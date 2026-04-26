import Foundation
import Lattice

/// One member's ballot for an `AskQuestion`. Single-select ballots
/// always carry exactly one entry in `chosenLabels`; multi-select
/// ballots can hold 0..n. The compound `@Unique` constraint on
/// `(voter, question)` enforces "one ballot per voter per question"
/// — re-casting overwrites prior labels via shadow-column upsert,
/// same mechanism `ApprovalVote` uses.
///
/// For multi-select, clients accumulate picks in local `@State`
/// and commit the full array in one write when the voter presses
/// Tab to finalise their ballot. For single-select, every
/// Enter-press immediately rewrites the 1-element array (or
/// deletes the row if pressed on the already-voted-for label).
@Model
public final class AskVote {
    @Unique(compoundedWith: \AskVote.question)
    public var voter: Member?

    public var question: AskQuestion?

    /// Labels picked by this voter, matching entries in
    /// `question.options[].label` (free-text rows included).
    public var chosenLabels: [String] = []

    public var castAt: Date = Date()
}
