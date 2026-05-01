import ClaudeCodeIRCCore
import Foundation
import class Lattice.TableResults
import NCursesUI

/// Inline card for an `AskQuestion`. Wraps the question header (which
/// can be multi-paragraph markdown — used by ExitPlanMode plans) in
/// an option list with focus marker + checkboxes. Display-only: the
/// parent (`WorkspaceView`) owns row-focus state and writes ballots /
/// appended options on keypress.
///
/// Card chrome (top/bottom borders, reverse-video header chip,
/// inner divider before footer) is delegated to NCursesUI's
/// `CardView` — this file just supplies the title / trailing /
/// content / footer payloads. Width is dynamic to the layout pass
/// so terminal resize naturally reflows.
struct AskQuestionCardView: View {
    let question: AskQuestion
    /// Currently-focused row index, owned by `WorkspaceView` so the
    /// state persists across the lattice-change re-renders that
    /// recreate this view on every vote.
    let focusedRow: Int
    /// Multi-select local pending ballot (committed via Tab). Empty
    /// for single-select.
    let pendingBallot: Set<String>
    /// Whether the card is the active focus target. Drives the `▸`
    /// marker visibility — non-active cards in a stacked layout
    /// dim out the focus indicator.
    let isFocused: Bool
    /// The local member, used to identify "this client's vote" for
    /// the `[x]` checkbox column.
    let selfMember: Member?

    /// Discussion thread state, owned by `WorkspaceView`. When
    /// `discussionFocused == true` the inline TextField at the bottom
    /// of the card captures keys; when false, arrow/Enter/Space route
    /// to the option list. The `comments` `List<AskComment>` itself
    /// fires the parent's `.update` observer on append (see Lattice
    /// `crossProcessListAppend` test) so peer-side comment inserts
    /// re-render this view without a separate `@Query` dependency.
    @Binding var discussionDraft: String
    @Binding var discussionFocused: Bool
    /// Called when the user presses Enter on a non-empty draft.
    /// `WorkspaceView` writes the `AskComment` since it owns the
    /// lattice handle.
    let onCommentSubmit: () -> Void

    @Query var members: TableResults<Member>
    /// Drives re-render when peers' AskVotes arrive via Lattice sync.
    /// `question.votes` is a `@Relation` backlink — traversing it
    /// reads the rows but doesn't subscribe to inserts in NCursesUI's
    /// observation tracker, so a peer-side vote arriving via sync
    /// invalidates the question row but not THIS view. An explicit
    /// `@Query` on the vote model forces a re-render whenever any
    /// AskVote inserts/updates; the body still reads `question.votes`
    /// so the filtering stays correct.
    @Query var allAskVotes: TableResults<AskVote>

    /// Sentinel row index for the trailing "Other…" entry. Lives just
    /// past `question.options.count`.
    var otherRowIndex: Int { question.options.count }

    var body: some View {
        CardView(
            title: Text("claude is asking"),
            trailing: Text(statusLabelWithGroup).paletteColor(statusRole),
            footer: footerLine,
            accent: accentRole,
            content: { contentBody }
        )
    }

    // MARK: - Header bits

    private var statusLabelWithGroup: String {
        let base = statusLabel
        return question.groupSize > 1
            ? "\(base) (\(question.groupIndex + 1)/\(question.groupSize))"
            : base
    }

    // MARK: - Content body

    @ViewBuilder
    private var contentBody: some View {
        VStack(spacing: 0) {
            questionBody
            SpacerView(1)
            ForEach(Array(question.options.indices)) { idx in
                optionRow(idx: idx, option: question.options[idx])
            }
            otherRow
            discussionBlock
        }
    }

    /// Inline thread + composer. Always rendered for `.pending`
    /// questions so the affordance is discoverable even when the
    /// thread is empty. Tab toggles focus between the option list and
    /// the composer; the focus marker (`▸`) on the composer line and
    /// the dimmed option-list markers reflect that state.
    @ViewBuilder
    private var discussionBlock: some View {
        if question.status == .pending {
            SpacerView(1)
            let dividerRole: Palette.Role = discussionFocused ? .accent : .dim
            Text("─── discussion ───").paletteColor(dividerRole)
            ForEach(Array(question.comments)) { c in
                let nick = c.author?.nick ?? "?"
                Text("  <\(nick)> ").foregroundColor(NickColor.color(for: nick))
                    + Text(c.text).foregroundColor(.dim)
            }
            HStack {
                let myNick = selfMember?.nick ?? "you"
                let markerRole: Palette.Role = discussionFocused ? .accent : .dim
                Text(discussionFocused ? "▸ " : "  ").paletteColor(markerRole)
                Text("<\(myNick)> ").foregroundColor(NickColor.color(for: myNick))
                TextField("",
                          text: $discussionDraft,
                          isFocused: $discussionFocused,
                          onSubmit: onCommentSubmit)
            }
        }
    }

