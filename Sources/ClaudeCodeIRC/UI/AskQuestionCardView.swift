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

    @Query var members: TableResults<Member>

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
            questionLines
            SpacerView(1)
            ForEach(Array(question.options.indices)) { idx in
                optionRow(idx: idx, option: question.options[idx])
            }
            otherRow
        }
    }

    /// Each line of the (possibly multi-paragraph) question header
    /// rendered through `Text(markdown:)` so `**bold**`, backtick code,
    /// and `# heading` style cleanly. Pre-split on `\n` so embedded
    /// newlines don't fall through to NCursesUI's wrap path
    /// (which can drop the `│` left frame on continuation rows).
    @ViewBuilder
    private var questionLines: some View {
        let lines = question.header.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        ForEach(Array(lines.indices)) { idx in
            Text(markdown: lines[idx])
        }
    }

    // MARK: - Option rows

    private func optionRow(idx: Int, option: AskOption) -> Text {
        let isFocusedRow = isFocused && idx == focusedRow
        let isChecked = isLabelChecked(option.label)
        let voters = votersFor(label: option.label)

        var line = Text(isFocusedRow ? "▸ " : "  ").paletteColor(.accent)
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
        var line = Text(isFocusedRow ? "▸ " : "  ").paletteColor(.accent)
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
                line = line + Text("↑/↓ move · Enter toggle · Tab commit")
                    .paletteColor(.dim)
            } else {
                line = line + Text("↑/↓ move · Enter vote · Esc unfocus")
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

    /// True when this client should render `[x]` for `label`. For
    /// multi-select pending-state, the local pendingBallot is the
    /// authoritative view (uncommitted toggles are visible only here).
    /// For single-select, fall through to the persisted vote.
    private func isLabelChecked(_ label: String) -> Bool {
        if question.multiSelect, !pendingBallot.isEmpty {
            return pendingBallot.contains(label)
        }
        for vote in question.votes where vote.voter?.globalId == selfGlobalId {
            return vote.chosenLabels.contains(label)
        }
        return false
    }

    private var selfGlobalId: UUID? { selfMember?.globalId }

    private func votersFor(label: String) -> [String] {
        var nicks: [String] = []
        for vote in question.votes {
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
        for vote in question.votes {
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
