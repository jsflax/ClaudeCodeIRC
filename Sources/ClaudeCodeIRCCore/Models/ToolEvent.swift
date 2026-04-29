import Foundation
import Lattice

@Model
public final class ToolEvent {
    public var name: String = ""

    /// Raw JSON of the tool input. Rendered as a summary in the TUI.
    public var input: String = ""

    public var result: String? = nil

    /// Raw JSON of `claude -p`'s `toolUseResult` envelope. Sibling to
    /// `result` (the textual ack like "File updated successfully") —
    /// this carries the rich structured payload claude code uses to
    /// render its own UI: for `Write`/`Edit` overwrites it includes
    /// `structuredPatch` (an array of `-old`/`+new` diff lines) plus
    /// `originalFile`. The renderer prefers this over reconstructing
    /// a diff from `input` alone, since `input` only has the new
    /// content and we'd otherwise show a misleading pure-add diff
    /// for an overwrite.
    public var resultMeta: String? = nil

    public var status: ToolStatus = .pending
    public var startedAt: Date = Date()
    public var endedAt: Date? = nil

    public var turn: Turn?

    /// Non-nil when the tool required approval. Wired 1:1.
    public var approval: ApprovalRequest?
}
