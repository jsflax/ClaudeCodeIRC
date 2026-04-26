import ClaudeCodeIRCCore
import NCursesUI

/// Framed code block — wraps the line-numbered, syntax-highlighted
/// source in NCursesUI's `CardView` primitive. The reverse-video
/// header chip carries the filename or language; line numbers go in
/// a 5-col gutter inside the card body.
///
/// Width is dynamic — CardView claims the layout pass's allocated
/// rect, so the block reflows with terminal resize. Empty-language
/// fences (bare ` ``` `) get a "code" fallback chip so the frame
/// still has a header.
struct CodeBlockView: View {
    let lang: String
    let filename: String?
    let source: String

    var body: some View {
        let lines = source.components(separatedBy: "\n")
        return CardView(
            title: Text(headerLabel),
            trailing: trailingLang,
            accent: .mute,
            content: {
                ForEach(Array(lines.indices)) { idx in
                    CodeLine(
                        lineNumber: idx + 1,
                        source: lines[idx],
                        lang: lang)
                }
            })
    }

    /// Chip header text. Prefers a non-empty filename, then a
    /// non-empty lang, else "code". Empty lang occurs for bare
    /// ` ``` ` fences (markdown without a language slug) — claude
    /// emits these for ad-hoc grammars / output blocks.
    private var headerLabel: String {
        if let f = filename, !f.isEmpty { return f }
        if !lang.isEmpty { return lang }
        return "code"
    }

    /// When both filename + lang are present, surface the lang as
    /// the trailing annotation so the chip stays focused on the
    /// filename. Returns nil when there's nothing to display so
    /// CardView skips the trailing slot.
    private var trailingLang: Text? {
        guard let f = filename, !f.isEmpty, !lang.isEmpty else { return nil }
        return Text(lang).paletteColor(.dim)
    }
}

/// One line inside a code block: a 5-col line-number gutter then the
/// tokenized source. CardView owns the outer `│ … │` borders so this
/// row only needs to render content — no left-frame `│` needed.
struct CodeLine: View {
    let lineNumber: Int
    let source: String
    let lang: String

    var body: some View {
        var line = Text(String(format: "%3d  ", lineNumber)).paletteColor(.dim)
        for token in SyntaxHighlighter.tokenize(source, language: lang) {
            line = line + Text(token.text).paletteColor(roleFor(token.kind))
        }
        return line
    }

    /// Map token kind → palette role so syntax colours track the
    /// active palette. The four `code*` roles in the palette
    /// registry are tuned per palette (phosphor / amber / modern /
    /// claude); diff-row colours reuse the generic `ok` / `danger` /
    /// `accent2` slots since they're not language-specific.
    private func roleFor(_ kind: TokenKind) -> Palette.Role {
        switch kind {
        case .keyword:      return .codeKw
        case .string:       return .codeStr
        case .comment:      return .codeCom
        case .number:       return .codeNum
        case .identifier:   return .codeIdent
        case .punctuation:  return .codePunct
        case .whitespace:   return .codeIdent
        case .diffAdd:      return .ok
        case .diffRemove:   return .danger
        case .diffHunk:     return .accent2
        case .diffMeta:     return .dim
        }
    }
}
