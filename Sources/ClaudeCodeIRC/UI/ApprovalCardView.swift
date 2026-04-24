import ClaudeCodeIRCCore
import Foundation
import NCursesUI

/// Inline box-drawing card for an `ApprovalRequest`. Replaces the old
/// modal `ApprovalOverlayView` per the design handoff — the card flows
/// in scrollback alongside chat messages so both host + peers see the
/// in-flight tool call and its outcome.
///
/// Card shape (phosphor palette colors):
/// ```
/// ┌─ claude wants to use Bash ──────────────── pending ─┐
/// │ touch /tmp/probe && ls -la /tmp/probe                │
/// │                                                       │
/// │ [Y] allow   [A] always-allow (host)   [D] deny        │
/// └──────────────────────────────────────────────────────┘
/// ```
/// Decided cards drop the action line and show the decider's nick.
///
/// Keypress routing stays on `WorkspaceView` (Y/A/D), same as when
/// the overlay owned them. D6b wires democratic voting on top of this
/// card by swapping the action line for per-member vote tallies.
struct ApprovalCardView: View {
    let request: ApprovalRequest
    let isHost: Bool

    @Environment(\.palette) var palette

    var body: some View {
        VStack(spacing: 0) {
            header
            bodyLine
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
        // Spread the rule out to 60 cols so the card reads as a unit;
        // terminal-width responsive layout can be refined in D10 once
        // we have the palette-role-aware text APIs.
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

    private var actionLine: Text {
        var line = Text("│ ").foregroundColor(accentColor)
        switch request.status {
        case .pending:
            if isHost {
                line = line + Text("[Y]").foregroundColor(.green).bold()
                line = line + Text(" allow   ").foregroundColor(.dim)
                line = line + Text("[A]").foregroundColor(.yellow).bold()
                line = line + Text(" always-allow   ").foregroundColor(.dim)
                line = line + Text("[D]").foregroundColor(.red).bold()
                line = line + Text(" deny").foregroundColor(.dim)
            } else {
                line = line + Text("waiting for host approval")
                    .foregroundColor(.dim)
            }
        case .approved:
            let by = request.decidedBy?.nick ?? "?"
            line = line + Text("✓ approved by ").foregroundColor(.green)
            line = line + Text(by).foregroundColor(.green).bold()
        case .denied:
            let by = request.decidedBy?.nick ?? "?"
            line = line + Text("✗ denied by ").foregroundColor(.red)
            line = line + Text(by).foregroundColor(.red).bold()
        }
        return line
    }

    private var footer: Text {
        Text("└─────────────────────────────────────────────────────────┘")
            .foregroundColor(accentColor)
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
