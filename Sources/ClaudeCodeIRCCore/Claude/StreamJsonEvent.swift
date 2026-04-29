import Foundation

/// Decoded shape of the events emitted by
///   `claude -p --input-format stream-json --output-format stream-json --verbose`
/// on its stdout. The CLI emits NDJSON — one event per line.
///
/// The event set is a moving target — `claude` adds fields and kinds
/// between releases. Decoder policy: recognise the kinds we need for
/// driving the room Lattice (init / user echo / assistant / tool use
/// and result / final result) and fall back to `.unknown(raw:)` so an
/// upgraded CLI doesn't crash us.
public enum StreamJsonEvent: Sendable, Decodable {
    case systemInit(SystemInit)
    case user(UserMessage)
    case assistant(AssistantMessage)
    case streamEvent(StreamEvent)
    case result(ResultEvent)
    case unknown(raw: String)

    public struct SystemInit: Decodable, Sendable {
        public let model: String?
        public let session_id: String?
        public let tools: [String]?
        public let cwd: String?
    }

    public struct UserMessage: Decodable, Sendable {
        public let session_id: String?
        public let message: Envelope?
        /// Sibling to `message`. When `message.content` carries a
        /// `tool_result` block, `claude -p` also surfaces a richer
        /// envelope here describing the tool's actual outcome — for
        /// `Edit`/`Write`/`MultiEdit` it includes `structuredPatch`
        /// (an array of `-old`/`+new` unified-diff lines) and
        /// `originalFile`. We preserve the raw JSON here and let the
        /// processor route it into `ToolEvent.resultMeta`.
        public let toolUseResult: ContentValue?

        public struct Envelope: Decodable, Sendable {
            /// Content is usually an array of `{type:"text", text:"…"}`
            /// blocks but can be a plain string. We preserve the raw
            /// JSON and let callers inspect it as needed.
            public let content: ContentValue?
        }
    }

    public struct AssistantMessage: Decodable, Sendable {
        public let session_id: String?
        public let message: Envelope?

        public struct Envelope: Decodable, Sendable {
            public let id: String?
            public let role: String?
            public let content: [ContentBlock]?
            public let stop_reason: String?
        }
    }

    /// Incremental streaming deltas. `event.type` is the SSE-ish event
    /// name (`content_block_start`, `content_block_delta`, `content_block_stop`,
    /// `message_stop`, …). For our purposes we mainly care about text
    /// deltas so we can live-render AssistantChunk rows.
    public struct StreamEvent: Decodable, Sendable {
        public let session_id: String?
        public let event: InnerEvent?

        public struct InnerEvent: Decodable, Sendable {
            public let type: String?
            public let index: Int?
            public let delta: Delta?
        }

        public struct Delta: Decodable, Sendable {
            public let type: String?
            public let text: String?
        }
    }

    public struct ResultEvent: Decodable, Sendable {
        public let session_id: String?
        public let subtype: String?  // "success" | "error_max_turns" | ...
        public let is_error: Bool?
        public let duration_ms: Int?
        public let num_turns: Int?
        public let result: String?   // final assistant text on success
    }

    /// A content block in an assistant message. Discriminated by `type`
    /// — `"text"` for text blocks, `"tool_use"` for tool invocations,
    /// `"tool_result"` when the CLI echoes the tool's output back.
    public struct ContentBlock: Decodable, Sendable {
        public let type: String
        public let text: String?           // type == "text"

        public let id: String?             // type == "tool_use"
        public let name: String?           // type == "tool_use"
        public let input: ContentValue?    // type == "tool_use"

        public let tool_use_id: String?    // type == "tool_result"
        public let content: ContentValue?  // type == "tool_result"
        public let is_error: Bool?         // type == "tool_result"
    }

    /// Raw JSON value — preserves whatever the CLI sends without
    /// forcing us to commit to a concrete Swift type for fields that
    /// can be string | array | object (e.g. `input` to a tool, user
    /// message `content`).
    public enum ContentValue: Decodable, Sendable {
        case string(String)
        case array([ContentValue])
        case object([String: ContentValue])
        case number(Double)
        case bool(Bool)
        case null

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let s = try? c.decode(String.self)                { self = .string(s); return }
            if let b = try? c.decode(Bool.self)                  { self = .bool(b);   return }
            if let n = try? c.decode(Double.self)                { self = .number(n); return }
            if let a = try? c.decode([ContentValue].self)        { self = .array(a);  return }
            if let o = try? c.decode([String: ContentValue].self) { self = .object(o); return }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "ContentValue: unrecognised JSON token")
        }

        /// Stringified view — useful for writing into `ToolEvent.input`
        /// / `ToolEvent.result` fields on the Lattice model.
        public var jsonString: String {
            switch self {
            case .string(let s): return s
            case .null: return "null"
            case .bool(let b): return b ? "true" : "false"
            case .number(let n): return String(n)
            case .array, .object:
                let enc = JSONEncoder()
                let data = (try? enc.encode(self)) ?? Data()
                return String(data: data, encoding: .utf8) ?? ""
            }
        }
    }

    // MARK: - Decoding

    public init(from decoder: Decoder) throws {
        // We need the raw JSON to support `.unknown` — decode the
        // `type` discriminator first, re-decode by kind, fall back to
        // reconstituting the JSON if we hit something new.
        let c = try decoder.container(keyedBy: TypeKey.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        let single = try decoder.singleValueContainer()
        switch type {
        case "system":
            let subtype = (try? c.decode(String.self, forKey: .subtype)) ?? ""
            if subtype == "init" {
                self = .systemInit(try single.decode(SystemInit.self))
            } else {
                self = .unknown(raw: "type=system subtype=\(subtype)")
            }
        case "user":
            self = .user(try single.decode(UserMessage.self))
        case "assistant":
            self = .assistant(try single.decode(AssistantMessage.self))
        case "stream_event":
            self = .streamEvent(try single.decode(StreamEvent.self))
        case "result":
            self = .result(try single.decode(ResultEvent.self))
        default:
            self = .unknown(raw: "type=\(type)")
        }
    }

    private enum TypeKey: String, CodingKey {
        case type, subtype
    }
}

extension StreamJsonEvent.ContentValue: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .string(let s):  try c.encode(s)
        case .bool(let b):    try c.encode(b)
        case .number(let n):  try c.encode(n)
        case .array(let a):   try c.encode(a)
        case .object(let o):  try c.encode(o)
        }
    }
}
