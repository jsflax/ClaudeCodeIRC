import Foundation
import Lattice

/// Per-member vote on a pending `ApprovalRequest`. Replaces the old
/// host-unilateral approve/deny model — any non-AFK room member can
/// weigh in, and `ApprovalTally` decides when quorum has landed on
/// an outcome. The host still performs the terminal
/// `request.status = .approved/.denied` write so peers don't race.
///
/// `@Unique(compoundedWith: \.request)` on a pair of link fields is
/// supported via LatticeCore's shadow-column machinery
/// (`<field>__link_gid` cols auto-maintained by link-table triggers).
/// Re-casting a vote clears the prior link and inserts the new one,
/// so this constraint prevents double-counting without requiring
/// delete-before-insert in app code.
@Model
public final class ApprovalVote {
    @Unique(compoundedWith: \ApprovalVote.request)
    public var voter: Member?

    public var request: ApprovalRequest?

    /// `.approved` or `.denied` — `.pending` is nonsensical on a vote row.
    /// The `@Model` default has to be something concrete; call sites always
    /// set a real decision before inserting.
    public var decision: ApprovalStatus = .approved
    public var castAt: Date = Date()
}
