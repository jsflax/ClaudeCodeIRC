import Foundation
import Lattice

/// One `claude -p` subprocess per user prompt. Spawns it with:
///
///   claude -p \
///     --input-format stream-json --output-format stream-json --verbose \
///     --session-id <session.claudeSessionId> \
///     --mcp-config <tmpfile pointing at `claudecodeirc --mcp-approve`> \
///     --permission-prompt-tool mcp__ccirc__approve \
///     --permission-mode <mode>
///
/// Writes the user message to stdin and immediately closes stdin —
/// `-p` ("print response and exit") only emits the `result` event
/// once its stdin reaches EOF. Conversation continuity comes from
/// `--session-id`: claude persists state under that UUID and resumes
/// on the next spawn with the same id.
///
/// Owns a `ClaudeEventProcessor` for event→Lattice translation. Actor
/// isolation serialises concurrent `send` calls — a second `@claude`
/// mention arriving mid-turn queues behind the first.
///
/// Not concerned with tool approvals: those route through the MCP
/// shim (`ApprovalMcpShim`) which writes `ApprovalRequest` rows that
/// the host TUI reads.
public actor ClaudeCLIDriver: ClaudeDriver {
    // MARK: - Configuration

    private var processor: ClaudeEventProcessor
    private let sessionRef: ModelThreadSafeReference<Session>
    private let sessionCode: String
    private let claudeSessionId: UUID
    private let cwd: String

    // MARK: - In-flight subprocess state

    private var process: Process?
    private var stdinPipe: Pipe?
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?

    // MARK: - Init

    /// Caller passes `SendableReference`s for `Lattice` and `Session`;
    /// the actor resolves both on its own isolation domain so the
    /// processor's stored properties are owned by the driver, not a
    /// shared main-actor handle.
    public init(
        latticeRef: LatticeThreadSafeReference,
        sessionRef: ModelThreadSafeReference<Session>,
        cwd: String
    ) async throws {
        guard let lattice = latticeRef.resolve() else {
            throw DriverError.latticeUnavailable
        }
        guard let session = sessionRef.resolve(on: lattice) else {
            throw DriverError.sessionUnavailable
        }
        self.processor = ClaudeEventProcessor(lattice: lattice, session: session)
        self.sessionRef = sessionRef
        self.sessionCode = session.code
        self.claudeSessionId = session.claudeSessionId
        self.cwd = cwd
    }

    // MARK: - ClaudeDriver

    /// Spawn a fresh `claude -p`, feed it the prompt, wait for the
    /// subprocess to exit. Actor isolation serialises concurrent
    /// callers behind the await.
    public func send(
        prompt: String,
        promptMessageRef: ModelThreadSafeReference<ChatMessage>?
    ) throws {
        Task { [weak self] in
            await self?.runTurn(prompt: prompt, promptMessageRef: promptMessageRef)
        }
    }

    public func stop() async {
        flushTask?.cancel()
        processor.flush()
        readerTask?.cancel()
        stderrTask?.cancel()
        if let stdin = stdinPipe?.fileHandleForWriting { try? stdin.close() }
        if let p = process, p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }
        process = nil
        stdinPipe = nil
        Log.line("claude-cli", "stopped")
    }

    // MARK: - Per-turn lifecycle

    private func runTurn(
        prompt: String,
        promptMessageRef: ModelThreadSafeReference<ChatMessage>?
    ) async {
        do {
            // Decide continuation BEFORE openTurn so the current turn
            // isn't counted. `--session-id` creates; `--resume`
            // continues. Filter by session via SQL — `.where` pushes
            // the predicate down to SQLite rather than walking every
            // Turn in Swift.
            let code = sessionCode
            let priorTurns = processor.lattice.objects(Turn.self)
                .where { $0.session.code == code }
                .count
            let isContinuation = priorTurns > 0

            let promptMessage = promptMessageRef?.resolve(on: processor.lattice)
            processor.openTurn(promptMessage: promptMessage)
            try await spawnAndDrain(prompt: prompt, isContinuation: isContinuation)
            processor.flush()
            // Safety net: if the reader missed the `result` event
            // (e.g. claude's last line arrived truncated so JSONDecoder
            // bailed with "Unexpected end of file"), the Turn stays
            // `.streaming` forever and the UI shows a perpetual
            // thinking-spinner. `closeTurnOnEof` is a no-op when a
            // `result` event already flipped the turn to `.done`, so
            // it's safe to call unconditionally.
            processor.closeTurnOnEof()
        } catch {
            Log.line("claude-cli", "runTurn failed: \(error)")
            processor.closeTurnOnEof()
        }
    }

    private func spawnAndDrain(prompt: String, isContinuation: Bool) async throws {
        let claudePath = try resolveClaude()
        let mcpConfigPath = try writeMcpConfig()

        // Re-resolve per spawn so Shift-Tab mode changes in the UI
        // take effect on the next `@claude` mention. The Session row
        // is the source of truth.
        let currentMode = sessionRef.resolve(on: processor.lattice)?
            .permissionMode ?? .default

        let sessionArg = isContinuation ? "--resume" : "--session-id"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            sessionArg, claudeSessionId.uuidString.lowercased(),
            "--mcp-config", mcpConfigPath,
            "--permission-prompt-tool", "mcp__ccirc__approve",
            "--permission-mode", currentMode.rawValue,
        ]
        p.environment = ProcessInfo.processInfo.environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        try p.run()
        process = p
        stdinPipe = stdin
        Log.line("claude-cli", "spawned pid=\(p.processIdentifier) cwd=\(self.cwd)")

        startReader(stdout: stdout)
        startStderrReader(stderr: stderr)

        // Write the user event and immediately EOF — `claude -p` only
        // emits the `result` event after stdin closes.
        let envelope: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [])
        try stdin.fileHandleForWriting.write(contentsOf: data)
        try stdin.fileHandleForWriting.write(contentsOf: Data([0x0a]))
        try stdin.fileHandleForWriting.close()
        Log.line("claude-cli", "sent prompt (\(prompt.count) chars); stdin closed")

        // Drain remaining stdout lines, then wait for process exit.
        await readerTask?.value
        await stderrTask?.value
        p.waitUntilExit()
        Log.line("claude-cli", "subprocess exited status=\(p.terminationStatus)")

        // Subprocess exit → any AskQuestion the MCP shim wrote (in
        // its own subprocess, same SQLite file) is now orphaned: the
        // shim is dead so even if quorum lands, nobody's tailing for
        // it. Flip pending rows to `.cancelled` with a clear reason
        // so the UI clears the card and clients see a definite
        // outcome. Idempotent — re-flipping an already-cancelled row
        // is a no-op via the status guard.
        cancelOrphanedAskQuestions()

        process = nil
        stdinPipe = nil
        readerTask = nil
        stderrTask = nil
    }

    /// Walk every `.pending` AskQuestion in the driver's lattice and
    /// flip them to `.cancelled`. There's effectively one driver per
    /// lattice file (one room → one host claude subprocess), so the
    /// scan-without-session-scope is safe; if multi-session-per-room
    /// ever lands, add a `session` filter here.
    private func cancelOrphanedAskQuestions() {
        let lattice = processor.lattice
        let pending = Array(lattice.objects(AskQuestion.self)
            .where { $0.status == .pending })
        guard !pending.isEmpty else { return }
        lattice.transaction {
            for q in pending where q.status == .pending {
                q.status = .cancelled
                q.cancelReason = "claude subprocess exited"
                q.answeredAt = Date()
            }
        }
        Log.line("claude-cli", "cancelled \(pending.count) orphaned AskQuestion rows")
    }

    // MARK: - Claude discovery + MCP config

    private func resolveClaude() throws -> String {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "claude"]
        let out = Pipe()
        which.standardOutput = out
        which.standardError = Pipe()
        try? which.run()
        which.waitUntilExit()
        if which.terminationStatus == 0 {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        for candidate in ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw DriverError.claudeNotFound
    }

    private func writeMcpConfig() throws -> String {
        let binPath = Bundle.main.executablePath
            ?? ProcessInfo.processInfo.arguments.first
            ?? "claudecodeirc"
        let config: [String: Any] = [
            "mcpServers": [
                "ccirc": [
                    "command": binPath,
                    "args": ["--mcp-approve", "--room-code", sessionCode],
                ],
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted])
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ccirc-mcp-\(sessionCode).json")
        try data.write(to: tmp, options: .atomic)
        return tmp.path
    }

    // MARK: - Stdout / stderr readers

    /// Read stdout as newline-delimited text using an explicit byte
    /// buffer. We used to iterate `handle.bytes.lines` (AsyncBytes on
    /// Darwin) but observed data loss under bursty output — when
    /// `claude -p` spawned an Agent sub-task and emitted a dozen
    /// `tool_use` events in a single millisecond, the final event
    /// arrived mid-JSON (`"stop_sequ` cut off at byte 371). The Turn
    /// then sat `.streaming` forever because the `result` event that
    /// would have closed it was part of the lost tail. Explicit
    /// `availableData` + manual `\n` splitting avoids the AsyncBytes
    /// cut-offs.
    private func startReader(stdout: Pipe) {
        let handle = stdout.fileHandleForReading
        readerTask = Task.detached { [weak self] in
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break }  // EOF
                buffer.append(chunk)
                while let nlIdx = buffer.firstIndex(of: 0x0a) {
                    let lineData = buffer[buffer.startIndex..<nlIdx]
                    buffer.removeSubrange(buffer.startIndex...nlIdx)
                    guard
                        let line = String(data: lineData, encoding: .utf8),
                        let self
                    else { continue }
                    await self.ingest(line: line)
                }
            }
            if !buffer.isEmpty {
                // Claude exited without terminating the last line with
                // `\n`. Surface it so we can tell genuine truncation
                // from decode failures on otherwise-complete lines.
                Log.line("claude-cli",
                    "stdout EOF with trailing \(buffer.count) bytes (no newline)")
            }
        }
    }

    private func startStderrReader(stderr: Pipe) {
        let handle = stderr.fileHandleForReading
        stderrTask = Task.detached {
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nlIdx = buffer.firstIndex(of: 0x0a) {
                    let lineData = buffer[buffer.startIndex..<nlIdx]
                    buffer.removeSubrange(buffer.startIndex...nlIdx)
                    if let line = String(data: lineData, encoding: .utf8) {
                        Log.line("claude-cli.stderr", line)
                    }
                }
            }
        }
    }

    // MARK: - Ingest

    private func ingest(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let event: StreamJsonEvent
        do {
            event = try JSONDecoder().decode(StreamJsonEvent.self, from: data)
        } catch {
            Log.line("claude-cli",
                "decode failed: \(error) len=\(trimmed.count) raw=\(trimmed)")
            return
        }
        logEvent(event)
        processor.handle(event)
        scheduleFlushIfNeeded()
    }

    /// Surface the interesting milestones (init, tool use, result,
    /// unknown event kinds) into the file log. Per-delta streaming
    /// events would flood; skip those.
    private func logEvent(_ event: StreamJsonEvent) {
        switch event {
        case .systemInit(let s):
            Log.line("claude-cli",
                "init session=\(s.session_id ?? "?") model=\(s.model ?? "?")")
        case .assistant(let a):
            for block in a.message?.content ?? [] {
                switch block.type {
                case "tool_use":
                    Log.line("claude-cli",
                        "tool_use id=\(block.id ?? "?") name=\(block.name ?? "?")")
                case "tool_result":
                    Log.line("claude-cli",
                        "tool_result id=\(block.tool_use_id ?? "?") error=\(block.is_error ?? false)")
                default: break
                }
            }
        case .result(let r):
            Log.line("claude-cli",
                "turn done is_error=\(r.is_error ?? false) dur=\(r.duration_ms ?? -1)ms")
        case .unknown(let raw):
            Log.line("claude-cli", "unknown event: \(raw)")
        case .user, .streamEvent:
            break
        }
    }

    /// Bounded write rate: one `AssistantChunk` per 50ms window when
    /// deltas are streaming. Claude can emit 10–30 deltas/sec; each
    /// write hits the audit log and fans out to every peer.
    private func scheduleFlushIfNeeded() {
        guard !processor.pendingText.isEmpty, flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            await self?.timedFlush()
        }
    }

    private func timedFlush() {
        flushTask = nil
        processor.flush()
    }

    // MARK: - Errors

    public enum DriverError: Error, CustomStringConvertible {
        case claudeNotFound
        case latticeUnavailable
        case sessionUnavailable

        public var description: String {
            switch self {
            case .claudeNotFound:
                return "`claude` CLI not found on $PATH. Install: brew install claude or see https://docs.claude.com/claude-code"
            case .latticeUnavailable:
                return "failed to resolve room lattice from sendable reference"
            case .sessionUnavailable:
                return "failed to resolve session from sendable reference"
            }
        }
    }
}
