import Combine
import Foundation
import Lattice

/// Host-only two-queue buffer in front of `ClaudeDriver`. Matches the
/// IRC turn model from the plan:
///
///   - `intraTurn`: non-side `.user` messages accumulated since the
///     last Claude turn. Forms the prompt context when `@claude`
///     fires.
///   - `interTurn`: messages arriving while a Turn is `.streaming`.
///     On turn completion, if any `interTurn` message mentions
///     `@claude`, it's promoted to `intraTurn` and fired immediately;
///     otherwise `interTurn` becomes the next `intraTurn` so the
///     context continues across turns.
///
/// The manager owns the `ChatMessage` → `ClaudeDriver.send` dispatch:
/// `RoomModel` just forwards every inserted `ChatMessage` row here and
/// the manager filters / buffers / fires as appropriate. `.side`,
/// `.system`, and assistant-authored messages are ignored.
///
/// Turn completion is observed via `lattice.observe(Turn.self)` rather
/// than awaiting `driver.send` — the driver's `send` is fire-and-forget
/// (it dispatches a `Task` and returns immediately), so the Lattice
/// row flipping to `.done`/`.errored` is our signal. That also means
/// peer-side writes couldn't accidentally hang the state machine: the
/// observer fires regardless of which process completed the turn.
public actor TurnManager: TurnManaging {

    private let driver: any ClaudeDriver
    private let lattice: Lattice
    private let sessionCode: String

    private var intraTurn: [ChatMessage] = []
    private var interTurn: [ChatMessage] = []
    private var streaming: Bool = false
    private var turnObserver: AnyCancellable?

    /// `init` is async because resolving the Lattice + Session off
    /// `SendableReference`s must happen inside the actor's isolation
    /// (same pattern as `ClaudeCLIDriver`).
    public init(
        driver: any ClaudeDriver,
        latticeRef: LatticeThreadSafeReference,
        sessionRef: ModelThreadSafeReference<Session>
    ) async throws {
        guard let lattice = latticeRef.resolve() else {
            throw TurnManagerError.latticeUnavailable
        }
        guard let session = sessionRef.resolve(on: lattice) else {
            throw TurnManagerError.sessionUnavailable
        }
        self.driver = driver
        self.lattice = lattice
        self.sessionCode = session.code
    }

    // MARK: - Ingest

    /// Called by `RoomModel`'s `ChatMessage` observer for every
    /// inserted row (local + peer uploads). Sendable-safe because the
    /// caller hands over a `globalId`; we resolve the row inside the
    /// actor.
    public func ingest(globalId: UUID) async {
        guard let msg = lattice.object(ChatMessage.self, globalId: globalId)
        else { return }
        // Assistant chunks live on a different table; system/side
        // messages are out-of-band (help text, /members dumps) and
        // shouldn't reach Claude. Only `.user` non-side messages
        // count for context + trigger.
        guard msg.kind == .user, !msg.side else { return }

        // Sanity-check the message belongs to this room; a
        // cross-session ingest here would mean misconfiguration.
        guard msg.session?.code == sessionCode else { return }

        let mentioned = ClaudeMention.matches(msg.text)

        let nick = msg.author?.nick ?? "?"
        if streaming {
            interTurn.append(msg)
            let n = interTurn.count
            Log.line("turn-mgr",
                "buffered inter-turn nick=\(nick) mentioned=\(mentioned) interCount=\(n)")
            return
        }

        intraTurn.append(msg)
        let n = intraTurn.count
        Log.line("turn-mgr",
            "buffered intra-turn nick=\(nick) mentioned=\(mentioned) intraCount=\(n)")
        if mentioned {
            await fire()
        }
    }

    // MARK: - Fire

    /// Assemble the prompt from `intraTurn`, kick the driver, and
    /// start watching for the Turn to flip to `.done`/`.errored`.
    private func fire() async {
        guard !streaming, let trigger = intraTurn.last else { return }
        let prompt = TurnManager.assemblePrompt(intraTurn)
        let ctxCount = intraTurn.count
        let promptLen = prompt.count
        Log.line("turn-mgr",
            "fire context=\(ctxCount) msgs prompt.len=\(promptLen)")
        streaming = true
        observeTurnCompletion()
        do {
            try await driver.send(
                prompt: prompt,
                promptMessageRef: trigger.sendableReference)
        } catch {
            Log.line("turn-mgr", "driver.send failed: \(error)")
            streaming = false
            turnObserver?.cancel()
            turnObserver = nil
        }
        // Context is consumed — the driver reproduces it to Claude
        // via `--resume`'s session state after the first turn, and by
        // the assembled prompt we just sent before that.
        intraTurn.removeAll(keepingCapacity: true)
    }

    /// `<nick>: <text>` one per line, blank line between speakers of
    /// the same nick only if we had multiple messages (cheap for
    /// single-speaker runs). Matches the plan's example:
    ///
    ///     alice: hey everyone
    ///     bob: did the build break?
    ///     alice: @claude any idea?
    package static func assemblePrompt(_ msgs: [ChatMessage]) -> String {
        msgs
            .map { "\($0.author?.nick ?? "?"): \($0.text)" }
            .joined(separator: "\n")
    }

    // MARK: - Turn completion

    private func observeTurnCompletion() {
        let code = sessionCode
        // Observer fires on every Turn row change; check whether any
        // are still streaming. When none are, this turn ended.
        turnObserver = lattice.observe(Turn.self) { @Sendable [weak self] change in
            guard case .update = change else { return }
            Task { [weak self] in
                await self?.checkTurnCompletion(code: code)
            }
        }
    }

    private func checkTurnCompletion(code: String) async {
        guard streaming else { return }
        let anyStreaming = lattice.objects(Turn.self)
            .where { $0.session.code == code && $0.status == TurnStatus.streaming }
            .first != nil
        if anyStreaming { return }

        streaming = false
        turnObserver?.cancel()
        turnObserver = nil

        // Any `@claude` in `interTurn`? If so, promote and re-fire.
        // Otherwise the inter-turn messages become next turn's context.
        let hasMention = interTurn.contains { ClaudeMention.matches($0.text) }
        intraTurn = interTurn
        interTurn.removeAll(keepingCapacity: true)
        let promoted = intraTurn.count
        Log.line("turn-mgr",
            "turn complete promoted=\(promoted) pendingFire=\(hasMention)")
        if hasMention {
            await fire()
        }
    }

    // MARK: - Errors

    public enum TurnManagerError: Error, CustomStringConvertible {
        case latticeUnavailable
        case sessionUnavailable
        public var description: String {
            switch self {
            case .latticeUnavailable: return "failed to resolve lattice"
            case .sessionUnavailable: return "failed to resolve session"
            }
        }
    }
}
