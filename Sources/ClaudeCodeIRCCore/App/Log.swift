import Foundation

/// File-backed logger used all over the app while we debug connection
/// and sync plumbing. Writes to
///   `~/Library/Logs/ClaudeCodeIRC/ccirc.log`
/// and never stdout/stderr — the TUI owns those and interleaved lines
/// would garble the ncurses output.
///
/// Thread-safety: serializes writes on a single queue.
public enum Log {
    private static let fileHandle: FileHandle? = {
        let logDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appending(path: "Logs/ClaudeCodeIRC")
        try? FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true)
        let url = logDir.appending(path: "ccirc.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let fh = try? FileHandle(forWritingTo: url)
        try? fh?.seekToEnd()
        return fh
    }()

    private static let queue = DispatchQueue(label: "ccirc.log")

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    public static func line(_ tag: String, _ msg: @autoclosure @escaping () -> String) {
        let message = msg()
        let ts = dateFormatter.string(from: Date())
        queue.async {
            guard let fh = fileHandle else { return }
            let line = "[\(ts)] [\(tag)] \(message)\n"
            fh.write(Data(line.utf8))
        }
    }

    /// Path to the log file for user-facing messages ("tail this to
    /// see what's going on").
    public static var filePath: String {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appending(path: "Logs/ClaudeCodeIRC/ccirc.log").path
    }
}
