import Foundation
import Lattice

@Model
public final class ApprovalRequest {
    /// Human-readable summary shown to the host in the approval overlay
    /// (e.g. "Edit Package.swift", "Bash: rm -rf .build && swift build").
    public var summary: String = ""

    public var status: ApprovalStatus = .pending
    public var requestedAt: Date = Date()
    public var decidedAt: Date? = nil

    public var toolEvent: ToolEvent?

    /// Member who clicked approve/deny. nil while pending.
    public var decidedBy: Member?
}
