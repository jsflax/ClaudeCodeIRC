import ClaudeCodeIRCCore
import NCursesUI

/// Framed unified-diff block. Header shows the target file and
/// +/- line counts; body lines are rendered with a leading line-
/// number column so users can locate the change in the source file
/// without flipping back to the editor — same shape Claude Code
/// itself uses.
///
/// Line-number rule:
/// - removed (`-`) → original-file line number
/// - added (`+`) → new-file line number
/// - context (` `) → new-file line number
/// - meta (`@@`, `+++`, `---`, `diff`, `index`) → no line number
struct DiffBlockView: View {
    let file: String
    let patch: String

    var body: some View {
        let rendered = renderRows(patch)
        let plus = rendered.lazy.filter { $0.kind == .added }.count
        let minus = rendered.lazy.filter { $0.kind == .removed }.count
        let gutter = max(2, String(rendered.map(\.lineNumber).max() ?? 0).count)
        return VStack(spacing: 0) {
            header(plus: plus, minus: minus)
            ForEach(Array(rendered.indices)) { idx in
                DiffLine(row: rendered[idx], gutter: gutter)
            }
            footer
        }
    }

    private func header(plus: Int, minus: Int) -> Text {
        var line = Text("┌─── diff ").foregroundColor(.dim)
        line = line + Text(file.isEmpty ? "(unnamed)" : file)
            .foregroundColor(.yellow)
        line = line + Text("  ").foregroundColor(.dim)
        line = line + Text("+\(plus)").foregroundColor(.green)
        line = line + Text(" / ").foregroundColor(.dim)
        line = line + Text("-\(minus)").foregroundColor(.red)
        line = line + Text(" ").foregroundColor(.dim)
        let rule = String(repeating: "─", count: max(1, 40 - file.count))
        line = line + Text(rule).foregroundColor(.dim)
        line = line + Text("┐").foregroundColor(.dim)
        return line
    }

    private var footer: Text {
        Text("└────────────────────────────────────────────────────────────┘")
            .foregroundColor(.dim)
    }
}

/// Per-line classification used by `DiffBlockView` to drive both the
/// gutter line number and the body color.
enum DiffRowKind {
    case context, added, removed, hunk, meta
}

/// One row of the diff body, post-parse: kind + the line number to
/// display in the gutter (0 when no number applies, e.g. `@@`
/// headers and meta lines) + the original source text.
struct DiffRow {
    let kind: DiffRowKind
    let lineNumber: Int
    let text: String
}

/// Walk a unified-diff patch and assign per-row classifications +
/// line numbers. Each `@@ -a,b +c,d @@` header reseeds the running
/// `oldLine` / `newLine` counters; subsequent rows increment one or
/// both depending on whether they're a removal, addition, or
/// context line. Lines we can't classify (or that precede any `@@`
/// header) get `lineNumber = 0`.
private func renderRows(_ patch: String) -> [DiffRow] {
    var rows: [DiffRow] = []
    var oldLine = 0
    var newLine = 0
    for line in patch.components(separatedBy: "\n") {
        if line.hasPrefix("@@") {
            if let (a, c) = parseHunkStarts(line) {
                oldLine = a
                newLine = c
            }
            rows.append(DiffRow(kind: .hunk, lineNumber: 0, text: line))
            continue
        }
        if line.hasPrefix("+++") || line.hasPrefix("---")
            || line.hasPrefix("diff ") || line.hasPrefix("index ") {
            rows.append(DiffRow(kind: .meta, lineNumber: 0, text: line))
            continue
        }
        if line.hasPrefix("+") {
            rows.append(DiffRow(kind: .added, lineNumber: newLine, text: line))
            newLine += 1
            continue
        }
        if line.hasPrefix("-") {
            rows.append(DiffRow(kind: .removed, lineNumber: oldLine, text: line))
            oldLine += 1
            continue
        }
        // Context (or empty trailing line). Empty terminator is
        // common when patches end with `\n`; render it as a final
        // blank context row so the visible block still terminates
        // cleanly.
        let n = oldLine == 0 && newLine == 0 ? 0 : newLine
        rows.append(DiffRow(kind: .context, lineNumber: n, text: line))
        if oldLine > 0 { oldLine += 1 }
        if newLine > 0 { newLine += 1 }
    }
    return rows
}

/// Parse the start line numbers out of a hunk header. Handles two
/// shapes:
/// - Standard unified-diff `@@ -a,b +c,d @@` (also accepted without
///   the `,b`/`,d` counts when each side is one line).
/// - The synthesized form `@@ N ⇢ M @@` emitted by
///   `ToolDiffPreview.synthesizePatch` for Edit/Write previews where
///   we don't yet have an absolute file position. There the numbers
///   are line *counts*, not start positions, so we render the hunk
///   starting at line 1 — gutter still shows relative ordering within
///   the change, which is the user-visible win.
/// Returns `nil` if the header doesn't match either form.
private func parseHunkStarts(_ line: String) -> (Int, Int)? {
    guard let hunkRange = line.range(of: "@@", options: .literal) else { return nil }
    let after = line[hunkRange.upperBound...]
    if after.contains("⇢") {
        return (1, 1)
    }
    var minus: Int?
    var plus: Int?
    for token in after.split(separator: " ") {
        if token.hasPrefix("-") {
            let body = token.dropFirst()
            let head = body.split(separator: ",").first.map(String.init) ?? String(body)
            minus = Int(head)
        } else if token.hasPrefix("+") {
            let body = token.dropFirst()
            let head = body.split(separator: ",").first.map(String.init) ?? String(body)
            plus = Int(head)
        }
    }
    guard let minus, let plus else { return nil }
    return (minus, plus)
}

/// One row of the diff body: dim gutter (line number, right-aligned
/// to a shared width) + body colored per row kind.
struct DiffLine: View {
    let row: DiffRow
    let gutter: Int

    var body: some View {
        let color: Color = {
            switch row.kind {
            case .added:    return .green
            case .removed:  return .red
            case .hunk:     return .cyan
            case .meta:     return .dim
            case .context:  return .white
            }
        }()
        let gutterText = row.lineNumber > 0
            ? String(row.lineNumber).padded(toLeadingWidth: gutter)
            : String(repeating: " ", count: gutter)
        var line = Text("│ ").foregroundColor(.dim)
        line = line + Text("\(gutterText)  ").foregroundColor(.dim)
        line = line + Text(row.text).foregroundColor(color)
        return line
    }
}

private extension String {
    /// Right-align `self` in a field of `toLeadingWidth` columns by
    /// prepending spaces. Used to keep the line-number gutter
    /// consistent across an entire patch.
    func padded(toLeadingWidth width: Int) -> String {
        let pad = max(0, width - count)
        return String(repeating: " ", count: pad) + self
    }
}
