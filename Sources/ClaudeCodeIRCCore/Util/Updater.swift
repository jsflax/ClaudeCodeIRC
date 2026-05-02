import CryptoKit
import Foundation

/// Silent self-update. Mirrors Claude Code's UX: a detached background
/// task on launch checks GitHub Releases for a newer published tag,
/// downloads the tarball, verifies its SHA256 against a sidecar file,
/// and atomically replaces the on-disk binary. The running process
/// keeps executing on its already-loaded inode — the new version takes
/// effect on the next launch.
///
/// Failure modes are all silent (logged to `ccirc.log` only): network
/// errors, hash mismatch, missing assets, unwritable install location.
/// Anything that could surprise the user goes through a skip gate.
public enum Updater {

    private static let repoOwner = "jsflax"
    private static let repoName = "ClaudeCodeIRC"
    private static let assetName = "claudecodeirc-darwin-arm64.tar.gz"

    /// Fire-and-forget entry point. Returns immediately; the actual
    /// check runs on a background-priority detached Task.
    public static func runInBackground(currentVersion: String) {
        Task.detached(priority: .background) {
            do {
                try await check(currentVersion: currentVersion)
            } catch {
                Log.line("updater", "check failed: \(error)")
            }
        }
    }

    private static func check(currentVersion: String) async throws {
        // --- skip gates ------------------------------------------------

        if currentVersion == "dev" {
            Log.line("updater", "skip: dev build")
            return
        }
        if ProcessInfo.processInfo.environment["CCIRC_SKIP_UPDATE"] != nil {
            Log.line("updater", "skip: CCIRC_SKIP_UPDATE set")
            return
        }
        if CommandLine.arguments.contains("--no-update") {
            Log.line("updater", "skip: --no-update")
            return
        }

        #if !arch(arm64)
        Log.line("updater", "skip: only darwin-arm64 is published")
        return
        #else

        guard let exePath = Bundle.main.executablePath else {
            Log.line("updater", "skip: no executablePath")
            return
        }
        let exeURL = URL(fileURLWithPath: exePath).resolvingSymlinksInPath()
        let exeRealPath = exeURL.path
        if exeRealPath.contains("/Cellar/") {
            Log.line("updater", "skip: brew install (\(exeRealPath))")
            return
        }
        let exeDir = exeURL.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: exeDir.path) {
            Log.line("updater", "skip: \(exeDir.path) not writable")
            return
        }

        // --- query latest release -------------------------------------

        let release = try await fetchLatestRelease()
        guard isNewer(remote: release.tagName, local: currentVersion) else {
            Log.line("updater", "up to date (local=\(currentVersion), remote=\(release.tagName))")
            return
        }
        Log.line("updater", "update available: \(currentVersion) → \(release.tagName)")

        guard let tarballAsset = release.assets.first(where: { $0.name == assetName }) else {
            Log.line("updater", "skip: missing tarball asset")
            return
        }
        guard let shaAsset = release.assets.first(where: { $0.name == assetName + ".sha256" }) else {
            Log.line("updater", "skip: missing sha256 sidecar — older release format")
            return
        }

        // --- download + verify ----------------------------------------

        let tarballData = try await download(tarballAsset.browserDownloadURL)
        let shaText = try await downloadString(shaAsset.browserDownloadURL)
        guard let expectedHex = shaText.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) else {
            Log.line("updater", "skip: empty sha256 sidecar")
            return
        }
        let actualHex = sha256Hex(tarballData)
        guard actualHex.lowercased() == expectedHex.lowercased() else {
            Log.line("updater", "sha256 mismatch (got \(actualHex), expected \(expectedHex))")
            return
        }

        // --- stage + extract ------------------------------------------

        let pid = getpid()
        let stagingTarball = exeDir.appendingPathComponent(".claudecodeirc.update.\(pid).tar.gz")
        let stagingDir = exeDir.appendingPathComponent(".claudecodeirc.update.\(pid).d")
        try? FileManager.default.removeItem(at: stagingTarball)
        try? FileManager.default.removeItem(at: stagingDir)
        defer {
            try? FileManager.default.removeItem(at: stagingTarball)
            try? FileManager.default.removeItem(at: stagingDir)
        }

        try tarballData.write(to: stagingTarball)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let untar = Process()
        untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        untar.arguments = ["-xzf", stagingTarball.path, "-C", stagingDir.path]
        untar.standardOutput = Pipe()
        untar.standardError = Pipe()
        try untar.run()
        untar.waitUntilExit()
        guard untar.terminationStatus == 0 else {
            Log.line("updater", "tar failed status=\(untar.terminationStatus)")
            return
        }

        let newBinary = stagingDir.appendingPathComponent("claudecodeirc")
        guard FileManager.default.fileExists(atPath: newBinary.path) else {
            Log.line("updater", "extracted tarball missing claudecodeirc")
            return
        }

        // Re-sign ad-hoc on the local host. The binary is already
        // ad-hoc signed in CI, but re-signing locally is cheap
        // insurance against any quarantine/signature hiccup post-
        // download. `Process` waits for completion; failure here is
        // non-fatal (the original CI signature should still be valid).
        let cs = Process()
        cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        cs.arguments = ["--force", "--sign", "-", newBinary.path]
        cs.standardOutput = Pipe()
        cs.standardError = Pipe()
        try? cs.run()
        cs.waitUntilExit()

        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: newBinary.path)

        // --- atomic replace -------------------------------------------

        // POSIX `rename(2)` is atomic within the same filesystem and
        // macOS allows replacing the executable file of a running
        // process — the running image stays mapped on its old inode.
        let rc = newBinary.path.withCString { src in
            exeRealPath.withCString { dst in
                rename(src, dst)
            }
        }
        if rc != 0 {
            Log.line("updater", "rename failed errno=\(errno)")
            return
        }
        Log.line("updater", "updated to \(release.tagName) — restart claudecodeirc to take effect")
        #endif
    }

    // MARK: - Version comparison

    /// True when `remote` is strictly newer than `local`. Both are
    /// expected to look like `v1.2.3` (leading `v` optional). Non-
    /// numeric components are treated as 0; any parse pathology
    /// returns `false` so we never try to "update" on garbage input.
    static func isNewer(remote: String, local: String) -> Bool {
        let r = parseSemver(remote)
        let l = parseSemver(local)
        guard !r.isEmpty, !l.isEmpty else { return false }
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func parseSemver(_ tag: String) -> [Int] {
        var s = tag
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: ".")
        return parts.map { Int($0) ?? 0 }
    }

    // MARK: - GitHub Releases API

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }
    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    private static func fetchLatestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeCodeIRC-Updater/1", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "Updater", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "release lookup http=\(code)"])
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    private static func download(_ url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    private static func downloadString(_ url: URL) async throws -> String {
        let data = try await download(url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - SHA256

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
