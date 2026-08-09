import Foundation
import Testing

@testable import ZmkonfigKit

/// Intercepts every request the client makes so the suite never touches the
/// network. The handler is global because `URLProtocol` is instantiated by
/// `URLSession`, which gives no way to hand one in.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A client whose every request is answered by `handler`.
    static func client(
        apiKey: String = "sk-ant-test",
        _ handler: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) -> AnthropicClient {
        Self.handler = handler
        Self.lastRequest = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return AnthropicClient(apiKey: apiKey, session: URLSession(configuration: configuration))
    }

    static func json(_ status: Int, _ body: String) -> @Sendable (URLRequest) -> (Int, Data) {
        { _ in (status, Data(body.utf8)) }
    }
}

/// Serves a scripted list of response bodies, one per request, and counts the
/// requests made.
///
/// The count is the point. A tool loop that fails to stop does not return a
/// wrong answer — it asks for another turn. Only counting requests catches
/// that; asserting on the final turn cannot tell a loop that stopped from one
/// that went round again and happened to end up somewhere similar.
final class StubSequence: @unchecked Sendable {
    private let bodies: [String]
    private var index = 0
    private let lock = NSLock()

    init(_ bodies: [String]) { self.bodies = bodies }

    /// How many requests have been served.
    var requestCount: Int { lock.withLock { index } }

    /// A client that answers from the script. A request past the end of the
    /// script is answered rather than failed — a loop that overruns should be
    /// caught by `requestCount`, not by a transport error that reads like an
    /// unrelated bug.
    func client() -> AnthropicClient {
        StubProtocol.client { [self] _ in
            lock.withLock {
                let body = index < bodies.count
                    ? bodies[index]
                    : #"{"content": [{"type": "text", "text": "overrun"}], "stop_reason": "end_turn"}"#
                index += 1
                return (200, Data(body.utf8))
            }
        }
    }
}

@Suite("Anthropic client", .serialized)
struct AnthropicClientTests {
    @Test("Listing models sends the auth and version headers")
    func modelsRequestIsShapedCorrectly() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"{"data": []}"#))
        _ = try await client.models()

