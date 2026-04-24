import Foundation

/// Token categories the highlighter emits. Map to palette
/// roles by the renderer:
///   `.keyword`     → palette.codeKw
///   `.string`      → palette.codeStr
///   `.comment`     → palette.codeCom
///   `.number`      → palette.codeNum
///   `.identifier`  → palette.codeIdent
///   `.punctuation` → palette.codePunct
///   `.whitespace`  → palette.fg
///   `.diffAdd`     → palette.ok
///   `.diffRemove`  → palette.danger
///   `.diffHunk`    → palette.accent2
///   `.diffMeta`    → palette.dim
public enum TokenKind: Sendable, Hashable {
    case keyword, string, comment, number, identifier, punctuation, whitespace
    case diffAdd, diffRemove, diffHunk, diffMeta
}

public struct Token: Equatable, Sendable, Hashable {
    public let text: String
    public let kind: TokenKind
    public init(text: String, kind: TokenKind) {
        self.text = text
        self.kind = kind
    }
}

/// Tiny per-line / per-token highlighter ported from
/// `tui-core.jsx`'s `highlightCode`. Not a real parser — a cheap
/// regex-first tokenizer good enough to paint code blocks in the
/// TUI. Swift, JS/TS, Python, shell, and unified diffs share the
/// same C-style scaffold; the lang slug picks the keyword set and
/// comment prefix.
public enum SyntaxHighlighter {

    public static func tokenize(_ source: String, language: String) -> [Token] {
        let lang = language.lowercased()
        switch lang {
        case "diff":
            return tokenizeDiff(source)
        case "js", "javascript":
            return tokenizeCLike(source, keywords: jsKeywords, lineComment: "//")
        case "ts", "typescript":
            return tokenizeCLike(source, keywords: tsKeywords, lineComment: "//")
        case "swift":
            return tokenizeCLike(source, keywords: swiftKeywords, lineComment: "//")
        case "py", "python":
            return tokenizeCLike(source, keywords: pyKeywords, lineComment: "#")
        case "sh", "bash", "zsh", "shell":
            return tokenizeCLike(source, keywords: shKeywords, lineComment: "#")
        default:
            return tokenizeCLike(source, keywords: [], lineComment: "//")
        }
    }

    // MARK: - Keyword sets (ported from tui-core.jsx)

