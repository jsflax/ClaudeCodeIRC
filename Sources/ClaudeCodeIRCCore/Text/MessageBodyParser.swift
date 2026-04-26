import Foundation

/// One segment of a parsed chat-message body. The renderer maps each
/// case to a different row type:
///   `.text`  → inline word-wrapped run
///   `.code`  → framed code block with line numbers + syntax colors
///   `.diff`  → framed diff block with +/- per-line coloring
public enum BodySegment: Equatable, Sendable {
    case text(String)
    case code(lang: String, filename: String?, body: String)
    case diff(file: String, patch: String)
}

/// Split a chat-message body into a sequence of `BodySegment`s at
/// display time. Recognises Markdown-style fenced code blocks and
/// unified-diff regions; everything else becomes a `.text` run.
///
/// Lightweight by design — picks out fenced and diff regions inside
/// otherwise-plain prose rather than parsing full Markdown. Claude's
/// assistant output regularly contains both; humans pasting either
/// get the same rendering.
public enum MessageBodyParser {

    public static func segments(_ text: String) -> [BodySegment] {
        // ```[lang [filename]]
        // …body…
        // ```
        //
        // Captures:
        //   1 — optional language slug (`swift`, `ts`, `diff`, …) —
        //       claude often emits bare ``` for grammars / generic
        //       blocks; treat the missing case as plain "code".
        //   2 — optional trailing filename (`auth/backup_codes.ts`)
        //   3 — body between the fences
        //
        // `.dotMatchesNewlines()` so `.*?` spans the full body.
        // `Regex` isn't `Sendable`, so it can't live as a module-
        // scope `static let` under strict concurrency — build per
        // call. The cost is negligible.
        let fencedCode = #/```([A-Za-z0-9_+\-]*)(?:[ \t]+([\w./+\-]+))?\n(.*?)\n```/#
            .dotMatchesNewlines()

        var out: [BodySegment] = []
        var cursor = text.startIndex
        for match in text.matches(of: fencedCode) {
            if match.range.lowerBound > cursor {
                let slice = String(text[cursor..<match.range.lowerBound])
                out.append(contentsOf: scanDiffs(in: slice))
            }
            let lang = String(match.1)
            let filename = match.2.map(String.init)
            let body = String(match.3)
            if lang.lowercased() == "diff" {
                // ```diff``` → dedicated diff block (per-line +/- coloring)
                out.append(.diff(file: filename ?? "", patch: body))
            } else {
                out.append(.code(lang: lang, filename: filename, body: body))
            }
            cursor = match.range.upperBound
        }
        if cursor < text.endIndex {
            let tail = String(text[cursor..<text.endIndex])
            out.append(contentsOf: scanDiffs(in: tail))
        }
        return coalesceText(out)
    }

    // MARK: - Diff scanning
    //
    // Looks for a run of lines starting with `diff --git a/… b/…` or
    // a lone `@@` hunk header, continuing through typical unified-
    // diff lines. Breaks at the first line that doesn't look diff-
    // shaped. Good enough for Claude's tool-call patch dumps.

    private static func scanDiffs(in text: String) -> [BodySegment] {
        let lines = text.components(separatedBy: "\n")
        var segments: [BodySegment] = []
        var textBuf: [String] = []
        var diffBuf: [String] = []
        var diffFile: String?
        var inDiff = false

        func flushText() {
            guard !textBuf.isEmpty else { return }
            let joined = textBuf.joined(separator: "\n")
            if !joined.isEmpty { segments.append(.text(joined)) }
            textBuf.removeAll(keepingCapacity: true)
        }
        func flushDiff() {
            guard !diffBuf.isEmpty else { return }
            segments.append(.diff(file: diffFile ?? "", patch: diffBuf.joined(separator: "\n")))
            diffBuf.removeAll(keepingCapacity: true)
            diffFile = nil
            inDiff = false
        }

        for line in lines {
            if inDiff {
                if isDiffLine(line) {
                    diffBuf.append(line)
                } else {
                    flushDiff()
                    textBuf.append(line)
                }
            } else if isDiffStart(line) {
                flushText()
                inDiff = true
                diffBuf.append(line)
                diffFile = fileFrom(diffGitHeader: line)
            } else {
                textBuf.append(line)
            }
        }
        flushDiff()
        flushText()
        return segments
    }

    private static func isDiffStart(_ line: String) -> Bool {
        line.hasPrefix("diff --git ") || line.hasPrefix("@@ ")
    }

    private static func isDiffLine(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        switch first {
        case "d": return line.hasPrefix("diff ")
        case "i": return line.hasPrefix("index ")
        case "-", "+": return true
        case " ": return true
        case "@": return line.hasPrefix("@@")
        default:  return false
        }
    }

    private static func fileFrom(diffGitHeader line: String) -> String? {
        // `diff --git a/foo/bar.swift b/foo/bar.swift`
        let parts = line.split(separator: " ")
        guard parts.count >= 4, parts[2].hasPrefix("a/") else { return nil }
        return String(parts[2].dropFirst(2))
    }

    // Merge any adjacent `.text` segments that ended up split by the
    // fence scan — keeps the consumer's line count stable.
    private static func coalesceText(_ segments: [BodySegment]) -> [BodySegment] {
        var out: [BodySegment] = []
        for segment in segments {
            if case .text(let s) = segment, case .text(let prev) = out.last {
                out[out.count - 1] = .text(prev + "\n" + s)
            } else {
                out.append(segment)
            }
        }
        return out
    }
}
