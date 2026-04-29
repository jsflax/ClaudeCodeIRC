import Foundation

/// Shared logic for turning a `Write` / `Edit` / `MultiEdit` tool
/// payload (raw JSON string off `ToolEvent.input` or
/// `ApprovalRequest.toolInput`) into a unified-diff body that
/// `DiffBlockView` can render.
///
/// Used by both `ToolEventRow` (post-execution result body) and
/// `ApprovalCardView` (preview the change at decision time). The
/// downstream renderer is the same `DiffBlockView` body segments
/// already use, so visual treatment stays consistent across all
/// three surfaces.
enum ToolDiffPreview {

    /// Tools whose `input` carries enough information to synthesize a
    /// diff. Membership drives the "render diff vs render generic
    /// preview" branch in both call sites.
    static let supportedTools: Set<String> = ["Write", "Edit", "MultiEdit"]

    /// Single before/after pair feeding the diff renderer. Same
    /// semantic shape regardless of source tool — `Write` yields one
    /// pair with empty `old`, `Edit` yields one pair with both, and
    /// `MultiEdit` yields one per element of its `edits` array.
    struct Pair: Equatable {
        let old: String
        let new: String
    }

    /// Parsed view of a tool input — the file path it operates on
    /// plus the change pairs and, when claude code shipped one, a
    /// pre-baked unified-diff body. `prebakedPatch` is preferred for
    /// rendering because it already carries context lines around the
    /// change (the way claude code's own UI shows them); `pairs` is
    /// the fallback for pre-execution surfaces (the approval card)
    /// where we have only the tool input.
    struct Parsed: Equatable {
        let path: String
        let pairs: [Pair]
        let prebakedPatch: String?

        var totalRemoved: Int { pairs.reduce(0) { $0 + ToolDiffPreview.lineCount($1.old) } }
        var totalAdded: Int   { pairs.reduce(0) { $0 + ToolDiffPreview.lineCount($1.new) } }
    }

    /// Decode the raw JSON tool input, normalising the three input
    /// shapes (Write content, Edit old/new, MultiEdit edits[]) into a
    /// uniform `Parsed`. Returns nil if the input isn't JSON or
    /// matches none of the shapes.
    ///
    /// `resultMeta`, when supplied, is the JSON of `claude -p`'s
    /// `toolUseResult` envelope — it carries `originalFile` and a
    /// pre-baked `structuredPatch` for Write/Edit overwrites. If
    /// present, we prefer it over reconstructing the diff from
    /// `input` alone, which only has the new content (and would
    /// otherwise render an overwrite as a misleading pure-add).
    static func parse(_ rawInput: String, resultMeta: String? = nil) -> Parsed? {
        guard let data = rawInput.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let path = (obj["file_path"] as? String) ?? ""

        // Prefer claude code's pre-baked unified diff when present —
        // it carries context lines around each hunk (the way claude
        // code's own UI shows them) and proper `oldStart`/`newStart`
        // line numbers we can't reconstruct from the input alone.
        let prebaked = parseStructuredPatch(from: resultMeta)
        // `originalFile` is the Write fallback when there's no
        // `structuredPatch` (e.g. for the `Update` flavour, or stale
        // claude code releases) — it lets us still distinguish a
        // Write-overwrite from a Write-create.
        let originalFile = parseOriginalFile(from: resultMeta)

        // MultiEdit: `edits: [{old_string, new_string}, …]`
        if let arr = obj["edits"] as? [[String: Any]] {
            let pairs = arr.compactMap { dict -> Pair? in
                guard let old = dict["old_string"] as? String,
                      let new = dict["new_string"] as? String
                else { return nil }
                return Pair(old: old, new: new)
            }
            return Parsed(path: path, pairs: pairs, prebakedPatch: prebaked)
        }
        // Edit: `old_string` / `new_string` at the root.
        if let old = obj["old_string"] as? String,
           let new = obj["new_string"] as? String {
            return Parsed(path: path, pairs: [Pair(old: old, new: new)], prebakedPatch: prebaked)
        }
        // Write: `content` at the root. If the result envelope tells
        // us the file pre-existed, use its prior bytes as the `old`
        // side — that turns `+3 / -0` for an overwrite into a true
        // `+3 / -3` diff. Otherwise treat as a fresh-file create.
        if let content = obj["content"] as? String, !content.isEmpty {
            let old = originalFile ?? ""
            return Parsed(path: path, pairs: [Pair(old: old, new: content)], prebakedPatch: prebaked)
        }
        return nil
    }

    /// Pull `originalFile` (Claude Code's pre-execution snapshot of a
    /// Write target) out of the serialized `toolUseResult` envelope.
    /// Returns nil for create-style results where there was no prior
    /// file (or for any tool that doesn't ship an `originalFile`).
    private static func parseOriginalFile(from rawMeta: String?) -> String? {
        guard let raw = rawMeta,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let original = obj["originalFile"] as? String,
              !original.isEmpty
        else { return nil }
        return original
    }

