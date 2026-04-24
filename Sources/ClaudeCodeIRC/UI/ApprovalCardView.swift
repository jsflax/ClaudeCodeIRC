import ClaudeCodeIRCCore
import Foundation
import class Lattice.TableResults
import NCursesUI

/// Inline box-drawing card for an `ApprovalRequest`. Replaces the old
/// modal `ApprovalOverlayView` per the design handoff — the card flows
/// in scrollback alongside chat messages so every member sees the
/// in-flight tool call, current vote state, and final outcome.
///
/// Card shape:
/// ```
/// ┌─ claude wants to use Bash ──────────────── pending ─┐
/// │ touch /tmp/probe && ls -la /tmp/probe                │
/// │                                                      │
/// │ yes: alice, bob ✓   no: carol ✗   quorum: 3 / 4      │
/// │ [Y] vote allow   [D] vote deny   [A] always-allow    │
/// └──────────────────────────────────────────────────────┘
/// ```
/// Decided cards drop the action line and show the outcome + quorum
/// snapshot.
///
/// Keypress routing stays on `WorkspaceView`. Y/D cast votes via
/// `ApprovalVote` rows; [A] remains host-only always-allow (writes
/// an `ApprovalPolicy` and bypasses the vote).
struct ApprovalCardView: View {
    let request: ApprovalRequest
    let isHost: Bool

    @Query var members: TableResults<Member>
    @Environment(\.palette) var palette

    var body: some View {
        VStack(spacing: 0) {
            header
            bodyLine
            tallyLine
            actionLine
            footer
        }
    }

    // MARK: - Sections

    private var header: Text {
        var line = Text("┌─ ").foregroundColor(accentColor)
        line = line + Text("claude wants to use ").foregroundColor(.dim)
        line = line + Text(request.toolName).bold()
        line = line + Text(" ").foregroundColor(accentColor)
        let fill = String(repeating: "─", count: max(1, 32 - request.toolName.count))
        line = line + Text(fill).foregroundColor(accentColor)
        line = line + Text(" ").foregroundColor(accentColor)
        line = line + Text(statusLabel).foregroundColor(statusColor)
        line = line + Text(" ─┐").foregroundColor(accentColor)
        return line
    }

    private var bodyLine: Text {
        // toolInput is a JSON blob — show the first line for
        // readability; D8 adds syntax-aware rendering for common tools.
        let preview = request.toolInput
            .components(separatedBy: "\n")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let truncated = preview.count > 70
            ? String(preview.prefix(67)) + "..."
            : preview
        var line = Text("│ ").foregroundColor(accentColor)
        line = line + Text(truncated).foregroundColor(.white)
        return line
    }

    /// "yes: alice, bob ✓   no: carol ✗   quorum: 2 / 3"
    private var tallyLine: Text {
        let (yesNicks, noNicks) = voteBreakdown()
        let presentQuorum = members.filter { !$0.isAway }.count
        var line = Text("│ ").foregroundColor(accentColor)
        line = line + Text("yes: ").foregroundColor(.dim)
        line = line + Text(yesNicks.isEmpty ? "—" : yesNicks.joined(separator: ", "))
            .foregroundColor(.green)
        line = line + Text("   no: ").foregroundColor(.dim)
        line = line + Text(noNicks.isEmpty ? "—" : noNicks.joined(separator: ", "))
            .foregroundColor(.red)
        line = line + Text("   quorum: ").foregroundColor(.dim)
        line = line + Text("\(yesNicks.count + noNicks.count) / \(presentQuorum)")
            .foregroundColor(.yellow)
        return line
    }

    private var actionLine: Text {
        var line = Text("│ ").foregroundColor(accentColor)
        switch request.status {
        case .pending:
            line = line + Text("[Y]").foregroundColor(.green).bold()
            line = line + Text(" vote allow   ").foregroundColor(.dim)
            line = line + Text("[D]").foregroundColor(.red).bold()
            line = line + Text(" vote deny").foregroundColor(.dim)
            if isHost {
                line = line + Text("   ").foregroundColor(.dim)
                line = line + Text("[A]").foregroundColor(.yellow).bold()
                line = line + Text(" always-allow").foregroundColor(.dim)
            }
        case .approved:
            if let by = request.decidedBy?.nick {
                line = line + Text("✓ always-allowed by ").foregroundColor(.green)
                line = line + Text(by).foregroundColor(.green).bold()
            } else {
                line = line + Text("✓ approved by quorum").foregroundColor(.green)
            }
        case .denied:
            if let by = request.decidedBy?.nick {
                line = line + Text("✗ denied by ").foregroundColor(.red)
                line = line + Text(by).foregroundColor(.red).bold()
            } else {
                line = line + Text("✗ denied by quorum").foregroundColor(.red)
            }
        }
        return line
    }

    private var footer: Text {
        Text("└─────────────────────────────────────────────────────────┘")
            .foregroundColor(accentColor)
    }

    // MARK: - Tally helpers

    /// Walk the request's `votes` relation once, collecting yes / no
    /// voter nicks. Iterates lazily (no Array materialisation) and
    /// keeps only the latest vote per voter so a flip from Y→D
    /// doesn't double-count. The on-disk unique constraint should
    /// already enforce uniqueness, but this reader is defensive.
    private func voteBreakdown() -> (yes: [String], no: [String]) {
        var latest: [UUID: ApprovalVote] = [:]
        for vote in request.votes {
            guard let voterGid = vote.voter?.globalId else { continue }
            if let existing = latest[voterGid], existing.castAt > vote.castAt {
                continue
            }
            latest[voterGid] = vote
        }
        var yes: [String] = []
        var no: [String] = []
        for vote in latest.values {
            guard let nick = vote.voter?.nick else { continue }
            switch vote.decision {
            case .approved: yes.append(nick)
            case .denied:   no.append(nick)
            case .pending:  break
            }
        }
        yes.sort(); no.sort()
        return (yes, no)
    }

    // MARK: - Styling

    private var statusLabel: String {
        switch request.status {
        case .pending:  return "pending"
        case .approved: return "approved"
        case .denied:   return "denied"
        }
    }

    private var statusColor: Color {
        switch request.status {
        case .pending:  return .yellow
        case .approved: return .green
        case .denied:   return .red
        }
    }

    private var accentColor: Color {
        // Decided cards read as "settled" — dim the frame so they
        // don't pull eye attention away from still-pending work.
        request.status == .pending ? .yellow : .dim
    }
}
