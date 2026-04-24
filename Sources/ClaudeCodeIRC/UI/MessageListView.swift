import ClaudeCodeIRCCore
import Foundation
import class Lattice.TableResults
import NCursesUI

/// Time-merged stream of user/system chat messages, assistant chunks,
/// and approval cards for the active room. Reads via `@Query` so
/// peer uploads and local writes trigger re-renders automatically.
///
/// Message bodies pass through `MessageBodyParser` at render time —
/// fenced code blocks become `CodeBlockView`s, unified diffs become
/// `DiffBlockView`s, plain prose stays as a single-line Text run.
struct MessageListView: View {
    let isHost: Bool
    /// Local-only scrollback cutoff set by `/clear`. Events with
    /// timestamps at or before this are hidden in this client; rows
    /// stay in the lattice so sync is unaffected.
    let scrollbackFloor: Date?

    @Query(sort: \ChatMessage.createdAt) var messages: TableResults<ChatMessage>
    @Query(sort: \AssistantChunk.createdAt) var chunks: TableResults<AssistantChunk>
    @Query(sort: \ApprovalRequest.requestedAt) var approvals: TableResults<ApprovalRequest>

    var body: some View {
        VStack(spacing: 0) {
            ForEach(mergedEvents) { event in
                switch event {
                case .message, .chunk:
                    MessageRow(event: event)
                case .approval(let req):
                    ApprovalCardView(request: req, isHost: isHost)
                }
            }
        }
    }

    private var mergedEvents: [RoomEvent] {
        let chatEvents = messages.map { RoomEvent.message($0) }
        let chunkEvents = chunks.map { RoomEvent.chunk($0) }
        let approvalEvents = approvals.map { RoomEvent.approval($0) }
        let merged = (chatEvents + chunkEvents + approvalEvents)
            .sorted { $0.timestamp < $1.timestamp }
        guard let floor = scrollbackFloor else { return merged }
        return merged.filter { $0.timestamp > floor }
    }
}

/// Unified event stream for the scrollback.
enum RoomEvent: Identifiable {
    case message(ChatMessage)
    case chunk(AssistantChunk)
    case approval(ApprovalRequest)

    var id: String {
        switch self {
        case .message(let m):  return "m-\(m.globalId?.uuidString ?? "?")"
        case .chunk(let c):    return "c-\(c.globalId?.uuidString ?? "?")"
        case .approval(let a): return "a-\(a.globalId?.uuidString ?? "?")"
        }
    }

    var timestamp: Date {
        switch self {
        case .message(let m):  return m.createdAt
        case .chunk(let c):    return c.createdAt
        case .approval(let a): return a.requestedAt
        }
    }
}

/// One row in the scrollback. Header (time + author) + body, where
/// the body is `MessageBodyParser.segments(...)` rendered as Text
/// runs for `.text` segments and dedicated views for `.code` / `.diff`.
struct MessageRow: View {
    let event: RoomEvent

    @ViewBuilder var body: some View {
        switch event {
        case .message(let m):
            messageBody(m)
        case .chunk(let c):
            chunkBody(c)
        case .approval:
            // Approval rows render via ApprovalCardView in the parent —
            // MessageRow is the text-row fallback. Emit a dim marker so
            // the slot isn't empty if the parent ever forgets to
            // branch on .approval.
            Text("[approval card]").foregroundColor(.dim)
        }
    }

    // MARK: - Message / chunk assembly

    @ViewBuilder private func messageBody(_ m: ChatMessage) -> some View {
        let t = Self.timeString(m.createdAt)
        switch m.kind {
        case .system:
            systemLine(time: t, text: m.text)
        case .action:
            actionLine(time: t, nick: m.author?.nick ?? "?", text: m.text)
        case .user, .assistant:
            authoredBody(
                time: t,
                nick: m.author?.nick ?? "?",
                nickColor: .cyan,
                text: m.text)
        }
    }

    @ViewBuilder private func chunkBody(_ c: AssistantChunk) -> some View {
        authoredBody(
            time: Self.timeString(c.createdAt),
            nick: "@claude",
            nickColor: .yellow,
            text: c.text)
    }

