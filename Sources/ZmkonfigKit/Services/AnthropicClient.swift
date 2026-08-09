import Foundation

// MARK: - Models

/// How much thinking and token spend a request is allowed. Sent as
/// `output_config.effort`, and only when the chosen model says it accepts the
/// level — see `ClaudeModel.supportedEfforts`.
public enum ClaudeEffort: String, Sendable, CaseIterable {
    case low, medium, high, xhigh, max
}

/// One model the configured API key is allowed to use.
public struct ClaudeModel: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    public let displayName: String
    /// The effort level names `GET /v1/models` reported as supported, or nil
    /// when nothing is known — a model list cached before this field existed,
    /// or the built-in `recommended` list. Optional so an old cached list still
    /// decodes; without that, `models` would silently fall back to
    /// `.recommended` on every existing install.
    public let supportedEfforts: [String]?

    public init(id: String, displayName: String, supportedEfforts: [String]? = nil) {
        self.id = id
        self.displayName = displayName
        self.supportedEfforts = supportedEfforts
    }

    /// Shown before a key has been verified, so the picker is never empty.
    /// Replaced wholesale by whatever `GET /v1/models` returns.
    public static let recommended: [ClaudeModel] = [
        ClaudeModel(id: "claude-opus-5", displayName: "Claude Opus 5"),
        ClaudeModel(id: "claude-sonnet-5", displayName: "Claude Sonnet 5"),
        ClaudeModel(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
    ]

    public static let defaultID = "claude-opus-5"
}

/// One answer, and whether it is the whole of one.
///
/// `wasTruncated` is not an error: the text is real and worth reading, it just
/// stops mid-sentence. Returning it alongside the answer is what stops a cut-off
/// review from being presented as a complete one.
public struct ClaudeCompletion: Sendable, Equatable {
    public let text: String
    /// The model hit `max_tokens` before it finished.
    public let wasTruncated: Bool

    public init(text: String, wasTruncated: Bool) {
        self.text = text
        self.wasTruncated = wasTruncated
    }
}

// MARK: - Errors

public enum AnthropicError: Error, CustomStringConvertible, Equatable {
    /// No API key has been saved yet.
    case notConfigured
    /// The API rejected the key itself — 401 or 403.
    case notAuthorized(detail: String)
    case requestFailed(status: Int, detail: String)
    case malformedResponse(detail: String)
    /// The request reached Claude and its safety classifiers declined it.
    /// A successful HTTP response, so it needs its own case.
    case refused(explanation: String?)
    /// The response carried no text — thinking blocks only, or nothing at all.
    case emptyResponse
    case transport(reason: String)

    public var description: String {
        switch self {
        case .notConfigured:
            return "No Anthropic API key is saved. Add one in Settings (⌘,)."
        case .notAuthorized(let detail):
            return "That API key was rejected by the Anthropic API. (\(detail))"
        case .requestFailed(let status, let detail):
            return "The Anthropic API returned HTTP \(status): \(detail)"
        case .malformedResponse(let detail):
            return "Could not read the Anthropic API's response: \(detail)"
        case .refused(let explanation):
            let reason = explanation.map { " (\($0))" } ?? ""
            return "Claude declined to answer this request\(reason)."
        case .emptyResponse:
            return "Claude returned no text for this request."
        case .transport(let reason):
            return "Could not reach the Anthropic API: \(reason)"
        }
    }
}

// MARK: - Client

/// A thin client over the two Anthropic endpoints this app uses.
///
/// There is no official Anthropic SDK for Swift, so this speaks the REST API
/// directly. Only what is used lives here: listing models (which doubles as
/// verifying the key) and a single non-streaming message.
public struct AnthropicClient: Sendable {
    /// Pinned as the docs require; not the model version.
    public static let apiVersion = "2023-06-01"
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!

    private let apiKey: String
    /// Not private: `converse` lives in an extension in another file and has to
    /// build its own `/v1/messages` URL against the same host.
    let baseURL: URL
    private let session: URLSession

