import Foundation
import Observation
import ZmkonfigKit

/// The API key, the chosen model, and what happened the last time the key was
/// checked. The key itself lives in the keychain and is never written to
/// defaults, logs, or the keymap.
@MainActor
@Observable
final class LLMModel {
    /// Where the key sits in the keychain, and what the settings page calls it.
    static let keychainAccount = "anthropic-api-key"

    private static let modelIDKey = "llm.anthropic.modelID"
    private static let modelListKey = "llm.anthropic.models"

    enum Verification: Equatable {
        /// A key is saved but has not been checked this launch.
        case idle
        case verifying
        case verified(modelCount: Int)
        case failed(String)
    }

    /// What the settings field is showing. Starts as the saved key so the page
    /// opens on the current state rather than on an empty box.
    var apiKeyDraft = ""
    var selectedModelID: String {
        didSet {
            guard selectedModelID != oldValue else { return }
            UserDefaults.standard.set(selectedModelID, forKey: Self.modelIDKey)
        }
    }

    private(set) var models: [ClaudeModel] = ClaudeModel.recommended
    private(set) var verification: Verification = .idle
    private(set) var savedKey: String?
    /// A keychain read or write that failed, which is not the same as a key the
    /// API rejected and deserves its own alert.
    var error: AppError?

    var isConfigured: Bool { savedKey != nil }

    /// True when the field differs from what is stored, which is the only time
    /// saving does anything.
    var hasUnsavedKey: Bool {
        apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines) != (savedKey ?? "")
    }

    private var hasLoaded = false
    private let keychain: Keychain
    private let defaults: UserDefaults
    private let makeClient: @Sendable (String) -> AnthropicClient

    init(
        keychain: Keychain = Keychain(),
        defaults: UserDefaults = .standard,
        makeClient: @escaping @Sendable (String) -> AnthropicClient = { AnthropicClient(apiKey: $0) }
    ) {
        self.keychain = keychain
        self.defaults = defaults
        self.makeClient = makeClient
        selectedModelID = defaults.string(forKey: Self.modelIDKey) ?? ClaudeModel.defaultID
        if let data = defaults.data(forKey: Self.modelListKey),
           let cached = try? JSONDecoder().decode([ClaudeModel].self, from: data),
           !cached.isEmpty {
            models = cached
        }
    }

    /// Reads the saved key once per launch.
    ///
    /// Called at startup rather than when a feature first needs the key: the
    /// read is what triggers macOS's keychain prompt, and one prompt as the app
    /// opens is better than one in the middle of reviewing a commit. Every
    /// LLM-backed control is hidden until this has run, so a late read would
    /// also mean features that quietly are not there.
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        load()
    }

    /// Re-reads the saved key, prompt and all.
    func load() {
        hasLoaded = true
        do {
            savedKey = try keychain.string(account: Self.keychainAccount)
            apiKeyDraft = savedKey ?? ""
        } catch {
            savedKey = nil
            self.error = AppError(title: "Could not read the saved API key", error: error)
        }
    }

    /// Verifies the key against `GET /v1/models`, and stores it only if the API
    /// accepts it. A key that does not work is not worth keeping.
    func saveAndVerify() async {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            verification = .failed("Enter an API key first.")
            return
        }

        verification = .verifying
        let client = makeClient(key)
        let fetched: [ClaudeModel]
        do {
            fetched = try await client.models()
        } catch {
            verification = .failed(AppError.describe(error))
            return
        }

        do {
            try keychain.set(key, account: Self.keychainAccount)
            savedKey = key
        } catch {
            verification = .failed(AppError.describe(error))
            return
        }

        if !fetched.isEmpty {
            models = fetched
            if let data = try? JSONEncoder().encode(fetched) {
                defaults.set(data, forKey: Self.modelListKey)
            }
            // The stored choice may name a model this key cannot reach.
            if !fetched.contains(where: { $0.id == selectedModelID }) {
                selectedModelID = fetched.first?.id ?? ClaudeModel.defaultID
            }
        }
        verification = .verified(modelCount: fetched.count)
    }

    /// Forgets the key entirely — keychain item, field, and verification state.
    func forget() {
        do {
            try keychain.remove(account: Self.keychainAccount)
            savedKey = nil
            apiKeyDraft = ""
            verification = .idle
        } catch {
            self.error = AppError(title: "Could not remove the saved API key", error: error)
        }
    }

    /// A client for the saved key, or nil if there is no key yet. Callers
    /// surface `AnthropicError.notConfigured` themselves so the message points
    /// at Settings.
    func client() -> AnthropicClient? {
        savedKey.map(makeClient)
    }

    /// `preferred`, but only if the selected model told us it accepts that
    /// level. Nil means send nothing — a model missing from the list, or one
    /// whose capabilities were never fetched, must produce exactly the request
    /// shape that worked before effort existed rather than a guess that 400s.
    func effort(_ preferred: ClaudeEffort) -> ClaudeEffort? {
        guard let model = models.first(where: { $0.id == selectedModelID }),
              let supported = model.supportedEfforts,
              supported.contains(preferred.rawValue)
        else { return nil }
        return preferred
    }
}