    // MARK: - Line shapes

    private func systemLine(time: String, text: String) -> Text {
        var line = Text("\(time) ").foregroundColor(.dim)
        line = line + Text("-- ").foregroundColor(.dim)
        line = line + Text(text).foregroundColor(.dim)
        return line
    }

    private func actionLine(time: String, nick: String, text: String) -> Text {
        var line = Text("\(time) * ").foregroundColor(.dim)
        line = line + Text("\(nick) ").foregroundColor(.cyan)
        line = line + Text(text).foregroundColor(.cyan)
        return line
    }

    /// Render header (`HH:MM <nick>`) + body. The body is parsed into
    /// segments; single-text bodies stay on the header line,
    /// multi-segment bodies break onto separate rows so code / diff
    /// blocks get their own framed real-estate.
    @ViewBuilder
    private func authoredBody(
        time: String,
        nick: String,
        nickColor: Color,
        text: String
    ) -> some View {
        let segments = MessageBodyParser.segments(text)
        let inlineOnly = segments.allSatisfy {
            if case .text = $0 { return true }; return false
        }
        if inlineOnly {
            // Fast path — all text, render on a single (word-wrapped) row.
            headerPlusInline(time: time, nick: nick, nickColor: nickColor, text: text)
        } else {
            VStack(spacing: 0) {
                headerPlusInline(
                    time: time, nick: nick, nickColor: nickColor,
                    text: leadingText(of: segments))
                ForEach(Array(remainingSegments(of: segments).enumerated())
                    .map { IndexedSegment(index: $0.offset, segment: $0.element) }
                ) { pair in
                    SegmentView(segment: pair.segment)
                }
            }
        }
    }

    private func headerPlusInline(
        time: String, nick: String, nickColor: Color, text: String
    ) -> Text {
        var line = Text("\(time) ").foregroundColor(.dim)
        line = line + Text("<\(nick)> ").foregroundColor(nickColor).bold()
        line = line + highlightedBody(text)
        return line
    }

    /// First `.text` segment if the body starts with one — that's
    /// what goes on the header row. Subsequent segments render
    /// below.
    private func leadingText(of segments: [BodySegment]) -> String {
        if case .text(let s) = segments.first { return s }
        return ""
    }

    private func remainingSegments(of segments: [BodySegment]) -> [BodySegment] {
        guard case .text = segments.first else { return segments }
        return Array(segments.dropFirst())
    }

    /// Highlight `@claude`, `@claude-sonnet`, `@claude-haiku` mentions
    /// inline — accent-colored + bold.
    private func highlightedBody(_ text: String) -> Text {
        let mention = #/@claude(?:-sonnet|-haiku)?\b/#
        var out = Text("")
        var cursor = text.startIndex
        for match in text.matches(of: mention) {
            if match.range.lowerBound > cursor {
                out = out + Text(String(text[cursor..<match.range.lowerBound]))
            }
            out = out + Text(String(text[match.range]))
                .foregroundColor(.yellow)
                .bold()
            cursor = match.range.upperBound
        }
        if cursor < text.endIndex {
            out = out + Text(String(text[cursor..<text.endIndex]))
        }
        return out
    }

    private static func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

/// Tiny Identifiable wrapper so ForEach can iterate an enumerated
/// sequence of BodySegments. Segments themselves aren't Identifiable
/// (they're enum payload-wrapped Strings / structs, no natural id).
private struct IndexedSegment: Identifiable {
    let index: Int
    let segment: BodySegment
    var id: Int { index }
}

/// Renders a single non-text BodySegment (code or diff) as its
/// dedicated view. Text segments handled directly by `MessageRow`
/// to keep the header-line fast path.
private struct SegmentView: View {
    let segment: BodySegment

    @ViewBuilder var body: some View {
        switch segment {
        case .text(let s):
            Text(s)
        case .code(let lang, let filename, let body):
            CodeBlockView(lang: lang, filename: filename, source: body)
        case .diff(let file, let patch):
            DiffBlockView(file: file, patch: patch)
        }
    }
}
