import Foundation

// MARK: - JSON

/// A JSON value the client can both send and receive.
///
/// Exists because a tool's input schema and a tool call's arguments are
/// arbitrary JSON, and `[String: Any]` is not `Sendable` — an actor-isolated
/// model cannot hold one, and a tool call cannot cross a concurrency boundary
/// as one.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// A whole number, or nil. `.number(1.5)` is not an int: a tool that asks
    /// for a key position and is handed 1.5 should hear "no", not "1".
    public var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value else { return nil }
        return Int(value)
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Compact JSON, for logging a call in the transcript. Keys are sorted so
    /// the same input always reads the same way in the UI and in a test.
    public var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The `JSONSerialization` representation, for splicing into a request body
    /// that is built as `[String: Any]` like `complete`'s.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.anyValue)
        case .object(let values): return values.mapValues(\.anyValue)
        }
    }

    // The synthesised `Codable` conformance would encode an enum with
    // associated values as a tagged object — `{"string": {"_0": "hi"}}` — which
    // is not what the API sends or accepts. These write plain JSON.

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            // Before `Double`: a JSON `true` decoded as a number is a type
            // mismatch, but the order makes the intent explicit either way.
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not a JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Tools

/// One tool Claude may call.
public struct ClaudeTool: Sendable, Equatable {
    public let name: String
    public let description: String
    /// A JSON Schema object: `{"type": "object", "properties": {...}, "required": [...]}`.
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// A call the model asked for. The `id` has to survive the round trip: the
/// result is matched back to the call by it, not by name or position.
public struct ClaudeToolUse: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let input: JSONValue

    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// What a tool answered. A failure is `isError`, not a thrown error: the model
/// is meant to read the reason and try something else.
public struct ClaudeToolResult: Sendable, Equatable {
    public let toolUseID: String
    public let content: String
    public let isError: Bool

    public init(toolUseID: String, content: String, isError: Bool = false) {
        self.toolUseID = toolUseID
        self.content = content
        self.isError = isError
    }
}

// MARK: - Transcript

/// One turn of the transcript as the API sees it. The app keeps its own
/// display-facing messages separately; this is the wire history.
public enum ClaudeMessage: Sendable, Equatable {
    case user(String)
    case assistant(text: String, toolUses: [ClaudeToolUse])
    /// Sent as a user-role message whose content is `tool_result` blocks — the
    /// API has no tool role, and results are the user's half of the exchange.
    case toolResults([ClaudeToolResult])
}

/// What one turn produced.
public struct ClaudeTurn: Sendable, Equatable {
    public let text: String
    public let toolUses: [ClaudeToolUse]
    public let stopReason: String?

    /// The model hit `max_tokens` before it finished this turn.
    ///
    /// Spelled the same way `ClaudeCompletion.wasTruncated` is, and computed
    /// rather than stored so there is only one place that knows what
    /// `stop_reason` means. Mid-loop this is worse than a cut-off answer: the
    /// turn's last `tool_use` may be the front half of a call the model had not
    /// finished writing, so a caller that runs the tools and goes round again
    /// is acting on a turn that was never completed. Stop instead.
    public var wasTruncated: Bool { stopReason == "max_tokens" }

