import ClaudeCodeIRCCore
import Foundation
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
    /// The local member, threaded down so `AskQuestionCardView` can
    /// render the user's own ballot checkboxes.
    let selfMember: Member?
    /// Active question card focus state. WorkspaceView owns the
    /// state and decides which card (if any) is the focus target.
    let activeAskQuestionId: UUID?
    let askFocusedRow: Int
    let askPendingBallot: Set<String>
    /// Discussion thread state, plumbed through to `AskQuestionCardView`.
    @Binding var askDiscussionDraft: String
    @Binding var askDiscussionFocused: Bool
    let onAskCommentSubmit: () -> Void
    /// Currently-streaming claude turn, if any. When non-nil and no
    /// decision is pending, MessageListView injects a synthetic
    /// `.thinking` event at the bottom of the scrollback so the user
    /// sees a chat-shaped pending claude row (rather than a separate
    /// strip below the ScrollView). Nil when no turn is in flight.
    let streamingTurn: Turn?

    // @Snapshot (not @Query) — `mergedEvents` calls `Collection.map` on each
    // of these. `Collection.map` reads `count` once then iterates by index;
    // `TableResults.count`/`endIndex` are live SQL queries. A streaming-chunk
    // insert that lands mid-iteration shifts `endIndex`, the post-loop
    // `_expectEnd` check trips, and the app SIGTRAPs in libswiftCore. The
    // crash repros as "scroll while claude is thinking". @Snapshot exposes
    // a stable `[T]` array that's race-free to map.
    @Snapshot(sort: \ChatMessage.createdAt) var messages: [ChatMessage]
    @Snapshot(sort: \AssistantChunk.createdAt) var chunks: [AssistantChunk]
    @Snapshot(sort: \ApprovalRequest.requestedAt) var approvals: [ApprovalRequest]
    @Snapshot(sort: \AskQuestion.requestedAt) var askQuestions: [AskQuestion]
    @Snapshot(sort: \ToolEvent.startedAt) var toolEvents: [ToolEvent]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(mergedEvents) { event in
                switch event {
                case .message, .chunk:
                    MessageRow(event: event)
                case .approval(let req):
                    ApprovalCardView(request: req, isHost: isHost)
                case .askQuestion(let q):
                    AskQuestionCardView(
                        question: q,
                        focusedRow: askFocusedRow,
                        pendingBallot: askPendingBallot,
                        isFocused: q.globalId == activeAskQuestionId,
                        selfMember: selfMember,
                        discussionDraft: $askDiscussionDraft,
                        discussionFocused: $askDiscussionFocused,
                        onCommentSubmit: onAskCommentSubmit)
                case .toolEvent(let t):
                    ToolEventRow(event: t)
                case .thinking(let turnId, let startedAt, let tokensSoFar):
                    ThinkingMessageRow(
                        turnId: turnId,
                        startedAt: startedAt,
                        tokensSoFar: tokensSoFar)
                }
            }
        }
    }

    /// True when claude is parked in `awaitDecision` — pending
    /// approval or pending question. Suppresses the synthetic
    /// thinking row so the UI doesn't lie about activity (the
    /// approval / question card itself communicates the wait).
    private var hasPendingDecision: Bool {
        approvals.contains { $0.status == .pending }
            || askQuestions.contains { $0.status == .pending }
    }

    /// Sum of streamed-chunk text length for the current turn,
    /// converted to a rough token count (≈ 4 bytes/token for
    /// English). nil-out for `streamingTurn == nil`.
    private func streamingTokensSoFar() -> Int {
        guard let turn = streamingTurn, let id = turn.globalId else { return 0 }
        var bytes = 0
        for c in chunks where c.turn?.globalId == id {
            bytes += c.text.count
        }
        return bytes / 4
    }

    private var mergedEvents: [RoomEvent] {
        let chatEvents = messages.map { RoomEvent.message($0) }
        let chunkEvents = chunks.map { RoomEvent.chunk($0) }
        let approvalEvents = approvals.map { RoomEvent.approval($0) }
        let askEvents = visibleAskQuestions().map { RoomEvent.askQuestion($0) }
        // Skip empty-input pending tool events — those are momentary
        // states between row-create and the input-write inside
        // `ClaudeEventProcessor.openToolEvent` and would render as a
        // bare `├─ 🔧` row for one frame.
        let toolEventRows = toolEvents
            .filter { !$0.name.isEmpty }
            .map { RoomEvent.toolEvent($0) }
        var merged = (chatEvents + chunkEvents + approvalEvents + askEvents + toolEventRows)
            .sorted { $0.timestamp < $1.timestamp }
        if let floor = scrollbackFloor {
            merged = merged.filter { $0.timestamp > floor }
        }
        // Append the thinking pseudo-event at the very end so it's
        // always the last row in the scrollback while a turn is in
        // flight. Use `.distantFuture`-ish ordering by simple append
        // (post-sort) rather than threading a synthetic timestamp
        // into the sort comparator.
        if let turn = streamingTurn, !hasPendingDecision {
            merged.append(.thinking(
                turnId: turn.globalId,
                startedAt: turn.startedAt,
                tokensSoFar: streamingTokensSoFar()))
        }
        return merged
    }

    /// Sequential multi-question groups: only surface the first
    /// `.pending` member of each group, plus all already-resolved
    /// rows. Future-question rows for a group with an in-flight
    /// earlier question stay hidden so the room works on one
    /// question at a time.
    private func visibleAskQuestions() -> [AskQuestion] {
        var firstPendingByTool: [String: Int] = [:]
        for q in askQuestions where q.status == .pending {
            let prior = firstPendingByTool[q.toolUseId] ?? Int.max
            if q.groupIndex < prior {
                firstPendingByTool[q.toolUseId] = q.groupIndex
            }
        }
        return askQuestions.filter { q in
            switch q.status {
            case .answered, .cancelled:
                return true
            case .pending:
                let firstPending = firstPendingByTool[q.toolUseId] ?? q.groupIndex
                return q.groupIndex == firstPending
            }
        }
    }
}

