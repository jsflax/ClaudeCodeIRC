import Foundation
import Lattice

/// Host-side driver for a Claude conversation. Production conformer
/// (`ClaudeCLIDriver`) spawns the headless `claude` CLI; tests inject
/// a fake that records calls without touching a subprocess.
///
/// Implementations are actors so the `RoomModel` observer can hand
/// prompts to the driver across isolation boundaries without
/// explicit locking.
public protocol ClaudeDriver: Actor {
    /// Push a prompt to the driver. Opens a new `Turn` row and
    /// streams the assistant's reply into the room Lattice.
    ///
    /// The concrete `ClaudeCLIDriver` spawns a fresh `claude -p`
    /// subprocess per call — `-p` is "print response and exit" and
    /// only emits the `result` event once its stdin closes. Per-
    /// prompt subprocesses keep the invocation aligned with claude's
    /// actual lifecycle.
    func send(
        prompt: String,
        promptMessageRef: ModelThreadSafeReference<ChatMessage>?
    ) throws

    /// Cancel any in-flight subprocess and flush buffered state.
    /// Called when the room is torn down.
    func stop() async
}
