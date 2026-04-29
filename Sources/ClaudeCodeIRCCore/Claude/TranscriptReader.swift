import Foundation

/// Reads the most-recent `assistant` entry from a Claude Code transcript
/// jsonl file. Used by `StatusLineDriver` to derive the active model id
/// and the cumulative token usage for the current session.
///
/// The transcript file is the source of truth: claude code itself writes
/// it (one entry per line), every assistant turn includes
/// `message.model` and `message.usage`. We just tail the file, find
/// the last `"type":"assistant"` line, decode the relevant fields.
///
/// **Robustness.** The file is appended to constantly while a turn
/// streams. Reading is best-effort — if we hit a partial trailing
/// line, we skip it (the next `runOnce()` cycle will catch up). If
/// the file doesn't exist (room just hosted, claude hasn't written
/// yet) we return `nil` and the caller falls back to "early-session"
/// defaults (`Claude` / `null`).
package enum TranscriptReader {

    /// Subset of the assistant entry fields we care about. Decoded
    /// directly from the jsonl line. Other fields on the line
    /// (`parentUuid`, `timestamp`, `version`, …) are ignored.
    package struct AssistantSnapshot: Equatable, Sendable {
        package let modelId: String
        package let usage: Usage

        package struct Usage: Equatable, Sendable {
            package let inputTokens: Int
            package let cacheCreationInputTokens: Int
            package let cacheReadInputTokens: Int
            package let outputTokens: Int

            package var totalTokens: Int {
                inputTokens + cacheCreationInputTokens + cacheReadInputTokens + outputTokens
            }
        }
    }

    /// Read the file at `url` and return the parsed snapshot of the
    /// last `"type":"assistant"` line, if any. Returns `nil` for any
    /// of:
    /// - file missing or unreadable
    /// - no assistant entries yet (only `permission-mode`, `user`, etc.)
    /// - malformed json on every assistant line
    package static func latestAssistant(at url: URL) -> AssistantSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Iterate lines back-to-front; first parseable assistant entry wins.
        // `split` is fine here: typical transcripts are <10 MB, this is
        // called at refresh cadence (every few seconds at most), and the
        // alternative (line-by-line tail with file-position tracking) is
        // overkill for the current size envelope.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let snapshot = parseAssistant(lineData)
            else { continue }
            return snapshot
        }
        return nil
    }

    /// Decode a single line as an assistant entry. Returns `nil` if the
    /// line is malformed JSON, isn't `type:"assistant"`, or is missing
    /// the model/usage fields.
    package static func parseAssistant(_ data: Data) -> AssistantSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["type"] as? String) == "assistant",
              let message = root["message"] as? [String: Any],
              let modelId = message["model"] as? String,
              let usageDict = message["usage"] as? [String: Any]
        else { return nil }
        let usage = AssistantSnapshot.Usage(
            inputTokens: (usageDict["input_tokens"] as? Int) ?? 0,
            cacheCreationInputTokens: (usageDict["cache_creation_input_tokens"] as? Int) ?? 0,
            cacheReadInputTokens: (usageDict["cache_read_input_tokens"] as? Int) ?? 0,
            outputTokens: (usageDict["output_tokens"] as? Int) ?? 0)
        return AssistantSnapshot(modelId: modelId, usage: usage)
    }
}
