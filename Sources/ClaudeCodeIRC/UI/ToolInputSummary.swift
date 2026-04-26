import Foundation

/// Shared helper for distilling a tool's JSON input into a one-line
/// human-readable preview. Used by `ToolEventRow` (live tool stream)
/// and `ApprovalCardView` (pending approvals) so the same Bash
/// command shows up the same way in both surfaces.
///
/// Pulls the most-meaningful field (`file_path`, `command`, `pattern`,
/// `url`, `query`, `prompt`, `description`) out of an object payload.
/// Falls back to the truncated raw string when the schema is
/// unfamiliar — keeps the row useful even for tools we haven't
/// special-cased.
enum ToolInputSummary {
    /// - Parameters:
    ///   - raw: the JSON string the tool emitted as input.
    ///   - limit: max characters in the returned preview. Truncated
    ///     with a trailing ellipsis when overflowing.
    static func summarise(_ raw: String, limit: Int = 100) -> String {
        guard !raw.isEmpty else { return "" }
        if let obj = parseJsonObject(raw) {
            // Priority order picks the first non-empty match. Order
            // tuned so file-path tools (Read, Write, Edit) and
            // command tools (Bash) read naturally without preferring
            // less-specific fields.
            for key in ["file_path", "path", "command", "pattern",
                        "description", "url", "query", "prompt"] {
                if let v = obj[key] as? String, !v.isEmpty {
                    return truncate(v, to: limit)
                }
            }
        }
        return truncate(raw, to: limit)
    }

    private static func parseJsonObject(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func truncate(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit - 1)) + "…"
    }
}