/// Unified event stream for the scrollback.
enum RoomEvent: Identifiable {
    case message(ChatMessage)
    case chunk(AssistantChunk)
    case approval(ApprovalRequest)
    case askQuestion(AskQuestion)
    case toolEvent(ToolEvent)
    /// Synthetic, non-persisted "claude is working" row. Injected by
    /// MessageListView at the bottom of the merged list while a Turn
    /// is streaming so the spinner reads as the freshest event in
    /// chat. Carries the turn's startedAt for the elapsed clock and
    /// a rough running token count off accumulated chunks.
    case thinking(turnId: UUID?, startedAt: Date, tokensSoFar: Int)

    var id: String {
        switch self {
        case .message(let m):     return "m-\(m.globalId?.uuidString ?? "?")"
        case .chunk(let c):       return "c-\(c.globalId?.uuidString ?? "?")"
        case .approval(let a):    return "a-\(a.globalId?.uuidString ?? "?")"
        case .askQuestion(let q): return "q-\(q.globalId?.uuidString ?? "?")"
        case .toolEvent(let t):   return "t-\(t.globalId?.uuidString ?? "?")"
        case .thinking(let t, _, _): return "thinking-\(t?.uuidString ?? "current")"
        }
    }

    var timestamp: Date {
        switch self {
        case .message(let m):     return m.createdAt
        case .chunk(let c):       return c.createdAt
        case .approval(let a):    return a.requestedAt
        case .askQuestion(let q): return q.requestedAt
        case .toolEvent(let t):   return t.startedAt
        case .thinking(_, let s, _): return s
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
        case .askQuestion:
            // Same fallback rationale as .approval — AskQuestion rows
            // are routed to AskQuestionCardView in the parent.
            Text("[question card]").foregroundColor(.dim)
        case .toolEvent:
            // Routed to ToolEventRow in the parent; this branch only
            // fires if the parent forgot to special-case the enum.
            Text("[tool event]").foregroundColor(.dim)
        case .thinking:
            // Routed to ThinkingMessageRow in the parent.
            Text("[thinking]").foregroundColor(.dim)
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
            let nick = m.author?.nick ?? "?"
            authoredBody(
                time: t,
                nick: nick,
                nickColor: NickColor.color(for: nick),
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
        let color = NickColor.color(for: nick)
        var line = Text("\(time) * ").foregroundColor(.dim)
        line = line + Text("\(nick) ").foregroundColor(color)
        line = line + Text(text).foregroundColor(color)
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

/// Inline "claude is working…" pending row. Same chat shape as a
/// normal `<claude>` message — `HH:MM <claude> ✶ thinking… (Mm Ss · ↓ Nk tokens)`
/// — so it sits naturally at the bottom of scrollback while a turn
/// streams. The leading glyph cycles via the global `SpinnerTicker`,
/// elapsed time recomputes on each tick, and the token count comes
/// straight from accumulated `AssistantChunk` text so the row keeps
/// updating without any extra observation plumbing.
struct ThinkingMessageRow: View {
    let turnId: UUID?
    let startedAt: Date
    let tokensSoFar: Int

    var body: some View {
        // Reading SpinnerTicker.frame inside the body registers with
        // the observation tracker so each tick triggers a redraw.
        let frame = SpinnerTicker.shared.frame
        let glyph = Self.glyphs[frame % Self.glyphs.count]

        let elapsed = max(0, Int(Date.now.timeIntervalSince(startedAt)))
        let m = elapsed / 60
        let s = elapsed % 60
        let elapsedStr = "\(m)m \(s)s"

        let tokenStr: String
        if tokensSoFar >= 1000 {
            tokenStr = "↓ \(tokensSoFar / 1000)k tokens"
        } else if tokensSoFar > 0 {
            tokenStr = "↓ \(tokensSoFar) tokens"
        } else {
            tokenStr = ""
        }

        // While no chunks have arrived, the row reads "thinking…";
        // once tokens start streaming, drop the word and surface the
        // running counter so the user sees progress instead of a
        // stuck label.
        let body = tokensSoFar > 0
            ? "\(glyph) (\(elapsedStr) · \(tokenStr))"
            : "\(glyph) thinking… (\(elapsedStr))"

        let time = Self.timeString(startedAt)
        var line = Text("\(time) ").foregroundColor(.dim)
        line = line + Text("<@claude> ").foregroundColor(.yellow).bold()
        line = line + Text(body).foregroundColor(.magenta)
        return line
    }

    /// Six asterisk-ish glyphs the ticker rotates through. Mix of
    /// 4- / 5- / 6-pointed stars so the rotation reads as a pulsing
    /// point rather than a strict frame-by-frame progression.
    private static let glyphs: [String] = ["✶", "✱", "✳", "✴", "✷", "✦"]

    private static func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

/// Renders a single non-text BodySegment (code or diff) as its
/// dedicated view. Text segments handled directly by `MessageRow`
/// to keep the header-line fast path. File-internal access (no
/// `private`) so `ToolEventRow` can reuse the same renderer for
/// sub-agent (Task) result bodies.
struct SegmentView: View {
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
