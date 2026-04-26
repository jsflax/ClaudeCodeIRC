import Foundation
import Lattice

/// One choice in an `AskQuestion`. Embedded directly inside the
/// question row's `options` array — Lattice persists it as a JSON
/// blob via the `EmbeddedModel` protocol's `PrimitiveProperty` +
/// `CxxListManaged` conformances.
///
/// Direct protocol conformance instead of the `@EmbeddedModel`
/// macro: the macro relies on the compiler synthesising `Codable`
/// for the resulting type, which doesn't kick in reliably across
/// macro-added conformances. Declaring the protocol on the type
/// itself triggers the standard Codable synthesis.
///
/// Free-text answers (entered via the card's "Other…" row) are
/// appended to the same array at runtime, distinguished from
/// claude's canonical options by a non-empty `submittedByNick`.
public struct AskOption: EmbeddedModel, Sendable {
    public var label: String = ""
    public var optionDescription: String = ""
    /// nick of the member who submitted this as free-text. Empty
    /// for the options claude originally provided.
    public var submittedByNick: String = ""

    public init() {}
    public init(label: String, optionDescription: String = "", submittedByNick: String = "") {
        self.label = label
        self.optionDescription = optionDescription
        self.submittedByNick = submittedByNick
    }
}

/// A democratic answer prompt. Created by the MCP shim when claude
/// invokes the `AskUserQuestion` tool — instead of running the
/// built-in (which would block waiting on stdin we don't have),
/// the shim short-circuits, writes one of these per sub-question,
/// and waits for the room to vote. Once `status = .answered`, the
/// shim packages `chosenLabels` into the tool's `deny`-with-message
/// reply and claude's model treats it as the user's answer.
///
/// `AskUserQuestion` calls may carry up to 4 sub-questions in a
/// single tool invocation; each is a separate `AskQuestion` row
/// sharing a `toolUseId`, with `groupIndex`/`groupSize` determining
/// presentation order. The UI surfaces them sequentially: only the
/// lowest-index `.pending` row is interactive at any time.
@Model
public final class AskQuestion {
    /// The top-level prompt text (claude's `question` field).
    public var header: String = ""

    /// All choices, including any user-submitted free-text rows
    /// appended after the question was opened. Vote labels reference
    /// entries in this array by string match (not index) so that
    /// appending can never invalidate prior votes.
    public var options: [AskOption] = []

    /// True iff claude marked this question `multiSelect: true`.
    /// Drives both tally termination (single-winner vs all-ballots-in)
    /// and reply shape (string vs JSON array).
    public var multiSelect: Bool = false

    public var status: AskStatus = .pending

    /// Populated when `status == .cancelled`. Surfaces in the shim's
    /// reply to claude (e.g. "claude subprocess exited") and in the
    /// card UI footer.
    public var cancelReason: String = ""

    public var requestedAt: Date = Date()
    public var answeredAt: Date? = nil

    /// Winning labels. Empty until `.answered`. Single-select holds
    /// at most one entry; multi-select holds every label that
    /// crossed threshold (possibly empty if everyone abstained).
    public var chosenLabels: [String] = []

    /// Claude's `tool_use_id` from the MCP CallTool params, or a
    /// freshly-minted UUID if the meta block didn't carry one. The
    /// shim tails `changeStream` for rows matching this ID until
    /// every member of the group is non-`.pending`.
    public var toolUseId: String = ""

    /// 0-based index within claude's multi-question group. The UI
    /// hides rows whose `groupIndex > firstPending` so the room
    /// works on one question at a time.
    public var groupIndex: Int = 0

    /// Total questions in the group (1..4). With `groupIndex`,
    /// drives the "(k/n)" header annotation.
    public var groupSize: Int = 1

    public var toolEvent: ToolEvent? = nil

    /// All ballots cast against this question. `AskTally` walks this
    /// when the coordinator re-evaluates on any vote/option change.
    @Relation(link: \AskVote.question)
    public var votes: any Results<AskVote>
}