    public init(
        apiKey: String,
        baseURL: URL = AnthropicClient.defaultBaseURL,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // Claude thinks before it answers, so a request is slow rather than
            // hung. Long enough to let one finish, short enough to fail.
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Every model this key may use, newest first as the API returns them.
    ///
    /// Also how a key is verified: it is the cheapest call that fails loudly on
    /// a bad key and costs no tokens on a good one.
    public func models() async throws -> [ClaudeModel] {
        var request = URLRequest(url: baseURL.appending(path: "v1/models"))
        request.httpMethod = "GET"
        applyHeaders(to: &request)

        let data = try await send(request)
        do {
            return try JSONDecoder().decode(ModelListResponse.self, from: data).data.map {
                ClaudeModel(
                    id: $0.id,
                    displayName: $0.displayName ?? $0.id,
                    supportedEfforts: $0.capabilities?.effort?.supportedNames
                )
            }
        } catch {
            throw AnthropicError.malformedResponse(detail: String(describing: error))
        }
    }

    /// One non-streaming turn. Returns the concatenated text blocks.
    ///
    /// `effort` is omitted unless a caller passes one, because model ids are
    /// chosen at runtime and a model that does not accept `output_config`
    /// answers with a 400. `LLMModel.effort(_:)` is what decides that.
    ///
    /// `maxTokens` is the budget for *thinking and answer together*, and
    /// thinking is on by default on current models — a few paragraphs of prose
    /// can easily sit behind several thousand thinking tokens, so a tight cap
    /// truncates the answer rather than the reasoning. 16k leaves room for both
    /// and stays under the timeout a non-streaming request has to answer in;
    /// every model the API still serves accepts it.
    ///
    /// A one-message `converse` with no tools, plus the rule that separates the
    /// two: here an answer with no text is an error, because a caller asking for
    /// prose has nothing to show. `converse` omits `tools` when the array is
    /// empty, so the request on the wire is the same one this used to build.
    public func complete(
        model: String,
        system: String,
        prompt: String,
        maxTokens: Int = 16_000,
        effort: ClaudeEffort? = nil
    ) async throws -> ClaudeCompletion {
        let turn = try await converse(
            model: model,
            system: system,
            messages: [.user(prompt)],
            maxTokens: maxTokens,
            effort: effort
        )
        guard !turn.text.isEmpty else { throw AnthropicError.emptyResponse }
        return ClaudeCompletion(text: turn.text, wasTruncated: turn.wasTruncated)
    }

    func applyHeaders(to request: inout URLRequest) {
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
    }

    /// Performs the request and maps anything that is not a 2xx onto an error
    /// carrying the API's own message.
    func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AnthropicError.transport(reason: AnthropicClient.describe(error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.malformedResponse(detail: "not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = Self.errorMessage(in: data)
            switch http.statusCode {
            case 401, 403:
                throw AnthropicError.notAuthorized(detail: detail)
            default:
                throw AnthropicError.requestFailed(status: http.statusCode, detail: detail)
            }
        }
        return data
    }

    /// The API's `{"error": {"message": …}}`, or the raw body if it is not that
    /// shape. Never a generic stand-in: a rejected request should say why.
    private static func errorMessage(in data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            return envelope.error.message
        }
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "no response body" : body
    }

    private static func describe(_ error: any Error) -> String {
        (error as? URLError)?.localizedDescription ?? String(describing: error)
    }

    // MARK: - Wire types

    private struct ModelListResponse: Decodable {
        /// Only the leaves this app acts on. The real tree also carries
        /// `image_input`, `thinking`, `structured_outputs` and more; every
        /// field here is optional so an entry that omits `capabilities`
        /// entirely still decodes.
        struct Capabilities: Decodable {
            struct Support: Decodable { let supported: Bool? }

            struct Effort: Decodable {
                let low: Support?
                let medium: Support?
                let high: Support?
                let xhigh: Support?
                let max: Support?

                /// The levels reported as supported, named as `ClaudeEffort`
                /// spells them. A level the API has added since is invisible
                /// here, which is the safe direction: it is simply never sent.
                var supportedNames: [String] {
                    let byLevel: [(ClaudeEffort, Support?)] = [
                        (.low, low), (.medium, medium), (.high, high),
                        (.xhigh, xhigh), (.max, max),
                    ]
                    return byLevel.compactMap { level, support in
                        support?.supported == true ? level.rawValue : nil
                    }
                }
            }

            let effort: Effort?
        }

        struct Entry: Decodable {
            let id: String
            let displayName: String?
            let capabilities: Capabilities?

            enum CodingKeys: String, CodingKey {
                case id
                case capabilities
                case displayName = "display_name"
            }
        }
        let data: [Entry]
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable {
            let message: String
        }
        let error: Detail
    }
}
