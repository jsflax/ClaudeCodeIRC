import Foundation

/// Spawns and supervises a `cloudflared` quick-tunnel child process,
/// surfacing the assigned `https://*.trycloudflare.com` URL whenever it
/// changes. Quick tunnels are anonymous (no CF account, no domain) and
/// the URL is reissued on every process start, so the manager auto-
/// restarts on crash and the *consumer* of `urlChanges` is responsible
/// for republishing the new URL to peers (via `Session.publicURL`).
///
/// The actor is independent of any specific room: `start(localPort:)`
/// is parameterized so callers can build per-room or shared instances.
/// Today's wiring is one tunnel per hosted public/group room.
///
/// **Discovery.** `cloudflared` is resolved on `PATH` via `which`, with
/// the same Homebrew fallbacks as `ClaudeCLIDriver.resolveClaude`. We
/// declare `cloudflared` as a Homebrew dependency in the formula so
/// `brew install` users get it transitively. Direct-tarball users hit
/// `TunnelError.cloudflaredNotFound` and are pointed at the brew install
/// hint in the host UI.
///
/// **URL parsing.** Quick tunnels print the assigned URL on stderr; the
/// exact format has churned across `cloudflared` releases, so we match a
/// regex (`https://[a-z0-9-]+\.trycloudflare\.com`) over each newline-
/// terminated line. This mirrors the manual `availableData` + `\n`
/// buffering pattern from `ClaudeCLIDriver.startStderrReader` —
/// `FileHandle.AsyncBytes.lines` was observed to drop tail bytes under
/// bursty pipe output on Darwin.
public actor TunnelManager {
    public enum TunnelError: Error, Sendable {
        /// `which cloudflared` failed and no Homebrew-shaped fallback exists.
        case cloudflaredNotFound
        /// `Process.run()` threw — e.g. permission denied on the binary.
        case spawnFailed(any Error)
    }

    public private(set) var publicURL: URL?

    /// Yields a value every time the assigned tunnel URL changes
    /// (initial assignment counts; restart with the same URL would not,
    /// but quick tunnels always issue a fresh URL on restart).
    public nonisolated let urlChanges: AsyncStream<URL>
    private let urlContinuation: AsyncStream<URL>.Continuation

    private var process: Process?
    private var readerTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?

    private let localPort: UInt16
    private let restartOnExit: Bool
    private var stopped: Bool = false

    /// - Parameter localPort: the port `RoomSyncServer` is bound to.
    ///   `cloudflared` proxies inbound traffic from its public edge URL
    ///   to `http://localhost:<localPort>`.
    public init(localPort: UInt16, restartOnExit: Bool = true) {
        self.localPort = localPort
        self.restartOnExit = restartOnExit
        var continuation: AsyncStream<URL>.Continuation!
        self.urlChanges = AsyncStream { continuation = $0 }
        self.urlContinuation = continuation
    }

    /// Resolve `cloudflared` and spawn it. Returns once the process is
    /// launched (not when the URL is known — consumers wait on
    /// `urlChanges`).
    public func start() async throws {
        precondition(!stopped, "TunnelManager.start() called after stop()")
        let path = try Self.resolveCloudflared()
        try spawn(executablePath: path, localPort: localPort)
    }

    /// Terminate the child process and finish the URL stream. Idempotent.
    public func stop() {
        stopped = true
        restartTask?.cancel()
        restartTask = nil
        readerTask?.cancel()
        readerTask = nil
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
        urlContinuation.finish()
    }

    // MARK: - Spawn

    private func spawn(executablePath: String, localPort: UInt16) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executablePath)
        p.arguments = [
            "tunnel",
            "--url", "http://localhost:\(localPort)",
            "--no-autoupdate",
        ]
        let stderr = Pipe()
        p.standardError = stderr
        // Quick-tunnel stdout is generally empty but Process.run() throws
        // if no stdout is wired to a writable destination on some macOS
        // versions; route it to a discard pipe.
        p.standardOutput = Pipe()

        // The handler fires on a private dispatch queue. Hop back into
        // the actor; do nothing if a manual stop() already ran.
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { [weak self] in
                await self?.handleProcessExit(terminationStatus: status)
            }
        }

        do {
            try p.run()
        } catch {
            throw TunnelError.spawnFailed(error)
        }
        process = p
        Log.line(
            "tunnel",
            "spawned cloudflared pid=\(p.processIdentifier) localPort=\(localPort)")
        startStderrReader(stderr: stderr)
    }

    private func handleProcessExit(terminationStatus: Int32) async {
        Log.line("tunnel", "cloudflared exited status=\(terminationStatus)")
        readerTask?.cancel()
        readerTask = nil
        process = nil
        // The URL we previously announced is dead; clear it so callers
        // checking `publicURL` don't keep handing out stale routes.
        publicURL = nil

        guard restartOnExit, !stopped else { return }

        // Brief backoff so a misconfigured environment can't fork-bomb
        // cloudflared restarts.
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.start()
            } catch {
                Log.line("tunnel", "auto-restart failed: \(error)")
            }
        }
    }

    // MARK: - Stderr URL extraction

    private func startStderrReader(stderr: Pipe) {
        let handle = stderr.fileHandleForReading
        readerTask = Task.detached { [weak self] in
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break }  // EOF — process closed pipe
                buffer.append(chunk)
                while let nlIdx = buffer.firstIndex(of: 0x0a) {
                    let lineData = buffer[buffer.startIndex..<nlIdx]
                    buffer.removeSubrange(buffer.startIndex...nlIdx)
                    guard
                        let line = String(data: lineData, encoding: .utf8),
                        let self
                    else { continue }
                    Log.line("tunnel-stderr", line)
                    if let url = Self.extractTunnelURL(in: line) {
                        await self.recordURL(url)
                    }
                }
            }
        }
    }

    private func recordURL(_ url: URL) {
        guard publicURL != url else { return }
        Log.line("tunnel", "publicURL = \(url.absoluteString)")
        publicURL = url
        urlContinuation.yield(url)
    }

    // MARK: - URL extraction (regex)

    /// Find the first `https://*.trycloudflare.com` occurrence in `line`.
    /// `public`+nonisolated so tests in another module can exercise it
    /// without spinning the process. (Project convention: no
    /// `@testable import`. `public` over `package` because the latter
    /// would require a -package-name build flag we don't otherwise need.)
    public nonisolated static func extractTunnelURL(in line: String) -> URL? {
        // Hand-rolled scan instead of `Regex` literal to keep the hot path
        // free of regex compilation; called once per stderr line.
        let scheme = "https://"
        let suffix = ".trycloudflare.com"
        guard let schemeRange = line.range(of: scheme) else { return nil }
        let afterScheme = schemeRange.upperBound
        guard let suffixRange = line.range(of: suffix, range: afterScheme..<line.endIndex)
        else { return nil }
        // Scan forward from afterScheme. The host segment is the
        // contiguous run of `[a-z0-9-]` between scheme and suffix —
        // anything else means the suffix we found belongs to a
        // different (non-tunnel) URL or the host is malformed.
        let hostRange = afterScheme..<suffixRange.lowerBound
        guard !hostRange.isEmpty else { return nil }   // empty host
        for ch in line[hostRange] {
            guard ch.isASCII, ch.isLetter || ch.isNumber || ch == "-"
            else { return nil }
        }
        let urlString = String(line[schemeRange.lowerBound..<suffixRange.upperBound])
        return URL(string: urlString)
    }

    // MARK: - cloudflared discovery

    /// Resolve `cloudflared` on `PATH`. Mirrors `ClaudeCLIDriver.resolveClaude`.
    /// `nonisolated` so tests can call it without touching actor state.
    nonisolated static func resolveCloudflared() throws -> String {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "cloudflared"]
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
        for candidate in ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw TunnelError.cloudflaredNotFound
    }
}
