import Foundation

/// Runs a user-chosen ordered list of providers (primary, then fallback) through one code path.
/// No provider is special: the fallback is just the next entry, picked by the user from the same
/// catalog (CLAUDE.md §5.5, "don't hardcode the fallback").
///
/// A provider is skipped when it can't start (missing key, setup not done) or fails *before*
/// producing any text. Once text has streamed, an error is reported instead of switching
/// providers mid-sentence.
public enum ProviderChain {
    public enum Event: Sendable, Equatable {
        case skipped(title: String, reason: String)
        case using(title: String, offDevice: Bool)
        case text(String)
    }

    public typealias Resolver = @Sendable (ProviderDescriptor) -> Result<any ExecutionProvider, ExecutionError>

    public static func run(_ chain: [ProviderDescriptor], prompt: ExecutionPrompt,
                           resolve: @escaping Resolver) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var lastError: Error = ExecutionError.modelUnavailable("no provider selected")
                for descriptor in chain {
                    let provider: any ExecutionProvider
                    switch resolve(descriptor) {
                    case .success(let p): provider = p
                    case .failure(let error):
                        continuation.yield(.skipped(title: descriptor.title, reason: error.localizedDescription))
                        lastError = error
                        continue
                    }
                    continuation.yield(.using(title: provider.displayName, offDevice: provider.sendsDataOffDevice))
                    var produced = false
                    do {
                        for try await delta in provider.generate(prompt: prompt, tools: []) {
                            produced = true
                            continuation.yield(.text(delta))
                        }
                        continuation.finish()
                        return
                    } catch {
                        if produced || Task.isCancelled {
                            continuation.finish(throwing: error)
                            return
                        }
                        continuation.yield(.skipped(title: descriptor.title, reason: error.localizedDescription))
                        lastError = error
                    }
                }
                continuation.finish(throwing: lastError)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
