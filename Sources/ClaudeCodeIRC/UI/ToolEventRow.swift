import ClaudeCodeIRCCore
import Foundation
import NCursesUI

/// One row per `ToolEvent` in the chat scrollback. Renders with a
/// tree-style prefix (`├─`/`└─`) + per-tool icon + a single-line
/// preview of input + result. Status drives the colour of both the
/// prefix and the result block (running=yellow, ok=green,
/// errored/denied=red).
///
/// Layout (one-line tools, 99% of cases):
/// ```
/// 14:03 ├─ 📖 Read     Package.swift
///       └─        ✓    "// swift-tools-version:6.0\nimport PackageDescription…"
/// ```
/// For `Task` (sub-agent) tool calls, the result expands into a
/// multi-segment block via `MessageBodyParser` so fenced code +
/// diffs in the agent's output render cleanly. Other tools stay
/// truncated to a single line.
struct ToolEventRow: View {
    let event: ToolEvent

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if event.status != .running, event.status != .pending {
                resultBlock
            }
        }
    }

    // MARK: - Header (always shown)

    private var headerRow: Text {
        let time = Self.timeString(event.startedAt)
        var line = Text("\(time) ").paletteColor(.dim)
        line = line + Text("├─ ").paletteColor(prefixRole)
        line = line + Text("\(icon) ").paletteColor(prefixRole)
        line = line + Text(event.name).bold().paletteColor(.accent)
        let preview = inputPreview()
        if !preview.isEmpty {
            line = line + Text("  ").paletteColor(.dim)
            line = line + Text(preview).paletteColor(.dim)
        }
        return line
    }

    // MARK: - Result (rendered after a non-pending row)

    @ViewBuilder
    private var resultBlock: some View {
        let mark = statusGlyph
        if event.name == "TodoWrite" {
            // Inline checklist — claude's TodoWrite payload IS the
            // semantically interesting part (the result is just
            // ack); render the input.todos array as `[ ]/[x]/[~]`
            // rows below the tool header.
            todoListBlock(mark: mark)
        } else if event.name == "Task", let r = event.result, !r.isEmpty {
            // Task sub-agent — render the full multi-segment result
            // body (the parent's stream-json doesn't surface the
            // sub-agent's individual tool calls, but the result text
            // often contains formatted markdown. Pass through
            // MessageBodyParser so fenced code / diffs land cleanly).
            let segments = MessageBodyParser.segments(r)
            VStack(spacing: 0) {
                resultHeaderLine(mark: mark, body: leadingText(segments))
                ForEach(Array(remainingSegments(segments).enumerated())
                    .map { IndexedToolSegment(index: $0.offset, segment: $0.element) }
                ) { pair in
                    SegmentView(segment: pair.segment)
                }
            }
        } else if ToolDiffPreview.supportedTools.contains(event.name) {
            // Write / Edit / MultiEdit all share one rationale: the
            // tool's `result` body is a one-line ack, but the
            // semantically interesting payload is the bytes the tool
            // changed. `ToolDiffPreview` normalises the three input
            // shapes; `DiffBlockView` renders the synthesized patch
            // (same component body segments use, so visual treatment
            // stays consistent across surfaces).
            diffPreviewBlock(mark: mark)
        } else {
            // Standard tool — single-line preview of result (or "—"
            // when no result text was returned, e.g. tools that
            // signal status only).
            resultHeaderLine(mark: mark, body: resultPreview())
        }
    }

    /// Unified renderer for any tool whose semantically interesting
    /// payload is "I changed bytes in this file" — Write (pure add),
    /// Edit (one old/new), MultiEdit (many olds/news). Both the
    /// parsing (`ToolDiffPreview.parse`) and the visual treatment
    /// (`DiffBlockView`) are shared with `ApprovalCardView` so the
    /// pre-decision and post-execution previews look identical.
    @ViewBuilder
    private func diffPreviewBlock(mark: String) -> some View {
        // Pass `event.resultMeta` so a Write that overwrites an
        // existing file picks up `toolUseResult.originalFile` and
        // claude code's pre-baked `structuredPatch` (which carries
        // context lines around the hunks, like claude code's own UI
        // shows) instead of falling back to a context-less synthesized
        // diff.
        let parsed = ToolDiffPreview.parse(event.input, resultMeta: event.resultMeta)
        let summary = parsed.map { ToolDiffPreview.summary(for: $0) } ?? "(empty)"
        VStack(spacing: 0) {
            resultHeaderLine(mark: mark, body: summary)
            if let parsed, let patch = ToolDiffPreview.renderablePatch(parsed) {
                DiffBlockView(file: parsed.path, patch: patch)
            }
        }
    }

    /// Render TodoWrite's `input.todos: [{content, status, ...}]`
    /// as a checklist. Mirrors Claude Code's official rendering: a
    /// leading `⎿` anchor on the first row and `◼`/`◻`/`✔` glyphs for
    /// in-progress / pending / completed items. To keep the strip
    /// readable on long-running tasks, completed items collapse — only
    /// the most recent two are shown verbatim and the rest fold into a
    /// trailing `… +N completed` summary row.
    @ViewBuilder
    private func todoListBlock(mark _: String) -> some View {
        let items = todoItems()
        let completedIndices = items.enumerated()
            .filter { $0.element.status == "completed" }
            .map { $0.offset }
        // "Most recent" = last 2 completed in array order. Claude appends
        // completed items after marking them done, so the suffix gives
        // the user the freshest two.
        let visibleCompleted = Set(completedIndices.suffix(2))
        let collapsedCount = max(0, completedIndices.count - 2)

        let visibleItems = items.enumerated().filter { offset, item in
            switch item.status {
            case "completed": return visibleCompleted.contains(offset)
            default:          return true
            }
        }.map(\.element)

        VStack(spacing: 0) {
            // First row owns the ⎿ anchor + the first item (or a
            // fallback message when the input had no items).
            if let first = visibleItems.first {
                todoRow(first, isAnchor: true)
            } else {
                anchorOnlyRow(label: collapsedCount > 0
                    ? "… +\(collapsedCount) completed"
                    : "(no todos)")
            }
            ForEach(Array(visibleItems.dropFirst().enumerated())
                .map { IndexedTodo(index: $0.offset, item: $0.element) }
            ) { pair in
                todoRow(pair.item, isAnchor: false)
            }
            if !visibleItems.isEmpty, collapsedCount > 0 {
                summaryRow(count: collapsedCount)
            }
        }
    }

    /// Indent + ⎿ for the anchor row; pure indent for follow-on rows so
    /// glyphs line up vertically.
    private static let todoAnchorIndent = "        ⎿  "
    private static let todoBodyIndent   = "           "

    private func todoRow(_ item: TodoItem, isAnchor: Bool) -> Text {
        var line = Text(isAnchor ? Self.todoAnchorIndent : Self.todoBodyIndent)
            .paletteColor(.dim)
        let glyph: String
        let glyphRole: Palette.Role
        switch item.status {
        case "completed":
            glyph = "✔"
            glyphRole = .ok
        case "in_progress":
            glyph = "◼"
            glyphRole = .accent
        default:
            glyph = "◻"
            glyphRole = .mute
        }
        line = line + Text("\(glyph) ").paletteColor(glyphRole)
        // Completed text dims so the eye lands on in-progress / pending.
        let textRole: Palette.Role = item.status == "completed" ? .dim : .fg
        line = line + Text(item.content).paletteColor(textRole)
        return line
    }

    private func anchorOnlyRow(label: String) -> Text {
        var line = Text(Self.todoAnchorIndent).paletteColor(.dim)
        line = line + Text(label).paletteColor(.dim)
        return line
    }

    private func summaryRow(count: Int) -> Text {
        var line = Text(Self.todoBodyIndent).paletteColor(.dim)
        line = line + Text("… +\(count) completed").paletteColor(.dim)
        return line
    }

    private func todoItems() -> [TodoItem] {
        guard let obj = parseJsonObject(event.input),
              let arr = obj["todos"] as? [[String: Any]]
        else { return [] }
        return arr.compactMap { dict in
            let content = (dict["content"] as? String)
                ?? (dict["activeForm"] as? String)
                ?? ""
            guard !content.isEmpty else { return nil }
            return TodoItem(
                content: content,
                status: (dict["status"] as? String) ?? "pending")
        }
    }

    private func resultHeaderLine(mark: String, body: String) -> Text {
        var line = Text("      ").paletteColor(.dim)  // align under HH:MM
        line = line + Text("└─ ").paletteColor(prefixRole)
        line = line + Text("\(mark) ").paletteColor(statusRole)
        if !body.isEmpty {
            line = line + Text(body).paletteColor(.dim)
        }
        return line
    }

    // MARK: - Previews

    /// One-line summary of the tool's input via the shared
    /// `ToolInputSummary` helper.
    private func inputPreview() -> String {
        ToolInputSummary.summarise(event.input)
    }

    private func resultPreview() -> String {
        guard let r = event.result, !r.isEmpty else {
            return event.status == .errored ? "(no error message)" : ""
        }
        let firstLine = r.split(whereSeparator: \.isNewline).first.map(String.init) ?? r
        return Self.truncate(firstLine, to: 100)
    }

    // MARK: - Status styling

    private var icon: String { Self.iconFor(event.name) }

    private var prefixRole: Palette.Role {
        switch event.status {
        case .running, .pending: return .accent
        case .ok:                return .ok
        case .errored, .denied:  return .danger
        }
    }

    private var statusRole: Palette.Role {
        switch event.status {
        case .running, .pending: return .accent
        case .ok:                return .ok
        case .errored, .denied:  return .danger
        }
    }

    private var statusGlyph: String {
        switch event.status {
        case .running, .pending: return "…"
        case .ok:                return "✓"
        case .errored:           return "✗"
        case .denied:            return "⊘"
        }
    }

    // MARK: - Static helpers

    /// Per-tool emoji glyph. Default `🔧` for anything unrecognised
    /// — keeps rows distinguishable while letting future tools land
    /// without code changes.
    static func iconFor(_ tool: String) -> String {
        switch tool {
        case "Read":            return "📖"
        case "Write":           return "📝"
        case "Edit", "MultiEdit", "NotebookEdit": return "✏️"
        case "Bash", "BashOutput": return "▶️"
        case "Grep":            return "🔍"
        case "Glob":            return "📂"
        case "Task":            return "🤖"
        case "WebFetch":        return "🌐"
        case "WebSearch":       return "🔎"
        case "TodoWrite":       return "✅"
        case "AskUserQuestion": return "❓"
        case "ExitPlanMode":    return "🗒️"
        default:                return "🔧"
        }
    }

    private static func truncate(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit - 1)) + "…"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func timeString(_ d: Date) -> String {
        timeFormatter.string(from: d)
    }

    private func parseJsonObject(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Segment helpers (mirror MessageListView's locals)

    private func leadingText(_ segments: [BodySegment]) -> String {
        if case .text(let s) = segments.first { return s }
        return ""
    }

    private func remainingSegments(_ segments: [BodySegment]) -> [BodySegment] {
        guard case .text = segments.first else { return segments }
        return Array(segments.dropFirst())
    }
}

/// Identifiable wrapper for ForEach over `[BodySegment]` (segments
/// have no natural id). Mirrors `IndexedSegment` in MessageListView
/// — kept private to this file so the two row types stay decoupled.
private struct IndexedToolSegment: Identifiable {
    let index: Int
    let segment: BodySegment
    var id: Int { index }
}

/// One entry from a `TodoWrite` invocation. Shape matches claude's
/// schema (`content`, `status`, optionally `activeForm`).
private struct TodoItem {
    let content: String
    let status: String
}

private struct IndexedTodo: Identifiable {
    let index: Int
    let item: TodoItem
    var id: Int { index }
}