    public init(text: String, toolUses: [ClaudeToolUse], stopReason: String?) {
        self.text = text
        self.toolUses = toolUses
        self.stopReason = stopReason
    }
}

// MARK: - The turn

extension AnthropicClient {
    /// One multi-turn, tool-enabled, non-streaming turn.
    ///
    /// Unlike `complete`, an empty `text` is legitimate and never throws: a turn
    /// that only calls tools has no prose, and treating that as an empty answer
    /// would break the loop on its most ordinary step. The caller decides when
    /// the conversation is finished — when `toolUses` comes back empty.
    ///
    /// `effort` is omitted unless a caller passes one, for the same reason
    /// `complete` omits it: a model that does not accept `output_config`
    /// answers with a 400, and the model id is chosen at runtime.
    ///
    /// `maxTokens` is the same 16k `complete` uses, and for the same reasons.
    /// It is the budget for thinking *and* the turn together, and thinking is
    /// on by default on current models, so a tight cap truncates the turn
    /// rather than the reasoning — mid-loop that means a half-written tool
    /// call. The ceiling has to be one every model accepts, because the model
    /// id is chosen at runtime and a value only some models allow would 400 a
    /// key set to Haiku: 16k is comfortably under the smallest output limit
    /// any model the API still serves imposes (Haiku 4.5 caps at 64k, every
    /// current Opus and Sonnet at 128k), and still small enough to answer
    /// inside the timeout a non-streaming request has to finish in.
    public func converse(
        model: String,
        system: String,
        messages: [ClaudeMessage],
        tools: [ClaudeTool] = [],
        maxTokens: Int = 16_000,
        effort: ClaudeEffort? = nil
    ) async throws -> ClaudeTurn {
        var request = URLRequest(url: baseURL.appending(path: "v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(to: &request)

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages.map(Self.wireMessage),
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.inputSchema.anyValue,
                ]
            }
        }
        if let effort {
            body["output_config"] = ["effort": effort.rawValue]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        let message: TurnResponse
        do {
            message = try JSONDecoder().decode(TurnResponse.self, from: data)
        } catch {
            throw AnthropicError.malformedResponse(detail: String(describing: error))
        }

        // Checked before the content is read, exactly as `complete` does: a
        // refusal is an HTTP 200 with an empty body, so reading first would
        // report it as a successful turn that happened to say nothing.
        if message.stopReason == "refusal" {
            throw AnthropicError.refused(explanation: message.stopDetails?.explanation)
        }

        // Only text and tool_use are read; a thinking block carries no text
        // unless it was asked for, and any block type added later is ignored
        // rather than mistaken for content.
        var text = ""
        var toolUses: [ClaudeToolUse] = []
        for block in message.content {
            switch block.type {
            case "text":
                text += block.text ?? ""
            case "tool_use":
                // A call with no id cannot be answered, and dropping it would
                // not avoid that — it would hide it. The caller would return a
                // result for every call it could see, the API would find a
                // tool_use with no matching tool_result, and the 400 would land
                // a round trip away from the response that caused it.
                guard let id = block.id, let name = block.name else {
                    let missing = block.id == nil ? "id" : "name"
                    throw AnthropicError.malformedResponse(
                        detail: "a tool_use block has no \(missing)"
                    )
                }
                toolUses.append(
                    ClaudeToolUse(id: id, name: name, input: block.input ?? .object([:]))
                )
            default:
                continue
            }
        }

        return ClaudeTurn(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            toolUses: toolUses,
            stopReason: message.stopReason
        )
    }

    /// One transcript entry as the wire wants it.
    private static func wireMessage(_ message: ClaudeMessage) -> [String: Any] {
        switch message {
        case .user(let text):
            return ["role": "user", "content": text]

        case .assistant(let text, let toolUses):
            var content: [[String: Any]] = []
            // An empty text block is a 400. A turn that only called tools has
            // no prose, which is the common case in the middle of a loop.
            if !text.isEmpty {
                content.append(["type": "text", "text": text])
            }
            for use in toolUses {
                content.append([
                    "type": "tool_use",
                    "id": use.id,
                    "name": use.name,
                    "input": use.input.anyValue,
                ])
            }
            return ["role": "assistant", "content": content]

        case .toolResults(let results):
            return [
                "role": "user",
                "content": results.map { result in
                    [
                        "type": "tool_result",
                        "tool_use_id": result.toolUseID,
                        "content": result.content,
                        "is_error": result.isError,
                    ] as [String: Any]
                },
            ]
        }
    }

    // MARK: - Wire types

    /// Every block shape a `/v1/messages` response can carry that this app
    /// reads. `complete` goes through `converse`, so this is the only wire type
    /// for the endpoint.
    private struct TurnResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
            let id: String?
            let name: String?
            let input: JSONValue?
        }
        struct StopDetails: Decodable {
            let explanation: String?
        }
        let content: [Block]
        let stopReason: String?
        let stopDetails: StopDetails?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
            case stopDetails = "stop_details"
        }
    }
}
