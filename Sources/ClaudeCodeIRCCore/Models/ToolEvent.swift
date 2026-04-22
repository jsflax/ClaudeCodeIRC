import Foundation
import Lattice

@Model
public final class ToolEvent {
    public var name: String = ""

    /// Raw JSON of the tool input. Rendered as a summary in the TUI.
    public var input: String = ""

    public var result: String? = nil
    public var status: ToolStatus = .pending
    public var startedAt: Date = Date()
    public var endedAt: Date? = nil

    public var turn: Turn?

    /// Non-nil when the tool required approval. Wired 1:1.
    public var approval: ApprovalRequest?
}
