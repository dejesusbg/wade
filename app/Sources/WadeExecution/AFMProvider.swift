import ClaudeForFoundationModels
import Foundation
import FoundationModels

/// Apple Foundation Models route (CLAUDE.md §5.5): one `LanguageModelSession` API over any model
/// that conforms to `LanguageModel`. Here: Apple's on-device model (private, offline) or Claude
/// via Anthropic's official ClaudeForFoundationModels package.
///
/// This is a black-box request/response interface with no activation access, which is why it's
/// the execution stage and never Stage 2.
public struct AFMProvider: ExecutionProvider {
    public enum Backend: Sendable {
        case onDevice
        case claude(ClaudeModel, apiKey: String?)
    }

    public let backend: Backend
    public let displayName: String

    public var sendsDataOffDevice: Bool {
        if case .claude = backend { return true }
        return false
    }

    public init(backend: Backend, displayName: String) {
        self.backend = backend
        self.displayName = displayName
    }

    /// Why the on-device model can't run, or nil if it can.
    public static var onDeviceUnavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is turned off (System Settings → Apple Intelligence & Siri)."
        case .unavailable(.deviceNotEligible): "This Mac doesn't support Apple Intelligence."
        case .unavailable(.modelNotReady): "Apple's on-device model is still downloading or preparing."
        case .unavailable: "Apple's on-device model is unavailable."
        }
    }

    public func generate(prompt: ExecutionPrompt, tools: [MCPTool]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = try makeSession(instructions: prompt.instructions)
                    var differ = SnapshotDiffer()
                    for try await snapshot in session.streamResponse(to: prompt.message) {
                        let delta = differ.delta(for: snapshot.content)
                        if !delta.isEmpty { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeSession(instructions: String) throws -> LanguageModelSession {
        switch backend {
        case .onDevice:
            if let reason = Self.onDeviceUnavailableReason { throw ExecutionError.modelUnavailable(reason) }
            return LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        case .claude(let model, let apiKey):
            guard let apiKey, !apiKey.isEmpty else { throw ExecutionError.missingAPIKey }
            // `.apiKey` is the package's development mode; shipping would use `.appAttest` or
            // `.proxied` so no key lives in the app (see README, "Execution").
            let claude = ClaudeLanguageModel(name: model, auth: .apiKey(apiKey), timeout: 60)
            return LanguageModelSession(model: claude, instructions: instructions)
        }
    }
}