    static let jsKeywords: Set<String> = [
        "const", "let", "var", "function", "return", "if", "else", "for",
        "while", "import", "export", "from", "await", "async", "class",
        "new", "try", "catch", "finally", "throw", "typeof", "in", "of",
        "null", "undefined", "true", "false", "this",
    ]
    static let tsKeywords: Set<String> = jsKeywords.union([
        "interface", "type", "as", "readonly", "public", "private", "protected",
    ])
    static let swiftKeywords: Set<String> = [
        "func", "struct", "class", "enum", "protocol", "extension", "actor",
        "let", "var", "if", "else", "for", "in", "while", "guard", "switch",
        "case", "default", "break", "continue", "return", "throw", "throws",
        "try", "catch", "defer", "import", "public", "private", "fileprivate",
        "internal", "open", "static", "final", "inout", "async", "await",
        "self", "Self", "nil", "true", "false", "init", "deinit", "where",
        "typealias", "associatedtype", "some", "any", "mutating", "nonmutating",
    ]
    static let pyKeywords: Set<String> = [
        "def", "class", "return", "if", "elif", "else", "for", "while",
        "import", "from", "as", "with", "try", "except", "finally", "raise",
        "lambda", "None", "True", "False", "self", "yield", "in", "not",
        "and", "or", "is", "pass", "break", "continue", "global", "nonlocal",
    ]
    static let shKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "do", "done", "while",
        "until", "case", "esac", "in", "function", "return", "export",
        "local", "readonly", "declare", "echo", "set", "cd", "rm", "mv",
        "cp", "mkdir", "grep", "sed", "awk", "cat",
    ]

    // MARK: - C-style tokenizer
    //
    // Scans in priority order: line comment, block comment, string
    // (single / double / backtick), number, identifier (classified
    // keyword vs ident), whitespace, punctuation. No nesting rules
    // — this is display-only and doesn't need to be correct on
    // pathological inputs.

    private static let lineCommentPrefixes: Set<String> = ["//", "#", "--"]

    private static func tokenizeCLike(
        _ source: String,
        keywords: Set<String>,
        lineComment: String
    ) -> [Token] {
        var tokens: [Token] = []
        let scalars = Array(source)
        var i = 0
        let n = scalars.count

        @inline(__always) func peek(_ offset: Int = 0) -> Character? {
            let idx = i + offset
            return idx < n ? scalars[idx] : nil
        }

        while i < n {
            let c = scalars[i]

            // Line comment: runs until newline.
            if matches(scalars, at: i, prefix: lineComment) {
                var j = i
                while j < n, scalars[j] != "\n" { j += 1 }
                tokens.append(Token(text: String(scalars[i..<j]), kind: .comment))
                i = j
                continue
            }
            // Block comment `/* … */` (supported in js/ts/swift/c).
            if c == "/", i + 1 < n, scalars[i + 1] == "*" {
                var j = i + 2
                while j + 1 < n, !(scalars[j] == "*" && scalars[j + 1] == "/") { j += 1 }
                j = min(j + 2, n)
                tokens.append(Token(text: String(scalars[i..<j]), kind: .comment))
                i = j
                continue
            }

            // String literal — quote-delimited, `\<char>` escapes.
            if c == "\"" || c == "'" || c == "`" {
                let quote = c
                var j = i + 1
                while j < n {
                    if scalars[j] == "\\", j + 1 < n { j += 2; continue }
                    if scalars[j] == quote { j += 1; break }
                    j += 1
                }
                tokens.append(Token(text: String(scalars[i..<j]), kind: .string))
                i = j
                continue
            }

            // Number literal — 123, 3.14. No hex / scientific for now.
            if c.isNumber {
                var j = i + 1
                while j < n, (scalars[j].isNumber || scalars[j] == ".") { j += 1 }
                tokens.append(Token(text: String(scalars[i..<j]), kind: .number))
                i = j
                continue
            }

            // Identifier — letter / underscore followed by letters / digits / underscores.
            if c.isLetter || c == "_" {
                var j = i + 1
                while j < n, (scalars[j].isLetter || scalars[j].isNumber || scalars[j] == "_") {
                    j += 1
                }
                let ident = String(scalars[i..<j])
                let kind: TokenKind = keywords.contains(ident) ? .keyword : .identifier
                tokens.append(Token(text: ident, kind: kind))
                i = j
                continue
            }

            // Whitespace run.
            if c.isWhitespace {
                var j = i + 1
                while j < n, scalars[j].isWhitespace { j += 1 }
                tokens.append(Token(text: String(scalars[i..<j]), kind: .whitespace))
                i = j
                continue
            }

            // Fallthrough — single-character punctuation.
            tokens.append(Token(text: String(c), kind: .punctuation))
            i += 1
        }
        return tokens
    }

    @inline(__always)
    private static func matches(_ scalars: [Character], at i: Int, prefix: String) -> Bool {
        let pc = Array(prefix)
        guard i + pc.count <= scalars.count else { return false }
        for k in 0..<pc.count where scalars[i + k] != pc[k] { return false }
        return true
    }

    // MARK: - Diff tokenizer
    //
    // Per-line classification rather than token-level. Each line is
    // a single token with its full text and a color-determining kind.
    // The renderer will split on newlines and paint line by line.

    private static func tokenizeDiff(_ source: String) -> [Token] {
        var tokens: [Token] = []
        let lines = source.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let kind: TokenKind
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                kind = .diffMeta
            } else if line.hasPrefix("@@") {
                kind = .diffHunk
            } else if line.hasPrefix("+") {
                kind = .diffAdd
            } else if line.hasPrefix("-") {
                kind = .diffRemove
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ") {
                kind = .diffMeta
            } else {
                kind = .identifier // context line — plain fg
            }
            tokens.append(Token(text: line, kind: kind))
            if i < lines.count - 1 {
                tokens.append(Token(text: "\n", kind: .whitespace))
            }
        }
        return tokens
    }
}
