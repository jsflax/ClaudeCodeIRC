import Foundation
import NCursesUI

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
