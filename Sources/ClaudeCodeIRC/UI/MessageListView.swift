import ClaudeCodeIRCCore
import Foundation
import class Lattice.TableResults
import NCursesUI

/// Time-merged stream of user/system chat messages and assistant
/// chunks in the active room. Replaces the inline ForEach that used
/// to live on RoomView; the richer rendering (code blocks, diff
/// cards, per-nick colors) lands in D6/D8.
///
/// Reads both Lattice tables through `@Query` — the view re-renders
/// automatically when a peer upload or local write changes either.
struct MessageListView: View {
    let isHost: Bool

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
        return (chatEvents + chunkEvents + approvalEvents)
            .sorted { $0.timestamp < $1.timestamp }
    }
}

/// Unified event stream for the scrollback. Proper tool-event rows +
/// turn separators land in later phases; this covers the primary
/// chat + assistant + approval-card mix.
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

/// One row in the scrollback. Time prefix, author (colored), body.
/// System messages render as `-- <body>`; action messages (`/me`)
/// italic-accented; assistant chunks prefixed with `@claude`.
struct MessageRow: View {
    let event: RoomEvent

    var body: some View {
        switch event {
        case .message(let m):
            return rowFor(m)
        case .chunk(let c):
            return chunkRow(c)
        case .approval:
            // Approval rows render via ApprovalCardView in the parent —
            // MessageRow is the text-row fallback. Emit a dim marker so
            // the row slot isn't empty if the parent ever forgets to
            // branch on .approval.
            return Text("[approval card]").foregroundColor(.dim)
        }
    }

    private func rowFor(_ m: ChatMessage) -> Text {
        let t = Self.timeString(m.createdAt)
        switch m.kind {
        case .system:
            var line = Text("\(t) ").foregroundColor(.dim)
            line = line + Text("-- ").foregroundColor(.dim)
            line = line + Text(m.text).foregroundColor(.dim)
            return line
        case .action:
            var line = Text("\(t) * ").foregroundColor(.dim)
            line = line + Text("\(m.author?.nick ?? "?") ").foregroundColor(.cyan)
            line = line + Text(m.text).foregroundColor(.cyan)
            return line
        case .user, .assistant:
            var line = Text("\(t) ").foregroundColor(.dim)
            line = line + Text("<\(m.author?.nick ?? "?")> ").foregroundColor(.cyan).bold()
            line = line + highlightedBody(m.text)
            return line
        }
    }

    private func chunkRow(_ c: AssistantChunk) -> Text {
        let t = Self.timeString(c.createdAt)
        var line = Text("\(t) ").foregroundColor(.dim)
        line = line + Text("<@claude> ").foregroundColor(.yellow).bold()
        line = line + Text(c.text)
        return line
    }

    /// Highlight `@claude`, `@claude-sonnet`, `@claude-haiku` mentions
    /// inline — accent-colored + bold, no background fill (the design
    /// iterated away from reverse-video chips).
    private func highlightedBody(_ text: String) -> Text {
        let pattern = #"@claude(?:-sonnet|-haiku)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return Text(text)
        }
        let ns = text as NSString
        var cursor = 0
        var out = Text("")
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let r = m.range
            if r.location > cursor {
                out = out + Text(ns.substring(with: NSRange(
                    location: cursor, length: r.location - cursor)))
            }
            out = out + Text(ns.substring(with: r))
                .foregroundColor(.yellow)
                .bold()
            cursor = r.location + r.length
        }
        if cursor < ns.length {
            out = out + Text(ns.substring(with: NSRange(
                location: cursor, length: ns.length - cursor)))
        }
        return out
    }

    private static func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
