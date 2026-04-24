import ClaudeCodeIRCCore
import Foundation
import NCursesUI

/// One-line strip that renders `✳ <verb>…` while claude is working.
/// The glyph cycles through six asterisk variants every 150ms, giving
/// the same pulsing animation that claude-code shows in its own TUI.
/// Verb is picked per Turn from `ClaudeSpinnerVerbs` and stays stable
/// for the turn's lifetime; the glyph is the only thing that moves.
struct ClaudeThinkingView: View {
    /// Pass the streaming Turn's `globalId` so the verb stays
    /// consistent per turn. `nil` falls back to the default verb.
    let turnId: UUID?

    var body: some View {
        // Reading the ticker's frame registers with the observation
        // tracker that wraps body eval → every tick markDirty →
        // redraw. Writes happen off-main from the ticker's Task.
        let frame = SpinnerTicker.shared.frame
        let glyph = Self.glyphs[frame % Self.glyphs.count]
        let verb = ClaudeSpinnerVerbs.verb(for: turnId)
        return Text("\(glyph) \(verb)…").foregroundColor(.magenta)
    }

    /// Six asterisk-ish glyphs rotated through. Mix of 4- / 5- / 6-
    /// pointed stars so the rotation looks like a pulsing point
    /// rather than a strict frame-by-frame progression.
    private static let glyphs: [String] = ["✢", "✳", "✶", "✻", "✼", "✽"]
}

/// Process-wide ticker that advances a frame counter every 150ms.
/// Reads from any @Observable-tracked call site (like NCursesUI's
/// body eval) register with the observation tracker, so mutating
/// `frame` from the background Task fires `markDirty` on whichever
/// node read it — only views that actually display the spinner
/// redraw on tick.
@MainActor
@Observable
final class SpinnerTicker {
    static let shared = SpinnerTicker()

    var frame: Int = 0

    private var task: Task<Void, Never>?

    private init() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                self?.frame &+= 1
            }
        }
    }
}