        let request = try #require(StubProtocol.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v1/models")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == AnthropicClient.apiVersion)
    }

    @Test("A model with no display name falls back to its id")
    func modelsDecode() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, """
            {"data": [
                {"type": "model", "id": "claude-opus-5", "display_name": "Claude Opus 5"},
                {"type": "model", "id": "claude-x"}
            ]}
            """))

        let models = try await client.models()
        #expect(models.map(\.id) == ["claude-opus-5", "claude-x"])
        #expect(models.map(\.displayName) == ["Claude Opus 5", "claude-x"])
    }

    @Test("Reported effort capabilities are read; a model without them stays unknown")
    func modelsDecodeEffortCapabilities() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, """
            {"data": [
                {"type": "model", "id": "claude-opus-5", "display_name": "Claude Opus 5",
                 "capabilities": {
                     "image_input": {"supported": true},
                     "effort": {
                         "supported": true,
                         "low": {"supported": true},
                         "medium": {"supported": true},
                         "high": {"supported": true},
                         "xhigh": {"supported": false},
                         "max": {"supported": true}
                     }
                 }},
                {"type": "model", "id": "claude-old", "capabilities": {"image_input": {"supported": true}}},
                {"type": "model", "id": "claude-bare"}
            ]}
            """))

        let models = try await client.models()
        #expect(models[0].supportedEfforts == ["low", "medium", "high", "max"])
        // `capabilities` present but with no effort branch, and no
        // `capabilities` at all, both mean "unknown" rather than "none".
        #expect(models[1].supportedEfforts == nil)
        #expect(models[2].supportedEfforts == nil)
    }

    @Test("A model list cached before supportedEfforts existed still decodes")
    func oldCachedModelListDecodes() throws {
        let old = Data(#"[{"id": "claude-opus-5", "displayName": "Claude Opus 5"}]"#.utf8)
        let models = try JSONDecoder().decode([ClaudeModel].self, from: old)
        #expect(models.map(\.id) == ["claude-opus-5"])
        #expect(models[0].supportedEfforts == nil)
    }

    @Test("A rejected key reports as unauthorized, carrying the API's message")
    func rejectedKey() async throws {
        let client = StubProtocol.client(StubProtocol.json(401, """
            {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}
            """))

        await #expect(throws: AnthropicError.notAuthorized(detail: "invalid x-api-key")) {
            _ = try await client.models()
        }
    }

    @Test("Other failures keep the status and the API's message")
    func otherFailure() async throws {
        let client = StubProtocol.client(StubProtocol.json(429, """
            {"type": "error", "error": {"type": "rate_limit_error", "message": "slow down"}}
            """))

        await #expect(throws: AnthropicError.requestFailed(status: 429, detail: "slow down")) {
            _ = try await client.models()
        }
    }

    @Test("A body that is not the documented error shape is surfaced verbatim")
    func unparseableErrorBody() async throws {
        let client = StubProtocol.client(StubProtocol.json(502, "<html>bad gateway</html>"))

        await #expect(throws: AnthropicError.requestFailed(status: 502, detail: "<html>bad gateway</html>")) {
            _ = try await client.models()
        }
    }

    @Test("A completion posts the model, system prompt and one user turn")
    func completionRequestBody() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [{"type": "text", "text": "hi"}], "stop_reason": "end_turn"}
            """#))
        _ = try await client.complete(model: "claude-opus-5", system: "be brief", prompt: "explain")

        let request = try #require(StubProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/messages")
        // URLProtocol hands back the body on the stream, not `httpBody`.
        let body = try #require(request.httpBodyStream.map(Self.drain))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-opus-5")
        #expect(json["system"] as? String == "be brief")
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "explain"]])
    }

    @Test("No effort means no output_config key at all")
    func completionOmitsOutputConfigByDefault() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [{"type": "text", "text": "hi"}], "stop_reason": "end_turn"}
            """#))
        _ = try await client.complete(model: "m", system: "s", prompt: "p")

        let json = try Self.lastBody()
        #expect(json["output_config"] == nil)
        #expect(json.keys.sorted() == ["max_tokens", "messages", "model", "system"])
    }

    @Test("An effort is sent as output_config.effort")
    func completionSendsEffort() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [{"type": "text", "text": "hi"}], "stop_reason": "end_turn"}
            """#))
        _ = try await client.complete(model: "m", system: "s", prompt: "p", effort: .low)

        let outputConfig = try #require(try Self.lastBody()["output_config"] as? [String: String])
        #expect(outputConfig == ["effort": "low"])
    }

    @Test("Thinking blocks are skipped and text blocks joined")
    func completionReadsTextBlocksOnly() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [
                {"type": "thinking", "thinking": ""},
                {"type": "text", "text": "This layer "},
                {"type": "text", "text": "is a symbol layer.\n"}
            ], "stop_reason": "end_turn"}
            """#))

        let answer = try await client.complete(model: "m", system: "s", prompt: "p")
        #expect(answer.text == "This layer is a symbol layer.")
        #expect(answer.wasTruncated == false)
    }

    @Test("An answer cut off at the token limit says so rather than reading as complete")
    func completionReportsTruncation() async throws {
        // Thinking and answer share `max_tokens`, so this is what a long review
        // behind a lot of thinking looks like: real text, stopped mid-sentence.
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [{"type": "text", "text": "The change moves the arrow cluster to"}],
             "stop_reason": "max_tokens"}
            """#))

        let answer = try await client.complete(model: "m", system: "s", prompt: "p")
        #expect(answer.text == "The change moves the arrow cluster to")
        #expect(answer.wasTruncated)
    }

    @Test("The token budget leaves room for thinking as well as the answer")
    func completionAsksForEnoughTokens() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [{"type": "text", "text": "hi"}], "stop_reason": "end_turn"}
            """#))
        _ = try await client.complete(model: "m", system: "s", prompt: "p")

        #expect(try Self.lastBody()["max_tokens"] as? Int == 16_000)
    }

    @Test("A refusal is an error, not an empty answer")
    func refusalIsAnError() async throws {
        // HTTP 200 with no content — the one failure that would otherwise read
        // as success.
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [], "stop_reason": "refusal",
             "stop_details": {"type": "refusal", "explanation": "policy"}}
            """#))

        await #expect(throws: AnthropicError.refused(explanation: "policy")) {
            _ = try await client.complete(model: "m", system: "s", prompt: "p")
        }
    }

    @Test("A response with no text at all is an error")
    func emptyResponse() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [{"type": "thinking", "thinking": ""}], "stop_reason": "end_turn"}
            """#))

        await #expect(throws: AnthropicError.emptyResponse) {
            _ = try await client.complete(model: "m", system: "s", prompt: "p")
        }
    }

    // MARK: - Tool use

    @Test("A turn that only calls tools decodes the calls and has no text")
    func converseDecodesToolUses() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [
                {"type": "thinking", "thinking": ""},
                {"type": "tool_use", "id": "toolu_1", "name": "read_layer",
                 "input": {"layer": 1}},
                {"type": "tool_use", "id": "toolu_2", "name": "find_keycodes",
                 "input": {"query": "escape"}}
            ], "stop_reason": "tool_use"}
            """#))

        let turn = try await client.converse(
            model: "m", system: "s", messages: [.user("swap tab for escape")]
        )
        // Empty text is legitimate here — the model has not spoken yet.
        #expect(turn.text.isEmpty)
        #expect(turn.stopReason == "tool_use")
        #expect(turn.toolUses.map(\.id) == ["toolu_1", "toolu_2"])
        #expect(turn.toolUses.map(\.name) == ["read_layer", "find_keycodes"])
        #expect(turn.toolUses[0].input["layer"]?.intValue == 1)
        #expect(turn.toolUses[1].input["query"]?.stringValue == "escape")
    }

    @Test("A tool_use block with no id is an error, not a dropped call")
    func converseRejectsMalformedToolUse() async throws {
        // Skipping it would surface a round trip later as a 400: the caller
        // answers the calls it can see, and the API finds a tool_use with no
        // matching tool_result.
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [
                {"type": "tool_use", "name": "read_layer", "input": {"layer": 1}}
            ], "stop_reason": "tool_use"}
            """#))

        await #expect(throws: AnthropicError.malformedResponse(
            detail: "a tool_use block has no id"
        )) {
            _ = try await client.converse(model: "m", system: "s", messages: [.user("hi")])
        }
    }

    @Test("A tool_use block with no name is an error too")
    func converseRejectsUnnamedToolUse() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [
                {"type": "tool_use", "id": "toolu_1", "input": {}}
            ], "stop_reason": "tool_use"}
            """#))

        await #expect(throws: AnthropicError.malformedResponse(
            detail: "a tool_use block has no name"
        )) {
            _ = try await client.converse(model: "m", system: "s", messages: [.user("hi")])
        }
    }

    @Test("Tools are sent with their JSON Schema; no effort means no output_config")
    func converseSendsTools() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn"}
            """#))
        let tool = ClaudeTool(
            name: "read_layer",
            description: "Read one layer.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["layer": .object(["type": .string("integer")])]),
                "required": .array([.string("layer")]),
            ])
        )
        _ = try await client.converse(
            model: "m", system: "s", messages: [.user("hi")], tools: [tool]
        )

        let json = try Self.lastBody()
        #expect(json["output_config"] == nil)
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "read_layer")
        let schema = try #require(tools[0]["input_schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["required"] as? [String] == ["layer"])
    }

    @Test("An effort is sent as output_config.effort")
    func converseSendsEffort() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn"}
            """#))
        _ = try await client.converse(
            model: "m", system: "s", messages: [.user("hi")], effort: .medium
        )

        let outputConfig = try #require(try Self.lastBody()["output_config"] as? [String: String])
        #expect(outputConfig == ["effort": "medium"])
    }

    @Test("An assistant turn with no text emits no text block")
    func converseOmitsEmptyTextBlock() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [{"type": "text", "text": "done"}], "stop_reason": "end_turn"}
            """#))
        _ = try await client.converse(
            model: "m",
            system: "s",
            messages: [
                .user("swap tab for escape"),
                // The model called a tool and said nothing — an empty text
                // block here is a 400 from the API.
                .assistant(text: "", toolUses: [
                    ClaudeToolUse(id: "toolu_1", name: "read_layer", input: .object(["layer": .number(1)])),
                ]),
                .toolResults([ClaudeToolResult(toolUseID: "toolu_1", content: "layer 1")]),
            ]
        )

        let messages = try #require(try Self.lastBody()["messages"] as? [[String: Any]])
        let assistant = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistant.count == 1)
        #expect(assistant[0]["type"] as? String == "tool_use")
    }

    @Test("A tool result round trip is a user message of tool_result blocks")
    func converseSendsToolResults() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [{"type": "text", "text": "done"}], "stop_reason": "end_turn"}
            """#))
        _ = try await client.converse(
            model: "m",
            system: "s",
            messages: [
                .user("swap tab for escape"),
                .assistant(text: "Let me look.", toolUses: [
                    ClaudeToolUse(id: "toolu_1", name: "read_layer", input: .object([:])),
                ]),
                .toolResults([
                    ClaudeToolResult(toolUseID: "toolu_1", content: "no such layer", isError: true),
                ]),
            ]
        )

        let messages = try #require(try Self.lastBody()["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])

        let assistant = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistant[0]["type"] as? String == "text")
        #expect(assistant[0]["text"] as? String == "Let me look.")
        #expect(assistant[1]["id"] as? String == "toolu_1")

        // Results go back as a *user*-role message; the API has no tool role.
        let results = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(results.count == 1)
        #expect(results[0]["type"] as? String == "tool_result")
        #expect(results[0]["tool_use_id"] as? String == "toolu_1")
        #expect(results[0]["content"] as? String == "no such layer")
        #expect(results[0]["is_error"] as? Bool == true)
    }

    @Test("A refusal is an error, not an empty turn")
    func converseRefusalIsAnError() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [], "stop_reason": "refusal",
             "stop_details": {"type": "refusal", "explanation": "policy"}}
            """#))

        await #expect(throws: AnthropicError.refused(explanation: "policy")) {
            _ = try await client.converse(model: "m", system: "s", messages: [.user("hi")])
        }
    }

    @Test("A turn with no content at all is empty, not an error")
    func converseAllowsEmptyTurn() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [{"type": "thinking", "thinking": ""}], "stop_reason": "end_turn"}
            """#))

        let turn = try await client.converse(model: "m", system: "s", messages: [.user("hi")])
        #expect(turn.text.isEmpty)
        #expect(turn.toolUses.isEmpty)
    }

    // MARK: - Truncation

    @Test("A conversation turn asks for enough tokens for thinking and the turn")
    func converseAsksForEnoughTokens() async throws {
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn"}
            """#))
        _ = try await client.converse(model: "m", system: "s", messages: [.user("hi")])

        // The same budget `complete` asks for, and a value every current model
        // accepts — the model id is chosen at runtime, so a ceiling only some
        // models allow would start 400ing a key set to Haiku.
        #expect(try Self.lastBody()["max_tokens"] as? Int == 16_000)
    }

    @Test("A turn cut off at the token limit says so, and still shows what it asked for")
    func converseReportsTruncation() async throws {
        // What a truncated tool round looks like on the wire: a call the model
        // was part-way through asking for when the budget ran out.
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [
                {"type": "text", "text": "Let me look at layer 1 first"},
                {"type": "tool_use", "id": "toolu_1", "name": "read_layer",
                 "input": {"layer": 1}}
            ], "stop_reason": "max_tokens"}
            """#))

        let turn = try await client.converse(
            model: "m", system: "s", messages: [.user("swap tab for escape")]
        )
        #expect(turn.wasTruncated)
        #expect(turn.stopReason == "max_tokens")
        // The calls are still decoded: the caller has to be able to say what
        // was cut off, and dropping them would hide it rather than report it.
        #expect(turn.toolUses.map(\.id) == ["toolu_1"])
    }

    @Test("A turn that finished is not reported as truncated")
    func converseDoesNotOverreportTruncation() async throws {
        for stopReason in ["end_turn", "tool_use", "stop_sequence"] {
            let client = StubProtocol.client(StubProtocol.json(200, """
                {"content": [{"type": "text", "text": "ok"}], "stop_reason": "\(stopReason)"}
                """))
            let turn = try await client.converse(
                model: "m", system: "s", messages: [.user("hi")]
            )
            #expect(turn.wasTruncated == false)
        }
    }

    @Test("A truncated turn mid tool loop stops the loop rather than answering it")
    func truncationStopsTheToolLoop() async throws {
        // Round one is an ordinary tool round; round two is cut off part-way
        // through asking for another. A loop that ignores the truncation runs
        // that second call, sends its result, and asks for a third turn.
        let sequence = StubSequence([
            #"""
            {"content": [
                {"type": "tool_use", "id": "toolu_1", "name": "read_layer",
                 "input": {"layer": 0}}
            ], "stop_reason": "tool_use"}
            """#,
            #"""
            {"content": [
                {"type": "text", "text": "Layer 0 has Tab on the left"},
                {"type": "tool_use", "id": "toolu_2", "name": "set_binding",
                 "input": {"layer": 0}}
            ], "stop_reason": "max_tokens"}
            """#,
        ])
        let client = sequence.client()

        // The loop `AssistantModel` runs, reduced to the part under test: ask,
        // stop if the turn is a fragment, otherwise answer the tools and go
        // round again.
        var history: [ClaudeMessage] = [.user("put escape on the left thumb")]
        var toolsRun: [String] = []
        var truncated = false

        for _ in 0..<12 {
            let turn = try await client.converse(
                model: "m", system: "s", messages: history,
                tools: [ClaudeTool(name: "read_layer", description: "d", inputSchema: .object([:]))]
            )
            if turn.wasTruncated {
                truncated = true
                break
            }
            if turn.toolUses.isEmpty { break }
            history.append(.assistant(text: turn.text, toolUses: turn.toolUses))
            history.append(.toolResults(turn.toolUses.map { use in
                toolsRun.append(use.name)
                return ClaudeToolResult(toolUseID: use.id, content: "ok")
            }))
        }

        #expect(truncated)
        // Two turns asked for, and no third: the loop stopped rather than
        // continuing on a turn the model never finished writing.
        #expect(sequence.requestCount == 2)
        // The truncated turn's call was never run — it may be the front half
        // of one the model had not finished asking for.
        #expect(toolsRun == ["read_layer"])
    }

    @Test("A refusal is still checked before the content, even when content is present")
    func refusalIsCheckedBeforeContent() async throws {
        // A refusal is an HTTP 200, so the check has to come first. This body
        // carries a tool_use block a content-first reader would happily return
        // as a turn to act on.
        let client = StubProtocol.client(StubProtocol.json(200, #"""
            {"content": [
                {"type": "tool_use", "id": "toolu_1", "name": "set_binding", "input": {}}
            ], "stop_reason": "refusal",
             "stop_details": {"type": "refusal", "explanation": "policy"}}
            """#))

        await #expect(throws: AnthropicError.refused(explanation: "policy")) {
            _ = try await client.converse(model: "m", system: "s", messages: [.user("hi")])
        }
    }

    @Test("JSONValue round-trips as plain JSON, not a tagged enum")
    func jsonValueEncodesPlainly() throws {
        let value = JSONValue.object([
            "layer": .number(2),
            "name": .string("Nav"),
            "keys": .array([.number(0), .number(1)]),
            "deep": .bool(true),
            "gone": .null,
        ])
        #expect(value.jsonText == #"{"deep":true,"gone":null,"keys":[0,1],"layer":2,"name":"Nav"}"#)

        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(value.jsonText.utf8))
        #expect(decoded == value)
        #expect(decoded["layer"]?.intValue == 2)
        #expect(decoded["deep"]?.boolValue == true)
        #expect(decoded["keys"]?.arrayValue?.count == 2)
        // 1.5 is not a key position; intValue says so rather than rounding.
        #expect(JSONValue.number(1.5).intValue == nil)
    }

    /// The JSON body of the request the client just made.
    private static func lastBody() throws -> [String: Any] {
        let request = try #require(StubProtocol.lastRequest)
        // URLProtocol hands back the body on the stream, not `httpBody`.
        let data = try #require(request.httpBodyStream.map(drain))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
