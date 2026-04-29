import ClaudeCodeIRCCore
import Foundation
import class Lattice.TableResults
import NCursesUI

/// Inline card for an `ApprovalRequest`. Reuses NCursesUI's `CardView`
/// primitive — the framework owns box drawing + the reverse-video
/// header chip; this file just supplies the title / trailing /
/// content / footer payloads.
///
/// Layout matches the IRC design reference:
/// ```
/// ┌──┤ claude wants to use Bash ├─────── pending ─┐
/// │ ls ~/Projects/ | head -20 && which carg…       │
/// │ yes: alice, bob ✓   no: carol ✗   quorum: 3/4  │
/// ├────────────────────────────────────────────────┤
/// │ [Y] vote allow  [D] vote deny  [A] always-allow│
/// └────────────────────────────────────────────────┘
/// ```
/// Approval colours are palette-aware: pending borders use `.accent`,
/// decided cards drop to `.mute`, yes/no tallies use `.ok` / `.danger`.
struct ApprovalCardView: View {
    let request: ApprovalRequest
    let isHost: Bool

    @Query var members: TableResults<Member>

    var body: some View {
        CardView(
            title: titleText,
            trailing: trailingText,
            footer: actionFooter,
            accent: accentRole,
            content: { contentBody }
        )
    }

    // MARK: - Header

    private var titleText: Text {
        Text("claude wants to use ").paletteColor(.dim)
            + Text(request.toolName).bold()
    }

    private var trailingText: Text {
        Text(statusLabel).paletteColor(statusRole)
    }

    // MARK: - Content rows

    @ViewBuilder
    private var contentBody: some View {
        VStack(spacing: 0) {
            commandRow
            // For Write / Edit / MultiEdit, the most useful thing to
            // see at decision time is the actual change, not just the
            // file path. Drop a unified-diff preview into the card so
            // voters know what they're approving. Renderer is the
            // same `DiffBlockView` body segments + tool result rows
            // use, kept consistent via `ToolDiffPreview`.
            if ToolDiffPreview.supportedTools.contains(request.toolName),
               let parsed = ToolDiffPreview.parse(request.toolInput),
               let patch = ToolDiffPreview.renderablePatch(parsed) {
                DiffBlockView(file: parsed.path, patch: patch)
            }
            tallyRow
        }
    }

    /// Single-line preview of the tool input — extracts the canonical
    /// field (`command`, `file_path`, `pattern`, …) so Bash approvals
    /// read as the bash command, not its JSON wrapping.
    private var commandRow: Text {
        let preview = ToolInputSummary.summarise(request.toolInput, limit: 110)
        return Text(preview).paletteColor(.fg)
    }

    /// "yes: alice, bob ✓   no: carol ✗   quorum: 2 / 3"
    private var tallyRow: Text {
        let (yesNicks, noNicks) = voteBreakdown()
        let presentQuorum = members.filter { !$0.isAway }.count
        var line = Text("yes: ").paletteColor(.dim)
        line = line + Text(yesNicks.isEmpty ? "—" : yesNicks.joined(separator: ", "))
            .paletteColor(.ok)
        line = line + Text("   no: ").paletteColor(.dim)
        line = line + Text(noNicks.isEmpty ? "—" : noNicks.joined(separator: ", "))
            .paletteColor(.danger)
        line = line + Text("   quorum: ").paletteColor(.dim)
        line = line + Text("\(yesNicks.count + noNicks.count) / \(presentQuorum)")
            .paletteColor(.accent)
        return line
    }

    // MARK: - Footer

    private var actionFooter: Text? {
        switch request.status {
        case .pending:
            var line = Text("[Y]").paletteColor(.ok).bold()
            line = line + Text(" vote allow   ").paletteColor(.dim)
            line = line + Text("[D]").paletteColor(.danger).bold()
            line = line + Text(" vote deny").paletteColor(.dim)
            if isHost {
                line = line + Text("   ").paletteColor(.dim)
                line = line + Text("[A]").paletteColor(.accent).bold()
                line = line + Text(" always-allow").paletteColor(.dim)
            }
            return line
        case .approved:
            if let by = request.decidedBy?.nick {
                return Text("✓ always-allowed by ").paletteColor(.ok)
                     + Text(by).paletteColor(.ok).bold()
            }
            return Text("✓ approved by quorum").paletteColor(.ok)
        case .denied:
            if let by = request.decidedBy?.nick {
                return Text("✗ denied by ").paletteColor(.danger)
                     + Text(by).paletteColor(.danger).bold()
            }
            return Text("✗ denied by quorum").paletteColor(.danger)
        }
    }

    // MARK: - Tally helpers

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

    private var statusRole: Palette.Role {
        switch request.status {
        case .pending:  return .accent
        case .approved: return .ok
        case .denied:   return .danger
        }
    }

    private var accentRole: Palette.Role {
        // Decided cards drop to `.mute` so they read as "settled"
        // and don't pull eye attention from in-flight work.
        request.status == .pending ? .accent : .mute
    }
}
