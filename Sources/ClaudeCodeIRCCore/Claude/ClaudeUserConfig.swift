import Foundation

/// Read-only helpers that pull selected fields out of the user's
/// `~/.claude.json` (Claude Code's per-user state file).
///
/// We keep these calls narrow on purpose — `~/.claude.json` is large,
/// frequently rewritten, and not a documented API. The only fields we
/// touch are the ones whose absence we can fall back from gracefully
/// (everything here returns `nil` when the file or the field is
/// missing, malformed, or shaped differently from what we expect).
package enum ClaudeUserConfig {

    /// Disambiguate an Anthropic model id by checking the user's
    /// `lastModelUsage` history across every project in
    /// `~/.claude.json`. The Anthropic API reports the base id (e.g.
    /// `claude-opus-4-7`) even when the user is on the 1M-context
    /// plan, so the assistant transcript alone can't tell us which
    /// variant is active. Claude Code records the variant id (e.g.
    /// `claude-opus-4-7[1m]`) in `projects.<cwd>.lastModelUsage`.
    ///
    /// We search globally rather than just the current `cwd`: the
    /// 1M plan is per-account, not per-project, so if the user has
    /// driven `<baseId>[1m]` in *any* project, the same variant
    /// applies in this one — even on a brand-new cwd that hasn't
    /// accumulated its own usage entry yet. Returns `nil` when no
    /// matching variant exists in the file.
    package static func resolveModelVariant(baseId: String, cwd _: String) -> String? {
        let prefix = baseId + "["
        for (id, _) in everyLastModelUsage() where id.hasPrefix(prefix) {
            // First match wins — there's only ever one variant
            // per base id active at a time on a given account.
            return id
        }
        return nil
    }

    /// Best-guess model id for the very first statusline render of a
    /// fresh session, when the transcript jsonl hasn't been written
    /// yet. We pick the model id from the **most-recently-modified**
    /// transcript jsonl across all `~/.claude/projects/`, which is a
    /// solid proxy for "what the user actually last drove" — far more
    /// useful than a cumulative-token heuristic that biases toward
    /// historic favourites long after the user has moved on (e.g.
    /// 1.2M tokens of legacy Opus 4.6 work outweighs 300k tokens of
    /// fresh Opus 4.7 work even when the user is firmly on 4.7 now).
    /// Returns `nil` when no transcripts exist at all.
    package static func mostRecentModelId() -> String? {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var best: (date: Date, url: URL)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if mtime > (best?.date ?? .distantPast) {
                best = (mtime, url)
            }
        }
        guard let best else { return nil }
        return latestAssistantModelId(in: best.url)
    }

    /// Tail the transcript jsonl, find the last `"type":"assistant"`
    /// line, and return its `message.model` id. Best-effort: returns
    /// `nil` for missing/unreadable files or transcripts containing
    /// only user / system events.
    private static func latestAssistantModelId(in url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (root["type"] as? String) == "assistant",
                  let message = root["message"] as? [String: Any],
                  let modelId = message["model"] as? String
            else { continue }
            return modelId
        }
        return nil
    }

    /// Flatten every project's `lastModelUsage` map into a single
    /// `(id, payload)` sequence. Keys repeat across projects (one
    /// per cwd) — callers that need a unique-by-id view should
    /// dedup themselves; both `resolveModelVariant` and
    /// `mostRecentModelId` are fine with the duplicates because
    /// they're aggregating, not enumerating.
    private static func everyLastModelUsage() -> [(String, Any)] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any]
        else { return [] }
        var out: [(String, Any)] = []
        for (_, project) in projects {
            guard let proj = project as? [String: Any],
                  let usage = proj["lastModelUsage"] as? [String: Any]
            else { continue }
            for (id, payload) in usage { out.append((id, payload)) }
        }
        return out
    }
}
