import Foundation
import Lattice

/// Persisted "always allow / always deny" decision for a given tool
/// name in a room. Coarse: keyed on `toolName` only, so approving
/// `Bash` once auto-allows every subsequent `Bash` call in the same
/// room. Rows sync to peers, so they know what the host has
/// pre-approved without seeing each individual `ApprovalRequest`.
///
/// The shim consults this table before writing a new
/// `ApprovalRequest`: a matching `.approved` policy returns allow
/// immediately; a matching `.denied` policy returns deny; otherwise
/// the approval overlay fires.
@Model
public final class ApprovalPolicy {
    @Unique()
    public var toolName: String = ""

    public var decision: ApprovalStatus = .approved
    public var createdAt: Date = Date()

    public var decidedBy: Member?
    public var session: Session?
}
