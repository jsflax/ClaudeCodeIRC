import Foundation
import Lattice
import MCP

/// The body of the `claudecodeirc --mcp-approve --room-code <code>`
/// subcommand. Spawned by `claude` as a stdio MCP server via the
/// `--mcp-config` file that `ClaudeCliDriver` writes. When `claude`
/// wants to use a tool, it calls the `approve` tool exposed here; we
/// write an `ApprovalRequest` row to the room Lattice, await a status
/// flip (`.approved` / `.denied`) via `lattice.changeStream`, and
/// return the MCP response.
///
/// Using Lattice IS the IPC — the host's TUI observes the same row
/// via its own handle on the same SQLite file and raises the approval
/// overlay; peers see the row sync down and render a read-only
/// "jason is reviewing…" indicator. When the host decides, the
/// status field updates and propagates back to us for free.
public enum ApprovalMcpShim {

    /// Call this from the app's `main()` before the TUI boots when
    /// `--mcp-approve` is present in argv. Blocks until stdin closes.
    public static func run() async -> Never {
        let args = parseArgs(CommandLine.arguments)
        guard let roomCode = args["--room-code"] else {
            stderr("ccirc --mcp-approve: missing --room-code")
            exit(2)
        }

        // Tests can override the on-disk lattice location to avoid
        // the Application Support resolution. Production callers (the
        // `ClaudeCLIDriver` → claude → shim spawn chain) leave it unset
        // and get the default `<code>.lattice` path.
        let lattice: Lattice
        do {
            if let path = args["--lattice-path"] {
                Log.line("mcp-shim", "starting roomCode=\(roomCode) path=\(path)")
                lattice = try Lattice(
                    for: RoomStore.schema,
                    configuration: .init(fileURL: URL(fileURLWithPath: path)))
            } else {
                Log.line("mcp-shim", "starting roomCode=\(roomCode)")
                lattice = try RoomStore.openHost(code: roomCode)
            }
            Log.line("mcp-shim", "lattice opened → \(lattice.configuration.fileURL.path)")
        } catch {
            stderr("ccirc --mcp-approve: lattice open failed: \(error)")
            exit(3)
        }

        // `Lattice` isn't `Sendable`, but the MCP SDK's method handler
        // closures are `@Sendable`. Capture the sendable reference and
        // resolve a fresh handle inside each handler — approvals are
        // infrequent (one per tool use), so per-call resolve overhead
        // is negligible.
        let latticeRef = lattice.sendableReference
        let server = Server(
            name: "ccirc-approve",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false)))

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [approveTool])
        }

        await server.withMethodHandler(CallTool.self) { params in
            guard params.name == "approve" else {
                throw MCPError.methodNotFound("unknown tool: \(params.name)")
            }
            guard let resolved = latticeRef.resolve() else {
                throw MCPError.internalError("could not resolve room lattice")
            }
            let decision = await handleApprove(params: params, lattice: resolved)
            let decisionJson = decision.asJsonString
            return CallTool.Result(content: [.text(decisionJson)], isError: false)
        }

        do {
            try await server.start(transport: StdioTransport())
            Log.line("mcp-shim", "started, waiting for requests")
        } catch {
            stderr("ccirc --mcp-approve: server.start failed: \(error)")
            exit(4)
        }

        // Safety: if parent `claude` dies and stdin never EOFs, exit.
        Task.detached {
            while true {
                try? await Task.sleep(for: .seconds(5))
                if getppid() == 1 {
                    Log.line("mcp-shim", "orphaned (ppid=1), exiting")
                    exit(0)
                }
            }
        }

        await server.waitUntilCompleted()
        Log.line("mcp-shim", "server completed — exiting")
        exit(0)
    }

    // MARK: - Tool spec + handler

    private static let approveTool = Tool(
        name: "approve",
        description: "Routes a tool-use permission request to the ClaudeCodeIRC host's approval overlay.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "tool_name": .object(["type": .string("string")]),
                "input":     .object(["type": .string("object")]),
            ]),
            "required": .array([.string("tool_name"), .string("input")]),
        ]))

    private static func handleApprove(params: CallTool.Parameters, lattice: Lattice) async -> Decision {
        let args = params.arguments ?? [:]
        let toolName: String = {
            if case .string(let s) = args["tool_name"] { return s }
            return "(unknown)"
        }()
        let inputStr: String = {
            guard let v = args["input"] else { return "" }
            return Self.valueAsString(v)
        }()
        let trimmed = inputStr.count > 180
            ? String(inputStr.prefix(180)) + "…"
            : inputStr
        let summary = "\(toolName): \(trimmed)"

        // claude-p's permission-prompt-tool runtime validates the
        // response schema and *requires* `updatedInput` on `allow` —
        // omitting it produces an "invalid_union / expected record"
        // tool_result error back to the model. Echo the original input
        // straight through for both policy-hit and human-decided paths.
        let originalInput = args["input"] ?? .object([:])

        // Short-circuit on a sticky policy — "always allow Bash" set
        // by a previous [A] press means every subsequent Bash call in
        // this room bypasses the overlay entirely.
        if let policy = lattice.objects(ApprovalPolicy.self)
            .first(where: { $0.toolName == toolName }) {
            Log.line("mcp-shim", "policy hit tool=\(toolName) decision=\(policy.decision)")
            switch policy.decision {
            case .approved: return .init(behavior: .allow, updatedInput: originalInput, message: nil)
            case .denied:   return .init(behavior: .deny, updatedInput: nil, message: "denied by policy")
            case .pending:  break  // treat as no-policy
            }
        }

        Log.line("mcp-shim", "approve request: \(summary)")

        let req = ApprovalRequest()
        req.toolName = toolName
        req.toolInput = inputStr
        req.summary = summary
        req.status = .pending
        lattice.add(req)

        let decision = await awaitDecision(req: req, lattice: lattice, originalInput: originalInput)
        Log.line("mcp-shim", "approve decision: \(decision.behavior.rawValue)")
        return decision
    }

    /// Tail changeStream until the row's status flips. `lattice.changeStream`
    /// yields for writes from ANY handle on the same SQLite file —
    /// including the host TUI's write when the user presses `[Y]` / `[D]`.
    private static func awaitDecision(
        req: ApprovalRequest,
        lattice: Lattice,
        originalInput: Value
    ) async -> Decision {
        // Fast path if somehow already decided.
        switch req.status {
        case .approved: return .init(behavior: .allow, updatedInput: originalInput, message: nil)
        case .denied:   return .init(behavior: .deny, updatedInput: nil, message: "denied by host")
        case .pending:  break
        }
        let ref = req.sendableReference
        for await _ in lattice.changeStream {
            guard let current = ref.resolve(on: lattice) else { continue }
            switch current.status {
            case .approved: return .init(behavior: .allow, updatedInput: originalInput, message: nil)
            case .denied:   return .init(behavior: .deny, updatedInput: nil, message: "denied by host")
            case .pending:  continue
            }
        }
        // Stream ended without a decision (shim torn down).
        return .init(behavior: .deny, updatedInput: nil, message: "shim exited before decision")
    }

    // MARK: - Types

    package struct Decision: Encodable {
        /// Wire contract read back by `claude`'s permission-prompt-tool
        /// transport. `String` raw values keep the JSON shape stable
        /// when the enum is serialized.
        package enum Behavior: String, Encodable {
            case allow, deny
        }

        package let behavior: Behavior
        /// The tool input echoed back to claude. claude-p's runtime
        /// validates `allow` responses and requires this field to be a
        /// record; omitting it produces "invalid_union / expected
        /// record" tool_result errors. For `deny`, leave nil.
        package let updatedInput: Value?
        package let message: String?

        package init(behavior: Behavior, updatedInput: Value?, message: String?) {
            self.behavior = behavior
            self.updatedInput = updatedInput
            self.message = message
        }

        /// Custom encode: emit only the keys claude-p's schema accepts.
        /// Allow responses carry `updatedInput`, deny responses carry
        /// `message`; nil fields are omitted (not encoded as null).
        package func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(behavior, forKey: .behavior)
            if let updatedInput { try c.encode(updatedInput, forKey: .updatedInput) }
            if let message { try c.encode(message, forKey: .message) }
        }

        private enum CodingKeys: String, CodingKey {
            case behavior, updatedInput, message
        }

        package var asJsonString: String {
            let enc = JSONEncoder()
            enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            guard let data = try? enc.encode(self),
                  let s = String(data: data, encoding: .utf8)
            else { return #"{"behavior":"deny","message":"encode error"}"# }
            return s
        }
    }

    // MARK: - Helpers

    /// Render an MCP `Value` back to a JSON string — used to embed the
    /// tool's input into the approval summary line.
    private static func valueAsString(_ value: Value) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        if let data = try? enc.encode(value),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return ""
    }

    private static func parseArgs(_ argv: [String]) -> [String: String] {
        var out: [String: String] = [:]
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--"), i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                out[a] = argv[i + 1]
                i += 2
            } else {
                out[a] = ""
                i += 1
            }
        }
        return out
    }

    private static func stderr(_ s: String) {
        FileHandle.standardError.write(Data("\(s)\n".utf8))
    }
}
