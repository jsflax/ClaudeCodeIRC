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
    /// yet. We can't know the model with certainty until claude
    /// emits a `system_init` or assistant turn — but the user's
    /// `~/.claude.json` records every model they've actually driven,
    /// keyed by per-project `lastModelUsage` payloads. The variant
    /// with the highest cumulative `outputTokens` is the one they
    /// use most, so it's a sensible default to surface in the
    /// statusline until the real value arrives.
    package static func mostRecentModelId() -> String? {
        var best: (id: String, output: Int)?
        for (id, payload) in everyLastModelUsage() {
            let output = (payload as? [String: Any])
                .flatMap { $0["outputTokens"] as? Int } ?? 0
            if output > (best?.output ?? -1) {
                best = (id, output)
            }
        }
        return best?.id
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
