import ClaudeCodeIRCCore
import NCursesUI

/// Framed code block with a filename / language badge up top, a
/// line-number gutter on the left, and tokenized source. Ported
/// visual from `tui-core.jsx`'s `CodeBlock`.
///
/// Box characters are fixed to single-line right now; once the
/// palette adds per-role Text coloring (D10) we'll swap these for
/// the user's box-drawing preference.
struct CodeBlockView: View {
    let lang: String
    let filename: String?
    let source: String

    var body: some View {
        let lines = source.components(separatedBy: "\n")
        return VStack(spacing: 0) {
            header
            ForEach(Array(lines.indices)) { idx in
                CodeLine(
                    lineNumber: idx + 1,
                    source: lines[idx],
                    lang: lang)
            }
            footer
        }
    }

    private var header: Text {
        var line = Text("┌─── ").foregroundColor(.dim)
        line = line + Text(filename ?? lang).foregroundColor(.yellow)
        line = line + Text(" ").foregroundColor(.dim)
        let rule = String(repeating: "─", count: max(1, 60 - (filename ?? lang).count))
        line = line + Text(rule).foregroundColor(.dim)
        line = line + Text("┐").foregroundColor(.dim)
        return line
    }

    private var footer: Text {
        Text("└────────────────────────────────────────────────────────────┘")
            .foregroundColor(.dim)
    }
}

/// One line inside a code block: gutter `│`, padded line number,
/// then the tokenized source. The highlighter emits a flat token
/// stream; we render each token as a foreground-colored Text run
/// and concat with `+`.
struct CodeLine: View {
    let lineNumber: Int
    let source: String
    let lang: String

    var body: some View {
        var line = Text("│ ").foregroundColor(.dim)
        line = line + Text(String(format: "%3d", lineNumber)).foregroundColor(.dim)
        line = line + Text("  ").foregroundColor(.dim)
        for token in SyntaxHighlighter.tokenize(source, language: lang) {
            line = line + Text(token.text).foregroundColor(colorFor(token.kind))
        }
        return line
    }

    /// Map token class → legacy `Color` enum cell. When the palette
    /// role-aware Text API lands in D10 this becomes palette-driven.
    private func colorFor(_ kind: TokenKind) -> Color {
        switch kind {
        case .keyword:      return .yellow
        case .string:       return .green
        case .comment:      return .dim
        case .number:       return .cyan
        case .identifier:   return .white
        case .punctuation:  return .dim
        case .whitespace:   return .white
        case .diffAdd:      return .green
        case .diffRemove:   return .red
        case .diffHunk:     return .cyan
        case .diffMeta:     return .dim
        }
    }
}
