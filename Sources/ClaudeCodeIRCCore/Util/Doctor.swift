import Foundation

/// First-run dependency check. ClaudeCodeIRC needs `claude` (the
/// Anthropic CLI, distributed via npm) to drive Claude turns and
/// optionally `cloudflared` (Homebrew) to host non-LAN rooms.
///
/// Brew users get both transitively from the formula
/// (`depends_on "cloudflared"` + `post_install` npm step). Users who
/// installed via direct GitHub-tarball download or whose Node manager
/// (asdf/nvm/fnm) wasn't on PATH when brew ran `post_install` can
/// land here without `claude` and would otherwise see a confusing
/// error mid-session when their first room tries to spawn the CLI
/// driver. The doctor surfaces the install hint upfront instead.
///
/// `cloudflared` missing is **non-blocking** at launch — Private
/// (LAN-only) rooms work fine without it. The
/// `TunnelError.cloudflaredNotFound` already thrown by
/// `TunnelManager.start` surfaces in `HostFormOverlay` when the user
/// picks Public/Group visibility.
public enum Doctor {

    public struct Report: Sendable {
        public let claudePath: String?
        public let cloudflaredPath: String?
        public init(claudePath: String?, cloudflaredPath: String?) {
            self.claudePath = claudePath
            self.cloudflaredPath = cloudflaredPath
        }
    }

    public static func check() -> Report {
        Report(
            claudePath: which("claude"),
            cloudflaredPath: which("cloudflared"))
    }

    /// Mirror of the resolution pattern in `ClaudeCLIDriver.resolveClaude`
    /// and `TunnelManager.resolveCloudflared` — `which` first, then the
    /// two well-known Homebrew prefixes (`/opt/homebrew/bin` on Apple
    /// silicon, `/usr/local/bin` on Intel).
    public static func which(_ tool: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", tool]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        if p.terminationStatus == 0 {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        for prefix in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = "\(prefix)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
