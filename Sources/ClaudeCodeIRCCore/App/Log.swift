import Foundation
import os

/// File-backed logger used all over the app while we debug connection
/// and sync plumbing. Writes to
///   `~/Library/Logs/ClaudeCodeIRC/ccirc.log`
/// with pid + timestamp per line so two instances running on the same
/// machine (host + peer in separate terminals) can share one file and
/// be disambiguated with `grep pid=`.
///
/// Also mirrors each line through `os.Logger` under the `ccirc.app`
/// subsystem so a single `log stream` invocation can merge Lattice's
/// own `lattice.io` logs with ours:
///
///   log stream --predicate 'subsystem == "ccirc.app" OR subsystem == "lattice.io"' --level debug
///
/// Thread-safety: serializes file writes on a single queue.
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
        _ = try? fh?.seekToEnd()
        return fh
    }()

    private static let queue = DispatchQueue(label: "ccirc.log")

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    private static let pid: Int32 = getpid()

    /// Cache `os.Logger` instances per tag. Guarded by `queue`.
    nonisolated(unsafe) private static var loggers: [String: Logger] = [:]
    private static func osLogger(for tag: String) -> Logger {
        if let existing = loggers[tag] { return existing }
        let l = Logger(subsystem: "ccirc.app", category: tag)
        loggers[tag] = l
        return l
    }

    public static func line(_ tag: String, _ msg: @autoclosure @escaping () -> String) {
        let message = msg()
        let ts = dateFormatter.string(from: Date())
        queue.async {
            if let fh = fileHandle {
                let line = "[\(ts)] [pid=\(pid)] [\(tag)] \(message)\n"
                fh.write(Data(line.utf8))
            }
            osLogger(for: tag).debug("\(message, privacy: .public)")
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