    /// The question header — typically just one line for AskUserQuestion
    /// but multi-paragraph markdown for ExitPlanMode plans. Pipe through
    /// `MessageBodyParser` so fenced code blocks and unified diffs render
    /// in their own framed views; reflow `.text` segments paragraph-wise
    /// so soft-wrapped prose collapses to space (lets NCursesUI wrap
    /// against terminal width) while preserving headings, list items,
    /// and blockquotes as standalone rows.
    @ViewBuilder
    private var questionBody: some View {
        let segments = MessageBodyParser.segments(question.header)
        ForEach(Array(segments.enumerated())
            .map { IndexedQuestionSegment(index: $0.offset, segment: $0.element) }
        ) { entry in
            switch entry.segment {
            case .text(let s):
                paragraphFlow(s)
            case .code(let lang, let filename, let body):
                CodeBlockView(lang: lang, filename: filename, source: body)
            case .diff(let file, let patch):
                DiffBlockView(file: file, patch: patch)
            }
        }
    }

    /// Render a `.text` segment as a sequence of paragraph rows.
    /// Each paragraph collapses internal soft-wrap newlines to spaces
    /// so NCursesUI's word-wrap can reflow against the actual card
    /// width; standalone lines (headings, lists, blockquotes) stay
    /// as their own rows.
    @ViewBuilder
    private func paragraphFlow(_ text: String) -> some View {
        let paragraphs = Self.reflowParagraphs(text)
        ForEach(Array(paragraphs.enumerated())
            .map { IndexedParagraph(index: $0.offset, line: $0.element) }
        ) { entry in
            Text(markdown: entry.line)
        }
    }