    /// Convert the `toolUseResult.structuredPatch` array into a
    /// `DiffBlockView`-ready unified-diff body. Each hunk becomes:
    ///
    ///     @@ -<oldStart>,<oldLines> +<newStart>,<newLines> @@
    ///     <line>
    ///     <line>
    ///     …
    ///
    /// with hunk lines passed through verbatim — claude code already
    /// prefixes them with `+`/`-`/` ` and includes context lines, so
    /// the renderer's prefix-based colouring just works.
    private static func parseStructuredPatch(from rawMeta: String?) -> String? {
        guard let raw = rawMeta,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hunks = obj["structuredPatch"] as? [[String: Any]],
              !hunks.isEmpty
        else { return nil }
        var out: [String] = []
        for hunk in hunks {
            let oldStart = (hunk["oldStart"] as? Int) ?? 0
            let oldLines = (hunk["oldLines"] as? Int) ?? 0
            let newStart = (hunk["newStart"] as? Int) ?? 0
            let newLines = (hunk["newLines"] as? Int) ?? 0
            out.append("@@ -\(oldStart),\(oldLines) +\(newStart),\(newLines) @@")
            if let lines = hunk["lines"] as? [String] {
                out.append(contentsOf: lines)
            }
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    /// Pick the right patch body for the renderer: the pre-baked one
    /// from claude code's `structuredPatch` (which has context lines
    /// + real line numbers) when available, else the synthesized
    /// pairs-only diff. Returns nil for "nothing to draw" so the
    /// caller can suppress the `DiffBlockView` for empty changes.
    static func renderablePatch(_ parsed: Parsed) -> String? {
        if let prebaked = parsed.prebakedPatch, !prebaked.isEmpty {
            return prebaked
        }
        guard !parsed.pairs.isEmpty,
              parsed.totalRemoved + parsed.totalAdded > 0
        else { return nil }
        return synthesizePatch(parsed.pairs)
    }

    /// Build a unified-diff body across one or more pairs — one `@@`
    /// hunk header per pair followed by interleaved `-old`, `+new`
    /// and ` context` lines. The line classification comes from
    /// stdlib's `CollectionDifference` (Myers' diff under the hood),
    /// so unchanged lines sandwiched between edits render as context
    /// and aren't misreported as a remove + add. We skip `--- old` /
    /// `+++ new` file headers because `DiffBlockView` already renders
    /// the file name in its own header row; emitting them again
    /// would double up.
    static func synthesizePatch(_ pairs: [Pair]) -> String {
        var lines: [String] = []
        for pair in pairs {
            lines.append("@@ \(lineCount(pair.old)) ⇢ \(lineCount(pair.new)) @@")
            lines.append(contentsOf: diffLines(old: splitLines(pair.old), new: splitLines(pair.new)))
        }
        return lines.joined(separator: "\n")
    }

    /// Split a chunk of text into the lines a diff should classify.
    /// `"foo\n"` → `["foo"]` rather than `["foo", ""]` so a trailing
    /// newline doesn't show up as a phantom empty-line edit.
    private static func splitLines(_ s: String) -> [String] {
        if s.isEmpty { return [] }
        let parts = s.components(separatedBy: "\n")
        return (parts.last == "") ? Array(parts.dropLast()) : parts
    }

    /// Walk `old` and `new` in lockstep, emitting `-`, `+`, or ` `
    /// rows according to stdlib's `CollectionDifference`. Removals'
    /// offsets are positions in `old`; insertions' offsets are
    /// positions in `new`. Indices that aren't touched by either are
    /// unchanged on both sides — render as context.
    private static func diffLines(old: [String], new: [String]) -> [String] {
        let diff = new.difference(from: old)
        var removed: [Int: String] = [:]
        var inserted: [Int: String] = [:]
        for change in diff {
            switch change {
            case .remove(let offset, let element, _): removed[offset] = element
            case .insert(let offset, let element, _): inserted[offset] = element
            }
        }
        var out: [String] = []
        var oldIdx = 0
        var newIdx = 0
        while oldIdx < old.count || newIdx < new.count {
            if let r = removed[oldIdx] {
                out.append("-\(r)")
                oldIdx += 1
            } else if let i = inserted[newIdx] {
                out.append("+\(i)")
                newIdx += 1
            } else {
                // Unchanged on both sides; the two arrays agree here.
                out.append(" \(old[oldIdx])")
                oldIdx += 1
                newIdx += 1
            }
        }
        return out
    }

    /// "+5 lines" / "-2 +3 lines" / "3 edits  -8 +12" style caption,
    /// used by both `ToolEventRow`'s result row and the approval
    /// card's tally area so the framing stays consistent.
    static func summary(for parsed: Parsed) -> String {
        let removed = parsed.totalRemoved
        let added = parsed.totalAdded
        if parsed.pairs.isEmpty || (removed == 0 && added == 0) { return "(empty)" }
        if parsed.pairs.count > 1 {
            return "\(parsed.pairs.count) edits  -\(removed) +\(added)"
        }
        if removed == 0 { return "+\(added) line\(added == 1 ? "" : "s")" }
        return "-\(removed) +\(added) line\(max(removed, added) == 1 ? "" : "s")"
    }

    static func lineCount(_ s: String) -> Int {
        if s.isEmpty { return 0 }
        let parts = s.components(separatedBy: "\n")
        // Trailing newline shouldn't count as an extra empty line.
        return (parts.last == "") ? parts.count - 1 : parts.count
    }
}
