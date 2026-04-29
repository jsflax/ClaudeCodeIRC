import Foundation

/// Reads the user's Claude Code `statusLine` config, runs the configured
/// command on event triggers + an optional refresh interval, and writes
/// each invocation's stdout to a callback (which the host wires into
/// `Session.hostStatusLine`). Peers see the value via Lattice sync —
/// only the host runs the driver.
///
/// **Config sources** (project overrides user, per Claude Code spec):
/// 1. `<cwd>/.claude/settings.json`
/// 2. `~/.claude/settings.json`
///
/// Each is a JSON object with an optional `statusLine` field of shape:
/// ```json
/// { "type": "command", "command": "<shell>", "refreshInterval": <seconds>? }
/// ```
///
/// **Trigger model** (matches Claude Code):
/// - Event-driven: `nudge()` from the host (assistant turn complete,
///   permission mode change, etc.). Debounced 300ms so bursts coalesce.
/// - Optional timer: `refreshInterval` in seconds, clamped >= 1, when
///   the user's config sets it. Absent → no timer.
///
/// **Process model**: each invocation runs `cloudflared`-style — pipe
/// the spec'd JSON blob to stdin, capture stdout, write the trimmed
/// string to the callback. A new invocation cancels any in-flight one
/// (`Process.terminate`) so a slow script can't pile up.
///
/// Stop with `stop()`. Idempotent.
public actor StatusLineDriver {

    /// Invocation context — fed into the JSON blob piped to stdin per
    /// the Claude Code statusLine spec. Constructed by the host once
    /// per room and held for the driver's lifetime; mutable fields
    /// (cwd, sessionName) update via `setContext`.
    public struct Context: Sendable {
        public let cwd: String
        public let sessionId: String   // claudeSessionId.uuidString
        public let sessionName: String
        public let appVersion: String
        public init(cwd: String, sessionId: String, sessionName: String, appVersion: String) {
            self.cwd = cwd
            self.sessionId = sessionId
            self.sessionName = sessionName
            self.appVersion = appVersion
        }
    }

    /// Configuration parsed from `settings.json` — kept separate from
    /// `Context` because it's user-controlled and may be absent.
    private struct Config: Sendable {
        let command: String
        let refreshInterval: Int?  // seconds, nil = no timer
    }

    public typealias Output = @Sendable (String?) -> Void

    private let context: Context
    private let onOutput: Output

    private var stopped: Bool = false
    /// Currently-running statusline child process, if any. Replaced by
    /// `runOnce()` on each new invocation so an in-flight slow script
    /// is preempted.
    private var inFlight: Process?
    /// Coalesce-window task: `nudge()` schedules a 300ms-delayed run;
    /// further nudges within the window cancel + re-arm. Mirrors
    /// Claude Code's debounced trigger semantics.
    private var debounceTask: Task<Void, Never>?
    /// Periodic timer task driven by `Config.refreshInterval`, if any.
    /// Nil when the user's config has no interval.
    private var timerTask: Task<Void, Never>?

    /// - Parameter context: per-room metadata baked into the JSON blob.
    /// - Parameter onOutput: invoked on every successful run. Caller
    ///   typically writes the value into `Session.hostStatusLine`.
    public init(context: Context, onOutput: @escaping Output) {
        self.context = context
        self.onOutput = onOutput
    }

    /// Start the driver. No-op if no statusLine command is configured.
    /// Fires one initial run synchronously so the bar populates without
    /// the user having to wait for the first nudge.
    public func start() async {
        precondition(!stopped, "StatusLineDriver.start() called after stop()")
        guard let config = readConfig() else {
            Log.line("statusline", "no statusLine.command configured — driver idle")
            return
        }
        Log.line("statusline", "driver starting cmd=\(config.command.prefix(60))… refresh=\(config.refreshInterval.map(String.init) ?? "none")")
        // Initial fire — caller doesn't need to wait, the run is async
        // and the result lands via onOutput when ready.
        Task { await self.runOnce(config: config) }
        if let secs = config.refreshInterval, secs >= 1 {
            timerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(secs))
                    if Task.isCancelled { return }
                    await self?.runIfConfigured()
                }
            }
        }
    }

    /// Trigger an event-driven refresh. Debounced 300ms — back-to-back
    /// nudges within the window collapse into a single run. The host's
    /// observers (turn-complete, permission-mode-change) call this.
    public func nudge() {
        guard !stopped else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            await self?.runIfConfigured()
        }
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        debounceTask?.cancel(); debounceTask = nil
        timerTask?.cancel(); timerTask = nil
        if let p = inFlight, p.isRunning { p.terminate() }
        inFlight = nil
    }

    // MARK: - Config loading

    /// Read `statusLine` from project (`<cwd>/.claude/settings.json`)
    /// then user (`~/.claude/settings.json`). Project overrides user.
    /// Returns nil if neither has a usable command.
    private func readConfig() -> Config? {
        let projectURL = URL(fileURLWithPath: context.cwd)
            .appending(path: ".claude/settings.json")
        let userURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/settings.json")

        for url in [projectURL, userURL] {
            if let cfg = parseStatusLine(at: url) { return cfg }
        }
        return nil
    }

    private func parseStatusLine(at url: URL) -> Config? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sl = root["statusLine"] as? [String: Any],
              let command = sl["command"] as? String,
              !command.isEmpty
        else { return nil }
        let interval = (sl["refreshInterval"] as? Int) ?? (sl["refreshInterval"] as? Double).map(Int.init)
        return Config(command: command, refreshInterval: interval.map { max(1, $0) })
    }

    // MARK: - Process invocation

    private func runIfConfigured() async {
        guard let config = readConfig() else { return }
        await runOnce(config: config)
    }

    /// Spawn the configured command via `sh -c`, pipe the JSON context
    /// blob to stdin, capture stdout. A non-zero exit code suppresses
    /// output (clears the bar to nil per the Claude Code spec).
    private func runOnce(config: Config) async {
        // Cancel any in-flight invocation — slow scripts mustn't pile up.
        if let prev = inFlight, prev.isRunning { prev.terminate() }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", config.command]
        let stdin = Pipe()
        let stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = Pipe()  // drained but not surfaced

        let blob = makeStdinBlob()

        do {
            try p.run()
            inFlight = p
            try? stdin.fileHandleForWriting.write(contentsOf: blob)
            try? stdin.fileHandleForWriting.close()
        } catch {
            Log.line("statusline", "spawn failed: \(error)")
            return
        }

        // Wait off-actor — `waitUntilExit` blocks the calling thread,
        // so we hop to a detached task and resume here on completion.
        let exitStatus = await Task.detached(priority: .background) { () -> Int32 in
            p.waitUntilExit()
            return p.terminationStatus
        }.value

        // If we were cancelled in-flight by a newer run, the inFlight
        // pointer was reassigned; don't surface this run's output.
        guard inFlight === p else { return }
        inFlight = nil

        guard exitStatus == 0 else {
            Log.line("statusline", "non-zero exit (\(exitStatus)) — suppressing output")
            onOutput(nil)
            return
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty output is treated the same as no statusline — clearer
        // than rendering an empty row that the user can't account for.
        onOutput(trimmed.isEmpty ? nil : trimmed)
    }

    /// Build the JSON blob fed to the command's stdin. Subset of the
    /// Claude Code spec — we populate the fields we know authoritatively
    /// (cwd, session_id, transcript_path) and pass conservative defaults
    /// for the rest. `model` and `context_window` are read from the
    /// session's transcript jsonl when present (any assistant turn has
    /// fired); before the first assistant turn we fall back to a
    /// generic `Claude` / null context to match Claude Code itself.
    private func makeStdinBlob() -> Data {
        // Claude Code derives the transcript path from cwd + session
        // id. The cwd encoding rule is "replace any character that's
        // not legal in a directory segment with `-`", which in
        // practice means `/` AND `.` — so `/Users/jason.flax/proj`
        // becomes `-Users-jason-flax-proj`, not `-Users-jason.flax-proj`.
        // (Confirmed empirically against `~/.claude/projects/`.)
        // The result starts with `-`; we keep that leading dash.
        // The session-id segment is lowercased because
        // `ClaudeCLIDriver` passes the lowercased UUID on the command
        // line and Swift's `UUID.uuidString` is uppercase by default;
        // without lowercasing here, `TranscriptReader` returns nil
        // for a file that exists right next door.
        let encodedCwd = String(context.cwd.map { ($0 == "/" || $0 == ".") ? "-" : $0 })
        let sessionFile = "\(context.sessionId.lowercased()).jsonl"
        let transcriptURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects/\(encodedCwd)/\(sessionFile)")
        let transcriptPath = transcriptURL.path

        // Pull the latest assistant entry off the transcript to populate
        // the model id + cumulative usage. nil for a freshly-hosted room
        // where claude hasn't written any assistant turn yet.
        let snapshot = TranscriptReader.latestAssistant(at: transcriptURL)
        let modelBlob: [String: Any]
        let contextWindowBlob: Any
        let exceeds200k: Bool
        if let snap = snapshot {
            // Anthropic's API reports the base id (`claude-opus-4-7`)
            // even when the user is on the 1M-context plan — there's
            // no `[1m]` suffix in the assistant message. Claude Code
            // itself disambiguates by reading
            // `~/.claude.json`'s `projects.<cwd>.lastModelUsage`,
            // whose keys carry the variant suffix
            // (`claude-opus-4-7[1m]`). Mirror that lookup so our
            // statusline can show the same `Opus 4.7 (1M context)`
            // label the user is used to.
            let resolvedId = ClaudeUserConfig.resolveModelVariant(
                baseId: snap.modelId, cwd: context.cwd) ?? snap.modelId
            let info = ModelRegistry.info(for: resolvedId)
            modelBlob = ["id": resolvedId, "display_name": info.displayName]
            let used = snap.usage.totalTokens
            let pct = info.contextWindow > 0
                ? (Double(used) / Double(info.contextWindow)) * 100.0
                : 0
            contextWindowBlob = [
                "max_tokens": info.contextWindow,
                "used_tokens": used,
                "used_percentage": pct,
                "input_tokens": snap.usage.inputTokens,
                "output_tokens": snap.usage.outputTokens,
                "cache_creation_input_tokens": snap.usage.cacheCreationInputTokens,
                "cache_read_input_tokens": snap.usage.cacheReadInputTokens,
            ] as [String: Any]
            exceeds200k = used > 200_000
        } else if let recent = ClaudeUserConfig.mostRecentModelId() {
            // No transcript yet for this session, but the user has
            // driven claude code somewhere — surface their most-used
            // model id as a sensible default so the statusline reads
            // `Opus 4.7 (1M context) [...] 0%` from the very first
            // render, instead of `Claude [...] 0%` until the first
            // @claude turn writes a transcript line.
            let info = ModelRegistry.info(for: recent)
            modelBlob = ["id": recent, "display_name": info.displayName]
            contextWindowBlob = NSNull()
            exceeds200k = false
        } else {
            modelBlob = ["id": "default", "display_name": "Claude"]
            contextWindowBlob = NSNull()
            exceeds200k = false
        }

        let blob: [String: Any] = [
            "cwd": context.cwd,
            "session_id": context.sessionId,
            "session_name": context.sessionName,
            "transcript_path": transcriptPath,
            "model": modelBlob,
            "workspace": [
                "current_dir": context.cwd,
                "project_dir": context.cwd,
                "added_dirs": [],
                "git_worktree": NSNull(),
            ],
            "version": context.appVersion,
            "output_style": ["name": "default"],
            "cost": [
                "total_cost_usd": 0,
                "total_duration_ms": 0,
                "total_api_duration_ms": 0,
                "total_lines_added": 0,
                "total_lines_removed": 0,
            ],
            "context_window": contextWindowBlob,
            "exceeds_200k_tokens": exceeds200k,
            "thinking": ["enabled": false],
        ]
        return (try? JSONSerialization.data(withJSONObject: blob)) ?? Data()
    }
}
