import Foundation

/// Abstraction over the host-side turn buffer so tests can inject a
/// fake without spinning up a real `ClaudeDriver` + subprocess +
/// Lattice observers. Actor-constrained because every conformance
/// holds mutable queue state that must be serialised.
///
/// Keep the surface minimal — only what `RoomModel` calls. New
/// methods should go on the concrete `TurnManager` first and only
/// get promoted here if RoomModel (or another external caller) needs
/// them.
public protocol TurnManaging: Actor {
    /// Forwarded by `RoomModel`'s `ChatMessage` observer for every
    /// `.insert` audit entry — local writes and peer uploads alike.
    /// The conformance decides whether the row matters (kind, side),
    /// whether to buffer or trigger, and whether the current in-flight
    /// turn should queue this arrival for after-completion.
    ///
    /// `globalId` rather than a model reference so the call is
    /// `@Sendable`-safe across the observer → actor hop.
    func ingest(globalId: UUID) async
}
