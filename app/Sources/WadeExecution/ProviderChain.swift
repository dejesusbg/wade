import Foundation

/// Runs a user-chosen ordered list of providers (primary, then fallback) through one code path.
/// No provider is special: the fallback is just the next entry, picked by the user from the same
/// catalog (CLAUDE.md §5.5, "don't hardcode the fallback").
///
/// A provider is skipped when it can't start (missing key, setup not done), fails *before*
/// producing any text, or produces no text within `firstTokenTimeout` (a suggestion that arrives
/// late is useless: the moment has passed). Once text has streamed, an error is reported
/// instead of switching providers mid-sentence. The same rules apply to every provider.
public enum ProviderChain {
    public enum Event: Sendable, Equatable {
        case skipped(title: String, reason: String)
        case using(title: String, offDevice: Bool)
        case text(String)
    }

    public typealias Resolver = @Sendable (ProviderDescriptor) -> Result<any ExecutionProvider, ExecutionError>

    public static let defaultFirstTokenTimeout: Duration = .milliseconds(2500)

    public static func run(_ chain: [ProviderDescriptor], prompt: ExecutionPrompt,
                           firstTokenTimeout: Duration = defaultFirstTokenTimeout,
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
                    let produced = Flag()
                    let timedOut = Flag()
                    // Watchdog: cancel this provider if no text arrives in time. It records that it
                    // fired, because a cancelled stream consumer ends quietly rather than throwing.
                    let attempt = Task {
                        for try await delta in provider.generate(prompt: prompt, tools: []) {
                            try Task.checkCancellation()
                            produced.set()
                            continuation.yield(.text(delta))
                        }
                    }
                    let dbg = ProcessInfo.processInfo.environment["WADE_DEBUG_CHAIN"] == "1"
                    let t0 = ContinuousClock.now
                    let watchdog = Task {
                        try await Task.sleep(for: firstTokenTimeout)
                        if dbg { FileHandle.standardError.write(Data("[chain] watchdog fired at \(ContinuousClock.now - t0), produced=\(produced.isSet)\n".utf8)) }
                        if !produced.isSet {
                            timedOut.set()
                            attempt.cancel()
                        }
                    }
                    let failure: Error?
                    do {
                        try await attempt.value
                        failure = nil
                    } catch {
                        failure = error
                    }
                    if dbg { FileHandle.standardError.write(Data("[chain] attempt ended at \(ContinuousClock.now - t0), failure=\(String(describing: failure))\n".utf8)) }
                    watchdog.cancel()
                    if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
                    if produced.isSet {
                        // Text was shown: finish (or fail) here, never switch mid-sentence.
                        if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
                        return
                    }
                    if timedOut.isSet {
                        let reason = "no text within \(firstTokenTimeout)"
                        continuation.yield(.skipped(title: descriptor.title, reason: reason))
                        lastError = ExecutionError.modelUnavailable("\(descriptor.title): \(reason)")
                        continue
                    }
                    if let failure {
                        continuation.yield(.skipped(title: descriptor.title, reason: failure.localizedDescription))
                        lastError = failure
                        continue
                    }
                    continuation.finish()  // finished normally without text: nothing to say
                    return
                }
                continuation.finish(throwing: lastError)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Thread-safe one-way flag shared between a provider attempt and its watchdog.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
