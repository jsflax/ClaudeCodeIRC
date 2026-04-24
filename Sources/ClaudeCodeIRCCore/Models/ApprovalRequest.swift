import Foundation
import Lattice

@Model
public final class ApprovalRequest {
    /// Bare tool name (e.g. "Bash", "Edit"). Used by the overlay's
    /// "always allow <tool>" affordance to key the `ApprovalPolicy`.
    public var toolName: String = ""

    /// Tool input as a JSON string — rendered beneath the tool name
    /// in the overlay so the host can see exactly what's about to run.
    public var toolInput: String = ""

    /// Legacy one-line summary ("Bash: rm -rf .build"). Kept for log
    /// readability; the overlay prefers `toolName` + `toolInput`.
    public var summary: String = ""

    public var status: ApprovalStatus = .pending
    public var requestedAt: Date = Date()
    public var decidedAt: Date? = nil

    public var toolEvent: ToolEvent?

    /// Member who clicked approve/deny. nil while pending.
    public var decidedBy: Member?
}
