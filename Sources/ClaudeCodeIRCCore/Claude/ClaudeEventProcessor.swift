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
        case .user(let u):
            // `claude -p`'s stream-json emits two flavours of user
            // events: (a) an echo of the prompt we just sent — ignore,
            // and (b) tool-result envelopes whose `message.content` is
            // a JSON array of `{type:"tool_result", ...}` blocks. The
            // latter are how a `ToolEvent` flips from `.running` →
            // `.ok` / `.errored`. Without handling them, every tool
            // row stays stuck at `.running` and never renders its
            // result block. Echoed prompts are plain strings, not
            // arrays — the array case below reads as a clean
            // "is this a tool-result envelope" gate.
            //
            // The same envelope carries a richer `toolUseResult`
            // sibling that we pass through so renderers can show a
            // proper diff for Write/Edit overwrites (claude code
            // pre-bakes `structuredPatch` + `originalFile` there).
            if case .array(let elements) = u.message?.content {
                handleUserToolResults(elements, toolUseResult: u.toolUseResult)
            }
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

    /// Drain `tool_result` blocks out of a user message's content
    /// array and route them through `closeToolEvent`. Pattern-matches
    /// the `ContentValue` enum directly — no JSON re-encoding round
    /// trip — so the field names stay grep-able and decoding stays
    /// deterministic.
    ///
    /// `toolUseResult` is the sibling top-level envelope from the
    /// same user message, when present. It carries claude code's
    /// rich post-execution payload (e.g. `structuredPatch` for Edit
    /// / Write overwrites). We pass its serialized JSON through to
    /// `ToolEvent.resultMeta` so renderers can use the pre-baked
    /// diff instead of reconstructing one from `input`.
    private mutating func handleUserToolResults(
        _ elements: [StreamJsonEvent.ContentValue],
        toolUseResult: StreamJsonEvent.ContentValue?
    ) {
        for el in elements {
            guard case .object(let fields) = el,
                  case .string(let type) = fields["type"], type == "tool_result",
                  case .string(let useId) = fields["tool_use_id"]
            else { continue }
            let isError: Bool
            if case .bool(let b) = fields["is_error"] { isError = b } else { isError = false }
            // `content` is usually a string but can be an array of
            // sub-blocks (e.g. claude code wrapping the result with
            // `[{type:"text", text:"…"}]`). `jsonString` handles both
            // shapes uniformly — string passes through, structured
            // values re-serialise to JSON.
            let result = fields["content"]?.jsonString ?? ""
            let metaJson: String?
            if case .object = toolUseResult {
                metaJson = toolUseResult?.jsonString
            } else {
                metaJson = nil
            }
            closeToolEvent(useId: useId, result: result, resultMeta: metaJson, isError: isError)
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

    private mutating func closeToolEvent(
        useId: String,
        result: String,
        resultMeta: String? = nil,
        isError: Bool
    ) {
        guard let ev = toolEventsByUseId[useId] else { return }
        ev.result = result
        ev.resultMeta = resultMeta
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
