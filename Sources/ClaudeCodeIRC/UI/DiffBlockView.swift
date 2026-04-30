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
        let language = languageSlug(forFilename: file)
        return VStack(spacing: 0) {
            header(plus: plus, minus: minus)
            ForEach(Array(rendered.indices)) { idx in
                DiffRowView(row: rendered[idx], gutter: gutter, language: language)
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

/// Per-row dispatcher: added / removed rows go through `DiffLineView`
/// (custom PrimitiveView with full-row bg fill + tokenized fg);
/// context rows go through `DiffLine` with tokenized fg but no bg
/// fill; hunk / meta rows keep the flat Text-based rendering.
struct DiffRowView: View {
    let row: DiffRow
    let gutter: Int
    let language: String

    @ViewBuilder
    var body: some View {
        if row.kind == .added || row.kind == .removed {
            DiffLineView(row: row, gutter: gutter, language: language)
        } else {
            DiffLine(row: row, gutter: gutter, language: language)
        }
    }
}

/// Context / hunk / meta row: dim gutter + body. Context rows are
/// syntax-highlighted in the active palette's code-token colours
/// (matches Claude Code's diff appearance — context lines aren't
/// just monotone). Hunk headers stay cyan; meta lines stay dim.
struct DiffLine: View {
    let row: DiffRow
    let gutter: Int
    let language: String

    var body: some View {
        let gutterText = row.lineNumber > 0
            ? String(row.lineNumber).padded(toLeadingWidth: gutter)
            : String(repeating: " ", count: gutter)
        var line = Text("│ ").foregroundColor(.dim)
        line = line + Text("\(gutterText)  ").foregroundColor(.dim)

        switch row.kind {
        case .hunk:
            line = line + Text(row.text).foregroundColor(.cyan)
        case .meta:
            line = line + Text(row.text).foregroundColor(.dim)
        case .context:
            // Context lines start with a leading space (the diff prefix)
            // — render it as raw whitespace so columns align with
            // added/removed rows, then tokenize the rest.
            let body = row.text.hasPrefix(" ")
                ? String(row.text.dropFirst())
                : row.text
            line = line + Text(" ").foregroundColor(.dim)
            for token in SyntaxHighlighter.tokenize(body, language: language) {
                line = line + Text(token.text).paletteColor(diffRoleFor(token.kind))
            }
        case .added, .removed:
            // Unreachable via DiffRowView (those go through DiffLineView).
            line = line + Text(row.text).foregroundColor(.white)
        }
        return line
    }
}

/// Map `SyntaxHighlighter` token kinds → palette code-token roles.
/// Shared between `DiffLine` (context) and `DiffLineView` (add/remove)
/// so all rows colour identically modulo the row background.
fileprivate func diffRoleFor(_ kind: TokenKind) -> Palette.Role {
    switch kind {
    case .keyword:      return .codeKw
    case .string:       return .codeStr
    case .comment:      return .codeCom
    case .number:       return .codeNum
    case .identifier:   return .codeIdent
    case .punctuation:  return .codePunct
    case .whitespace:   return .codeIdent
    case .diffAdd, .diffRemove, .diffHunk, .diffMeta:
        return .codeIdent
    }
}

/// Added / removed row: full-width diff-bg fill + dim gutter + bold
/// glyph + syntax-highlighted body.
///
/// PrimitiveView (no `body`) so we can read `rect.width` at draw time
/// and pin total run length to exactly that width. ≥2 runs guarantees
/// `Text.draw` enters the multi-run fast path and skips wrap, so
/// trailing padding spaces survive and bg-paint every cell across the
/// row. Lines longer than the rect are truncated, not wrapped — same
/// shape as Claude Code's diff renderer.
struct DiffLineView: View, PrimitiveView {
    typealias Body = Never
    let row: DiffRow
    let gutter: Int
    let language: String

    var body: Never { fatalError("DiffLineView has no body") }

    func measure(children: [ViewNode], proposedWidth: Int) -> Size {
        Size(width: proposedWidth, height: 1)
    }

    func draw(in rect: Rect) {
        guard rect.width > 0, rect.height > 0 else { return }
        let bg: Palette.DiffBg = row.kind == .added ? .add : .remove
        let glyph = row.kind == .added ? "+" : "-"
        let glyphRole: Palette.Role = row.kind == .added ? .ok : .danger

        // Strip the leading +/- so we tokenize the actual code body.
        let body = row.text.hasPrefix("+") || row.text.hasPrefix("-")
            ? String(row.text.dropFirst())
            : row.text

        let gutterText = row.lineNumber > 0
            ? String(row.lineNumber).padded(toLeadingWidth: gutter)
            : String(repeating: " ", count: gutter)

        // Build runs: frame `│ ` + gutter + space + bold glyph + space
        // + tokenized body + trailing-pad spaces.
        var line = Text("│ ").paletteColor(.dim, on: bg)
        line = line + Text("\(gutterText) ").paletteColor(.dim, on: bg)
        line = line + Text(glyph).paletteColor(glyphRole, on: bg).bold()
        line = line + Text(" ").paletteColor(.fg, on: bg)

        var consumed = 2 /* "│ " */ + gutterText.count + 1 /* sp */
            + 1 /* glyph */ + 1 /* sp */

        if consumed < rect.width {
            for token in SyntaxHighlighter.tokenize(body, language: language) {
                if consumed >= rect.width { break }
                let remaining = rect.width - consumed
                let text = token.text.count > remaining
                    ? String(token.text.prefix(remaining))
                    : token.text
                line = line + Text(text).paletteColor(diffRoleFor(token.kind), on: bg)
                consumed += text.count
            }
        }

        if consumed < rect.width {
            let pad = String(repeating: " ", count: rect.width - consumed)
            line = line + Text(pad).paletteColor(.fg, on: bg)
        }

        line.draw(in: rect)
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
