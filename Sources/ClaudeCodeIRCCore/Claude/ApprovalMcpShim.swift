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

        // AskUserQuestion is semantically an answer prompt, not a
        // permission prompt — short-circuit BEFORE policy / Approval
        // creation so the room votes on labels instead of yes/no.
        // Branching here keeps the rest of the handler intact for
        // every other tool.
        if toolName == "AskUserQuestion" {
            return await handleAskQuestion(input: originalInput, lattice: lattice)
        }

        // ExitPlanMode is a plan-vote prompt with mode side-effects,
        // also handled bespoke. Same branch-before-Approval pattern.
        if toolName == "ExitPlanMode" {
            return await handleExitPlanMode(input: originalInput, lattice: lattice)
        }

        // Permission-mode pass-through. The two special handlers above
        // (AskUserQuestion / ExitPlanMode) have already run, so this
        // only affects "normal" tools (Bash, Edit, Write, …):
        //   - .auto / .bypassPermissions: short-circuit allow.
        //     `.auto` delegates safety to claude's own server-side
        //     classifier; `.bypassPermissions` is the deliberate
        //     no-guards mode reachable only by explicit code path.
        //   - .default / .plan: fall through to the room vote (the
        //     "manually approve" path; in plan mode claude already
        //     self-restricts to read-only tools).
        //   - .acceptEdits: deferred — wired in a follow-up.
        if let session = lattice.objects(Session.self).first {
            switch session.permissionMode {
            case .auto, .bypassPermissions:
                Log.line("mcp-shim",
                    "\(session.permissionMode.label)-mode pass-through tool=\(toolName)")
                return .init(behavior: .allow, updatedInput: originalInput, message: nil)
            case .default, .plan, .acceptEdits:
                break  // fall through to normal approval flow
            }
        }

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

        // Hard invariant: AskUserQuestion / ExitPlanMode must NEVER
        // produce an ApprovalRequest row — they're answer / plan-vote
        // prompts, not permission prompts. The early-return branches
        // above already cover this; the assertion catches future
        // refactors that move the branch point or introduce new code
        // paths reaching here. Ships as a no-op in release builds.
        assert(toolName != "AskUserQuestion" && toolName != "ExitPlanMode",
               "\(toolName) must be handled by its bespoke branch, not as an Approval")

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

    // MARK: - AskUserQuestion handler

    /// Intercepts `AskUserQuestion` tool calls and converts them into
    /// democratic question rows. Returns a `deny`-with-message
    /// `Decision` that hands claude the room's chosen answer(s) as
    /// the tool's "error" payload. The built-in `AskUserQuestion`
    /// is never invoked.
    private static func handleAskQuestion(input: Value, lattice: Lattice) async -> Decision {
        // Claude's input shape (see SDK):
        //   { questions: [{ question, header, options: [{label, description}], multiSelect }] }
        guard case .object(let inputDict) = input,
              case .array(let questions)? = inputDict["questions"],
              !questions.isEmpty
        else {
            Log.line("ask-shim", "malformed input — no questions array")
            return .init(behavior: .deny, updatedInput: nil,
                         message: "AskUserQuestion received malformed input.")
        }

        // Cap at 4 (claude's schema max) defensively. Group is
        // surfaced sequentially in the UI; share one toolUseId so
        // the tail loop below knows which rows to wait on.
        let toolUseId = UUID().uuidString
        let groupSize = min(questions.count, 4)

        // Parse outside the transaction; the tx only batches the
        // row inserts so the group lands atomically (peers either
        // see the full set of questions or none of them, never a
        // half-rendered group).
        struct Parsed { let header: String; let options: [AskOption]; let multiSelect: Bool }
        let parsed: [Parsed] = questions.prefix(groupSize).compactMap { qVal -> Parsed? in
            guard case .object(let q) = qVal else { return nil }
            let header: String = {
                if case .string(let s)? = q["question"] { return s }
                if case .string(let s)? = q["header"]   { return s }
                return "(question)"
            }()
            let multiSelect: Bool = {
                if case .bool(let b)? = q["multiSelect"] { return b }
                return false
            }()
            let options: [AskOption] = {
                guard case .array(let opts)? = q["options"] else { return [] }
                return opts.compactMap { entry -> AskOption? in
                    guard case .object(let o) = entry else { return nil }
                    let label: String = {
                        if case .string(let s)? = o["label"] { return s }
                        return ""
                    }()
                    guard !label.isEmpty else { return nil }
                    let desc: String = {
                        if case .string(let s)? = o["description"] { return s }
                        return ""
                    }()
                    return AskOption(label: label, optionDescription: desc)
                }
            }()
            return Parsed(header: header, options: options, multiSelect: multiSelect)
        }

        var rowRefs: [ModelThreadSafeReference<AskQuestion>] = []
        lattice.transaction {
            for (idx, p) in parsed.enumerated() {
                let row = AskQuestion()
                row.header = p.header
                row.options = p.options
                row.multiSelect = p.multiSelect
                row.status = .pending
                row.toolUseId = toolUseId
                row.groupIndex = idx
                row.groupSize = parsed.count
                row.requestedAt = Date()
                lattice.add(row)
                rowRefs.append(row.sendableReference)
                Log.line("ask-shim",
                    "queued question idx=\(idx)/\(parsed.count) header=\(p.header) " +
                    "options=\(p.options.count) multi=\(p.multiSelect)")
            }
        }

        guard !rowRefs.isEmpty else {
            return .init(behavior: .deny, updatedInput: nil,
                         message: "AskUserQuestion received no usable questions.")
        }

        // Tail until every row in the group is non-pending. Fast-path
        // check first in case the coordinator already finished (e.g.
        // single-pane quorum-1 trivial answer).
        await awaitGroupCompletion(rowRefs: rowRefs, lattice: lattice)

        // Resolve final state and build reply.
        let finals: [AskQuestion] = rowRefs.compactMap { $0.resolve(on: lattice) }
        if let cancelled = finals.first(where: { $0.status == .cancelled }) {
            let reason = cancelled.cancelReason.isEmpty ? "cancelled" : cancelled.cancelReason
            return .init(behavior: .deny, updatedInput: nil,
                         message: "User declined to answer: \(reason)")
        }

        let message = formatGroupReply(finals)
        Log.line("ask-shim", "group answered (\(finals.count) questions)")
        return .init(behavior: .deny, updatedInput: nil, message: message)
    }

    // MARK: - ExitPlanMode handler

    /// Constants for the four post-plan options. Match strings live
    /// in both the option list and the shim's reply dispatch — keep
    /// them in one place so a typo in either side fails loudly.
    private enum PlanChoice {
        static let yesAuto    = "Yes — auto mode"
        static let yesManual  = "Yes — manually approve edits"
        static let decline    = "Decline"
        static let declineRsn = "Decline with reason"
    }

    /// Intercepts `ExitPlanMode` calls. Renders the plan markdown as
    /// a question card with 4 fixed options (auto / manual / decline
    /// / decline-with-reason). The chosen label drives both the
    /// MCP reply (allow vs deny) and a side-effect on
    /// `Session.permissionMode` for the "yes" paths.
    ///
    /// Reuses the AskQuestion machinery (D11) — same coordinator,
    /// same card view, same "Other…" free-text overlay. Differs
    /// only in how the answer translates back to claude.
    private static func handleExitPlanMode(input: Value, lattice: Lattice) async -> Decision {
        let plan: String = {
            if case .object(let dict) = input,
               case .string(let p)? = dict["plan"] {
                return p
            }
            return "(no plan provided)"
        }()

        let toolUseId = UUID().uuidString
        let options: [AskOption] = [
            AskOption(label: PlanChoice.yesAuto,
                      optionDescription: "Approve plan; subsequent tool calls auto-allowed (claude's auto mode safety classifier still applies)."),
            AskOption(label: PlanChoice.yesManual,
                      optionDescription: "Approve plan; the room votes on each Edit/Write/Bash as before."),
            AskOption(label: PlanChoice.decline,
                      optionDescription: "Reject the plan. Claude stays in plan mode."),
            AskOption(label: PlanChoice.declineRsn,
                      optionDescription: "Reject with a reason — pick this to type a custom message."),
        ]

        var rowRef: ModelThreadSafeReference<AskQuestion>?
        lattice.transaction {
            let row = AskQuestion()
            row.header = plan
            row.options = options
            row.multiSelect = false
            row.status = .pending
            row.toolUseId = toolUseId
            row.groupIndex = 0
            row.groupSize = 1
            row.requestedAt = Date()
            lattice.add(row)
            rowRef = row.sendableReference
        }
        guard let rowRef else {
            return .init(behavior: .deny, updatedInput: nil,
                         message: "ExitPlanMode: failed to write plan card.")
        }
        Log.line("plan-shim", "queued plan card len=\(plan.count) toolUseId=\(toolUseId)")

        await awaitGroupCompletion(rowRefs: [rowRef], lattice: lattice)

        guard let q = rowRef.resolve(on: lattice) else {
            return .init(behavior: .deny, updatedInput: nil,
                         message: "ExitPlanMode: row vanished before resolution.")
        }
        if q.status == .cancelled {
            let reason = q.cancelReason.isEmpty ? "cancelled" : q.cancelReason
            return .init(behavior: .deny, updatedInput: nil,
                         message: "User declined the plan: \(reason)")
        }

        let chosen = q.chosenLabels.first ?? ""
        Log.line("plan-shim", "plan resolved chosen=\(chosen)")

        switch chosen {
        case PlanChoice.yesAuto:
            setSessionMode(.auto, on: lattice)
            return .init(behavior: .allow, updatedInput: input, message: nil)
        case PlanChoice.yesManual:
            setSessionMode(.default, on: lattice)
            return .init(behavior: .allow, updatedInput: input, message: nil)
        case PlanChoice.decline:
            return .init(behavior: .deny, updatedInput: nil,
                         message: "User declined the plan.")
        default:
            // Either the literal "Decline with reason" row (no extra
            // text was entered before submit), or a free-text label
            // from the Other… overlay. Both translate to declined +
            // the chosen string as the rejection reason.
            let reason = chosen.isEmpty ? "no reason given" : chosen
            return .init(behavior: .deny, updatedInput: nil,
                         message: "User declined the plan: \(reason)")
        }
    }

    private static func setSessionMode(_ mode: PermissionMode, on lattice: Lattice) {
        guard let session = lattice.objects(Session.self).first else { return }
        session.permissionMode = mode
        Log.line("plan-shim", "session.permissionMode → \(mode.label)")
    }

    private static func awaitGroupCompletion(
        rowRefs: [ModelThreadSafeReference<AskQuestion>],
        lattice: Lattice
    ) async {
        if allDone(rowRefs: rowRefs, lattice: lattice) { return }
        for await _ in lattice.changeStream {
            if allDone(rowRefs: rowRefs, lattice: lattice) { return }
        }
    }

    private static func allDone(
        rowRefs: [ModelThreadSafeReference<AskQuestion>],
        lattice: Lattice
    ) -> Bool {
        for ref in rowRefs {
            guard let row = ref.resolve(on: lattice) else { return false }
            if row.status == .pending { return false }
        }
        return true
    }

    /// Build the `User responded: …` string that claude's model sees
    /// as the AskUserQuestion tool's deny-message. Plan shape:
    ///   - 1 question, single-select: `"User responded: <label>"`
    ///   - 1 question, multi-select : `"User responded: ["a","b"]"`
    ///                                or `(no options selected)` for empty
    ///   - n questions: numbered list, one per question.
    private static func formatGroupReply(_ qs: [AskQuestion]) -> String {
        let sorted = qs.sorted { $0.groupIndex < $1.groupIndex }

        func answerSegment(_ q: AskQuestion) -> String {
            if q.multiSelect {
                guard !q.chosenLabels.isEmpty else { return "(no options selected)" }
                let quoted = q.chosenLabels.map { "\"\($0)\"" }.joined(separator: ", ")
                return "[\(quoted)]"
            } else {
                return q.chosenLabels.first ?? "(no answer)"
            }
        }

        if sorted.count == 1 {
            return "User responded: \(answerSegment(sorted[0]))"
        }
        var lines = ["User responded:"]
        for (i, q) in sorted.enumerated() {
            lines.append("\(i + 1). \(q.header) → \(answerSegment(q))")
        }
        return lines.joined(separator: "\n")
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
