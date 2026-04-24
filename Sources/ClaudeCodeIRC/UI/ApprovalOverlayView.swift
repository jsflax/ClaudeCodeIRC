import ClaudeCodeIRCCore
import Foundation
import Lattice
import NCursesUI

/// Host-only overlay summarising the oldest `ApprovalRequest` row with
/// `status == .pending`. Pure presentation — key handling and row
/// mutation live on `RoomView.decide(_:persist:)` so Y/A/D/ESC continue
/// to work during the brief window between consecutive approvals, when
/// overlay A has dismissed but overlay B hasn't mounted yet.
///
/// Peers observe the same `ApprovalRequest` row via sync — P5
/// follow-up will render a read-only "<nick> is reviewing…" strip on
/// their side.
struct ApprovalOverlayView: View {
    let request: ApprovalRequest

    var body: some View {
        BoxView("Claude wants to use a tool", color: .yellow) {
            VStack {
                HStack {
                    Text("Tool:  ").foregroundColor(.dim)
                    Text(request.toolName).foregroundColor(.cyan).bold()
                }
                HStack {
                    Text("Input: ").foregroundColor(.dim)
                    Text(Self.trim(request.toolInput))
                }
                SpacerView(1)
                Text("[Y] allow once   [A] always allow \(request.toolName)   [D] deny   ⎋ leave pending")
                    .foregroundColor(.dim)
            }
        }
    }

    /// Tool inputs can be multi-line JSON; keep the overlay compact.
    private static func trim(_ s: String) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 140 ? String(oneLine.prefix(140)) + "…" : oneLine
    }
}
