import ClaudeCodeIRCCore
import NCursesUI

/// Framed unified-diff block. Header shows the target file and
/// +/- line counts; each body line is painted per the diff
/// tokenizer's classification (`+` → ok, `-` → danger, `@@` →
/// accent2, meta → dim, context → fg).
struct DiffBlockView: View {
    let file: String
    let patch: String

    var body: some View {
        let lines = patch.components(separatedBy: "\n")
        let (plus, minus) = addRemoveCounts(lines)
        return VStack(spacing: 0) {
            header(plus: plus, minus: minus)
            ForEach(Array(lines.indices)) { idx in
                DiffLine(source: lines[idx])
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

    private func addRemoveCounts(_ lines: [String]) -> (Int, Int) {
        var plus = 0
        var minus = 0
        for line in lines {
            // Skip `+++` / `---` meta headers — those aren't
            // content changes.
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { plus += 1 }
            else if line.hasPrefix("-") { minus += 1 }
        }
        return (plus, minus)
    }
}

/// One row of the diff body. Colored by prefix. Not run through the
/// syntax highlighter — the visual priority is the change class,
/// not inner syntax.
struct DiffLine: View {
    let source: String

    var body: some View {
        let color: Color = {
            if source.hasPrefix("+++") || source.hasPrefix("---") { return .dim }
            if source.hasPrefix("@@") { return .cyan }
            if source.hasPrefix("+") { return .green }
            if source.hasPrefix("-") { return .red }
            if source.hasPrefix("diff ") || source.hasPrefix("index ") { return .dim }
            return .white
        }()
        var line = Text("│ ").foregroundColor(.dim)
        line = line + Text(source).foregroundColor(color)
        return line
    }
}
