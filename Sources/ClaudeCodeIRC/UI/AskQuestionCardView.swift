import ClaudeCodeIRCCore
import Foundation
import class Lattice.TableResults
import NCursesUI

/// Inline card for an `AskQuestion`. Parallels `ApprovalCardView` but
/// renders an option list with focus marker + checkboxes instead of
/// yes/no. Display-only: the parent (`WorkspaceView`) owns row-focus
/// state and writes ballots / appended options on keypress.
///
/// Card shape (single-select):
/// ```
/// ┌─ claude is asking: What should the test cover? ─ pending (1/2) ─┐
/// │ ▸ [x] edge cases                              alice, bob         │
/// │   [ ] happy path                              carol              │
/// │   [ ] concurrency                                                │
/// │   [ ] "write property-based tests" — by dave                     │
/// │   [ ] Other… (type answer)                                       │
/// │                                                                   │
/// │ quorum: 3 / 3   ↑/↓ move · Enter vote · Esc unfocus              │
/// └──────────────────────────────────────────────────────────────────┘
/// ```
///
/// Multi-select adds a `Tab commit` hint and shows
/// `⏳ commit (k/n done)` instead of `Enter vote` until everyone has
/// submitted. `[x]` reflects either the persisted ballot for
/// single-select or the local pending-ballot set for multi-select.
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
    /// the `[x]` checkbox column. Threaded down from
    /// `WorkspaceView` (matches how `ApprovalCardView` would render
    /// per-user state if it needed to).
    let selfMember: Member?

    @Query var members: TableResults<Member>
    @Environment(\.palette) var palette

    /// Sentinel row index for the trailing "Other…" entry. Lives just
    /// past `question.options.count`.
    var otherRowIndex: Int { question.options.count }

    /// Total selectable rows, including "Other…".
    var totalRows: Int { question.options.count + 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(question.options.indices)) { idx in
                optionRow(idx: idx, option: question.options[idx])
            }
            otherRow
            spacerLine
            footer
            bottomBorder
        }
    }

    // MARK: - Header

    private var header: Text {
        var line = Text("┌─ ").foregroundColor(accentColor)
        line = line + Text("claude is asking: ").foregroundColor(.dim)
        let q = question.header.count > 50
            ? String(question.header.prefix(47)) + "..."
            : question.header
        line = line + Text(q).bold()
        line = line + Text(" ").foregroundColor(accentColor)
        line = line + Text("─").foregroundColor(accentColor)
        line = line + Text(" ").foregroundColor(accentColor)
        let group = question.groupSize > 1
            ? "\(statusLabel) (\(question.groupIndex + 1)/\(question.groupSize))"
            : statusLabel
        line = line + Text(group).foregroundColor(statusColor)
        line = line + Text(" ─┐").foregroundColor(accentColor)
        return line
    }

    // MARK: - Option rows

    private func optionRow(idx: Int, option: AskOption) -> Text {
        let isFocusedRow = isFocused && idx == focusedRow
        let isChecked = isLabelChecked(option.label)
        let voters = votersFor(label: option.label)

        var line = Text("│ ").foregroundColor(accentColor)
        line = line + Text(isFocusedRow ? "▸ " : "  ").foregroundColor(.yellow)
        line = line + Text(isChecked ? "[x] " : "[ ] ")
            .foregroundColor(isChecked ? .green : .dim)
        line = line + Text(option.label).foregroundColor(.white)
        if !option.submittedByNick.isEmpty {
            line = line + Text(" — by ").foregroundColor(.dim)
            line = line + Text(option.submittedByNick).foregroundColor(.dim)
        }
        if !voters.isEmpty {
            line = line + Text("   ").foregroundColor(.dim)
            line = line + Text(voters.joined(separator: ", ")).foregroundColor(.dim)
        }
        return line
    }

    private var otherRow: Text {
        let isFocusedRow = isFocused && focusedRow == otherRowIndex
        var line = Text("│ ").foregroundColor(accentColor)
        line = line + Text(isFocusedRow ? "▸ " : "  ").foregroundColor(.yellow)
        line = line + Text("[ ] ").foregroundColor(.dim)
        line = line + Text("Other… (type answer)").foregroundColor(.dim)
        return line
    }

    // MARK: - Footer

    private var spacerLine: Text {
        Text("│").foregroundColor(accentColor)
    }

    private var footer: Text {
        let presentQuorum = members.filter { !$0.isAway }.count
        let ballotCount = uniqueBallotVoters().count
        var line = Text("│ ").foregroundColor(accentColor)

        switch question.status {
        case .pending:
            line = line + Text("quorum: ").foregroundColor(.dim)
            line = line + Text("\(ballotCount) / \(presentQuorum)")
                .foregroundColor(.yellow)
            line = line + Text("   ").foregroundColor(.dim)
            if question.multiSelect {
                line = line + Text("↑/↓ move · Enter toggle · Tab commit")
                    .foregroundColor(.dim)
            } else {
                line = line + Text("↑/↓ move · Enter vote · Esc unfocus")
                    .foregroundColor(.dim)
            }
        case .answered:
            line = line + answeredLine()
        case .cancelled:
            line = line + Text("✗ cancelled").foregroundColor(.red)
            if !question.cancelReason.isEmpty {
                line = line + Text(" — \(question.cancelReason)")
                    .foregroundColor(.dim)
            }
        }
        return line
    }

    private func answeredLine() -> Text {
        if question.chosenLabels.isEmpty {
            return Text("✓ answered: none of the options (by quorum)")
                .foregroundColor(.green)
        }
        let quoted = question.chosenLabels.map { "\"\($0)\"" }.joined(separator: ", ")
        var l = Text("✓ answered: ").foregroundColor(.green)
        l = l + Text(quoted).foregroundColor(.green).bold()
        l = l + Text(" (by quorum)").foregroundColor(.dim)
        return l
    }

    private var bottomBorder: Text {
        Text("└─────────────────────────────────────────────────────────────────┘")
            .foregroundColor(accentColor)
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
        // Match against this user's persisted ballot.
        for vote in question.votes where vote.voter?.globalId == selfGlobalId {
            return vote.chosenLabels.contains(label)
        }
        return false
    }

    private var selfGlobalId: UUID? { selfMember?.globalId }

    /// Per-label voter nicks. For pending questions, walks `votes`
    /// and counts each ballot once per (voter, label) pair.
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

    /// Count of unique voters who've cast any ballot — drives
    /// `quorum: k/n` and the multi-select "commit done" indicator.
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

    private var statusColor: Color {
        switch question.status {
        case .pending:   return .yellow
        case .answered:  return .green
        case .cancelled: return .red
        }
    }

    private var accentColor: Color {
        question.status == .pending ? .yellow : .dim
    }
}
