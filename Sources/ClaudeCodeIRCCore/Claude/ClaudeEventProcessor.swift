import Foundation
import Lattice

/// Pure state machine that maps decoded `StreamJsonEvent`s to Lattice
/// row writes (`Turn`, `AssistantChunk`, `ToolEvent`). Knows nothing
/// about processes, pipes, async, or timers — the CLI driver wraps
/// it with those, and tests exercise it directly by feeding a
/// scripted event sequence.
///
/// A processor is single-turn at a time: call `openTurn` before each
/// user prompt, feed events, then either let a `.result` event close
/// the turn or call `closeTurnOnEof()` if the subprocess dies mid-
/// stream.
///
/// Text deltas are buffered in `pendingText` but not written until
/// `flush()` is called. The driver calls `flush()` on a 50ms debounce
/// timer to keep the `AssistantChunk` insert rate bounded.
package struct ClaudeEventProcessor {
    package let lattice: Lattice
    package let session: Session

    package private(set) var currentTurn: Turn?
    package private(set) var pendingText: String = ""
    package private(set) var chunkCount: Int = 0
    private var toolEventsByUseId: [String: ToolEvent] = [:]

    /// `claude -p` emits both (a) incremental `stream_event` text
    /// deltas and (b) a consolidated `assistant` event that contains
    /// the same full text as a single content block. Taking both
    /// double-writes every reply. When we've seen at least one delta
    /// we flip this flag; the `assistant` event's text blocks are
    /// then ignored. Tool use/result blocks on the assistant event
    /// are still honoured — only text is duplicated.
    private var sawTextDelta: Bool = false

    package init(lattice: Lattice, session: Session) {
        self.lattice = lattice
        self.session = session
    }

    // MARK: - Turn lifecycle

    /// Open a new `.streaming` Turn linked to `session`. Called by the
    /// driver right before it writes the user prompt to claude's stdin.
    package mutating func openTurn(promptMessage: ChatMessage?) {
        let turn = Turn()
        turn.status = .streaming
        turn.session = session
        turn.prompt = promptMessage
        lattice.add(turn)
        currentTurn = turn
        chunkCount = 0
        pendingText = ""
        sawTextDelta = false
        toolEventsByUseId.removeAll(keepingCapacity: true)
    }

    /// Called when the subprocess closes stdout before emitting a
    /// `result` event. Marks any in-flight Turn as `.errored`.
    package mutating func closeTurnOnEof() {
        guard let t = currentTurn, t.status == .streaming else { return }
        t.status = .errored
        t.endedAt = Date()
        currentTurn = nil
    }

    // MARK: - Event dispatch

    package mutating func handle(_ event: StreamJsonEvent) {
        switch event {
        case .systemInit:
            break
        case .user:
            break  // claude echoes our own prompt back; ignore
        case .assistant(let a):
            handleContent(a.message?.content ?? [])
        case .streamEvent(let e):
            handleStreamEvent(e)
        case .result(let r):
            finishTurn(result: r)
        case .unknown:
            break
        }
    }

    /// Force-flush any buffered delta text to an `AssistantChunk`.
    /// Idempotent — no-op when `pendingText` is empty or no turn is
    /// open.
    package mutating func flush() {
        guard !pendingText.isEmpty, let turn = currentTurn else {
            pendingText = ""
            return
        }
        let chunk = AssistantChunk()
        chunk.text = pendingText
        chunk.chunkIndex = chunkCount
        chunk.turn = turn
        lattice.add(chunk)
        chunkCount += 1
        pendingText = ""
    }

    // MARK: - Assistant blocks

    private mutating func handleContent(_ blocks: [StreamJsonEvent.ContentBlock]) {
        for block in blocks {
            switch block.type {
            case "text":
                // Skip if we already streamed the same text via deltas;
                // otherwise this is a non-streaming CLI path and we
                // need this block to surface the reply at all.
                if !sawTextDelta, let t = block.text, !t.isEmpty {
                    pendingText += t
                }
            case "tool_use":
                openToolEvent(
                    useId: block.id ?? UUID().uuidString,
                    name: block.name ?? "(unknown)",
                    input: block.input?.jsonString ?? "")
            case "tool_result":
                closeToolEvent(
                    useId: block.tool_use_id ?? "",
                    result: block.content?.jsonString ?? "",
                    isError: block.is_error ?? false)
            default:
                break
            }
        }
    }

    // MARK: - Streaming deltas

    private mutating func handleStreamEvent(_ e: StreamJsonEvent.StreamEvent) {
        guard let inner = e.event, let type = inner.type else { return }
        switch type {
        case "content_block_delta":
            if inner.delta?.type == "text_delta", let text = inner.delta?.text {
                pendingText += text
                sawTextDelta = true
            }
        case "content_block_stop", "message_stop":
            flush()
        default:
            break
        }
    }

    // MARK: - Tool events

    private mutating func openToolEvent(useId: String, name: String, input: String) {
        guard let turn = currentTurn else { return }
        let ev = ToolEvent()
        ev.name = name
        ev.input = input
        ev.status = .running
        ev.turn = turn
        lattice.add(ev)
        toolEventsByUseId[useId] = ev
    }

    private mutating func closeToolEvent(useId: String, result: String, isError: Bool) {
        guard let ev = toolEventsByUseId[useId] else { return }
        ev.result = result
        ev.status = isError ? .errored : .ok
        ev.endedAt = Date()
        toolEventsByUseId[useId] = nil
    }

    // MARK: - Turn finish

    private mutating func finishTurn(result: StreamJsonEvent.ResultEvent) {
        flush()
        guard let turn = currentTurn else { return }
        turn.status = (result.is_error ?? false) ? .errored : .done
        turn.endedAt = Date()

        // Some CLI paths skip per-delta stream events and just emit
        // the final result string. Make sure the Turn has non-empty
        // content even in that case.
        if chunkCount == 0, let finalText = result.result, !finalText.isEmpty {
            let chunk = AssistantChunk()
            chunk.text = finalText
            chunk.chunkIndex = 0
            chunk.turn = turn
            lattice.add(chunk)
            chunkCount = 1
        }

        currentTurn = nil
        toolEventsByUseId.removeAll(keepingCapacity: true)
    }
}