    /// Group consecutive lines into "paragraphs" — soft-wrapped prose
    /// merges into one long string (NCursesUI re-wraps to width),
    /// while lines that are semantically standalone (empty, headings,
    /// list items, blockquotes) stay separate.
    static func reflowParagraphs(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var buf: [String] = []

        func flush() {
            guard !buf.isEmpty else { return }
            out.append(buf.joined(separator: " "))
            buf.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                out.append("") // preserve blank line as paragraph break
                continue
            }
            if isStandaloneLine(trimmed) {
                flush()
                out.append(line)
                continue
            }
            buf.append(line)
        }
        flush()
        return out
    }

    /// Lines that should NOT merge into a wrapped paragraph — block-level
    /// markdown that has its own visual identity. Headings (`# `..`#### `),
    /// bullet lists (`- `, `* `, `+ `), numbered lists (`1. `), and
    /// blockquotes (`> `).
    private static func isStandaloneLine(_ line: String) -> Bool {
        if line.hasPrefix("# ") || line.hasPrefix("## ")
            || line.hasPrefix("### ") || line.hasPrefix("#### ") { return true }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return true
        }
        if line.hasPrefix("> ") { return true }
        // Numbered list: optional whitespace + digits + dot + space.
        return line.firstMatch(of: #/^\s*\d+\. /#) != nil
    }

    // MARK: - Option rows

    private func optionRow(idx: Int, option: AskOption) -> Text {
        let isFocusedRow = isFocused && idx == focusedRow
        let isChecked = isLabelChecked(option.label)
        let voters = votersFor(label: option.label)

        // When discussion has focus, dim the option-list marker so the
        // user sees focus has moved off the ballot.
        let markerRole: Palette.Role = discussionFocused ? .dim : .accent
        var line = Text(isFocusedRow ? "▸ " : "  ").paletteColor(markerRole)
        line = line + Text(isChecked ? "[x] " : "[ ] ")
            .paletteColor(isChecked ? .ok : .mute)
        line = line + Text(option.label).paletteColor(.fg)
        if !option.submittedByNick.isEmpty {
            line = line + Text(" — by ").paletteColor(.dim)
            line = line + Text(option.submittedByNick).paletteColor(.dim)
        }
        if !voters.isEmpty {
            line = line + Text("   ").paletteColor(.dim)
            line = line + Text(voters.joined(separator: ", ")).paletteColor(.dim)
        }
        return line
    }

    private var otherRow: Text {
        let isFocusedRow = isFocused && focusedRow == otherRowIndex
        let markerRole: Palette.Role = discussionFocused ? .dim : .accent
        var line = Text(isFocusedRow ? "▸ " : "  ").paletteColor(markerRole)
        line = line + Text("[ ] ").paletteColor(.mute)
        line = line + Text("Other… (type answer)").paletteColor(.dim)
        return line
    }

    // MARK: - Footer

    private var footerLine: Text {
        let presentQuorum = members.filter { !$0.isAway }.count
        let ballotCount = uniqueBallotVoters().count

        switch question.status {
        case .pending:
            var line = Text("quorum: ").paletteColor(.dim)
            line = line + Text("\(ballotCount) / \(presentQuorum)")
                .paletteColor(.accent)
            line = line + Text("   ").paletteColor(.dim)
            if question.multiSelect {
                line = line + Text("↑/↓ move · Enter toggle · Space commit · Tab focus")
                    .paletteColor(.dim)
            } else {
                line = line + Text("↑/↓ move · Enter vote · Tab focus")
                    .paletteColor(.dim)
            }
            return line
        case .answered:
            return answeredFooterLine()
        case .cancelled:
            var line = Text("✗ cancelled").paletteColor(.danger)
            if !question.cancelReason.isEmpty {
                line = line + Text(" — \(question.cancelReason)")
                    .paletteColor(.dim)
            }
            return line
        }
    }

    private func answeredFooterLine() -> Text {
        if question.chosenLabels.isEmpty {
            return Text("✓ answered: none of the options (by quorum)")
                .paletteColor(.ok)
        }
        let quoted = question.chosenLabels.map { "\"\($0)\"" }.joined(separator: ", ")
        var l = Text("✓ answered: ").paletteColor(.ok)
        l = l + Text(quoted).paletteColor(.ok).bold()
        l = l + Text(" (by quorum)").paletteColor(.dim)
        return l
    }

    // MARK: - Tally helpers

    /// Filter the top-level `@Query var allAskVotes` by this question
    /// — does the same job as `question.votes` (the `@Relation`
    /// backlink) but **reads** the `@Query` wrapper, so NCursesUI's
    /// observation tracker subscribes the view to vote
    /// inserts/updates. Reading the backlink alone doesn't subscribe
    /// (the relation traversal returns rows but bypasses the
    /// wrapper's `value` getter), so vote arrivals during the
    /// pending phase didn't trigger a re-render — the count only
    /// refreshed when the question terminated.
    private func votesForQuestion() -> [AskVote] {
        guard let qid = question.globalId else { return [] }
        return allAskVotes.filter { $0.question?.globalId == qid }
    }

    /// True when this client should render `[x]` for `label`. For
    /// multi-select pending-state, the local pendingBallot is the
    /// authoritative view (uncommitted toggles are visible only here).
    /// For single-select, fall through to the persisted vote.
    private func isLabelChecked(_ label: String) -> Bool {
        if question.multiSelect, !pendingBallot.isEmpty {
            return pendingBallot.contains(label)
        }
        for vote in votesForQuestion() where vote.voter?.globalId == selfGlobalId {
            return vote.chosenLabels.contains(label)
        }
        return false
    }

    private var selfGlobalId: UUID? { selfMember?.globalId }

    private func votersFor(label: String) -> [String] {
        var nicks: [String] = []
        for vote in votesForQuestion() {
            guard let nick = vote.voter?.nick else { continue }
            if vote.chosenLabels.contains(label), !nicks.contains(nick) {
                nicks.append(nick)
            }
        }
        nicks.sort()
        return nicks
    }

    private func uniqueBallotVoters() -> Set<UUID> {
        var ids: Set<UUID> = []
        for vote in votesForQuestion() {
            if let gid = vote.voter?.globalId { ids.insert(gid) }
        }
        return ids
    }

    // MARK: - Styling

    private var statusLabel: String {
        switch question.status {
        case .pending:   return "pending"
        case .answered:  return "answered"
        case .cancelled: return "cancelled"
        }
    }

    private var statusRole: Palette.Role {
        switch question.status {
        case .pending:   return .accent
        case .answered:  return .ok
        case .cancelled: return .danger
        }
    }

    private var accentRole: Palette.Role {
        question.status == .pending ? .accent : .mute
    }
}

/// Identifiable wrapper for ForEach over `[BodySegment]` (segments
/// have no natural id). Mirrors `IndexedSegment` in `MessageListView`
/// — kept private here so the two views stay decoupled.
private struct IndexedQuestionSegment: Identifiable {
    let index: Int
    let segment: BodySegment
    var id: Int { index }
}

/// Identifiable wrapper for paragraph-flow lines.
private struct IndexedParagraph: Identifiable {
    let index: Int
    let line: String
    var id: Int { index }
}
