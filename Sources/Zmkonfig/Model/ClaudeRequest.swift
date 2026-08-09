import Foundation
import Observation
import ZmkonfigKit

/// One in-flight question to Claude and its answer.
///
/// Every LLM feature in the app is a `ClaudeRequest`: it owns the task, the
/// result, and the failure, so a view never talks to `AnthropicClient` itself
/// and a second ask cancels the first rather than racing it.
@MainActor
@Observable
final class ClaudeRequest {
    private(set) var isRunning = false
    private(set) var text: String?
    private(set) var failure: String?
    /// The answer stopped at the model's token limit. It is still shown — a
    /// half-read review is worth having — but never as if it were finished.
    private(set) var wasTruncated = false
    /// What the current `text` is about. An answer about a different subject is
    /// stale — a layer writeup shown under another layer, or a review of a diff
    /// that has since changed, would be worse than showing nothing.
    private(set) var subject: String?

    private let llm: LLMModel
    private var task: Task<Void, Never>?

    init(llm: LLMModel) {
        self.llm = llm
    }

    /// The answer, but only if it is about `subject`.
    func text(for subject: String) -> String? {
        self.subject == subject ? text : nil
    }

    var isConfigured: Bool { llm.isConfigured }

    func clear() {
        task?.cancel()
        task = nil
        isRunning = false
        text = nil
        subject = nil
        failure = nil
        wasTruncated = false
    }

    /// `effort` is what the feature would like, not what is sent: it is
    /// resolved against the selected model's capabilities first, and dropped
    /// when the model has not said it accepts that level.
    func run(subject: String, system: String, prompt: String, effort: ClaudeEffort? = nil) {
        guard let client = llm.client() else {
            failure = AnthropicError.notConfigured.description
            return
        }

        task?.cancel()
        text = nil
        failure = nil
        wasTruncated = false
        self.subject = subject
        isRunning = true

        let model = llm.selectedModelID
        let resolvedEffort = effort.flatMap(llm.effort)
        task = Task { [weak self] in
            do {
                let answer = try await client.complete(
                    model: model,
                    system: system,
                    prompt: prompt,
                    effort: resolvedEffort
                )
                guard !Task.isCancelled else { return }
                self?.text = answer.text
                self?.wasTruncated = answer.wasTruncated
            } catch {
                guard !Task.isCancelled else { return }
                self?.failure = AppError.describe(error)
            }
            self?.isRunning = false
        }
    }
}
