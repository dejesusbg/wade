import Foundation
import WadeExecution
import WadeIPC
import os

/// Runs the execution stage for each Stage 2 fire and exposes the streaming text to SwiftUI.
/// The providers are the user's primary and optional fallback from Settings, run through
/// `ProviderChain` (no provider is special-cased). Placeholder surface for Phase 4; Phase 6
/// replaces the window with the menu-bar popover.
@MainActor
@Observable
final class ExecutionEngine {
    enum Status: Equatable {
        case streaming
        case done
        case dropped  // the model said there's nothing worth offering
        case failed(String)
    }

    struct Suggestion: Identifiable {
        let id: String
        let mode: String?
        let concepts: [String]
        var providerName = ""
        var sendsDataOffDevice = false
        var skipped: [String] = []  // providers tried first and why they didn't run
        var text = ""
        var status = Status.streaming
        let startedAt = Date()
        var firstTokenAfter: TimeInterval?
        var finishedAfter: TimeInterval?
    }

    private(set) var current: Suggestion?

    var primaryID: String {
        didSet { UserDefaults.standard.set(primaryID, forKey: Self.primaryKey) }
    }
    var fallbackID: String? {
        didSet { UserDefaults.standard.set(fallbackID ?? "", forKey: Self.fallbackKey) }
    }
    /// Seconds a provider may take to produce its first text before the next one is tried.
    var timeoutSeconds: Double {
        didSet { UserDefaults.standard.set(timeoutSeconds, forKey: Self.timeoutKey) }
    }
    static let timeoutRange: ClosedRange<Double> = 1.5...10  // below ~1.5s even the on-device model misses its first answer after launch
    /// Which vendors have a key in the Keychain (for Settings; keys themselves are never held here).
    private(set) var keyed: Set<Vendor> = Set(Vendor.allCases.filter { APIKeyStore.read($0) != nil })

    var chain: [ProviderDescriptor] {
        [ProviderCatalog.find(primaryID), ProviderCatalog.find(fallbackID)]
            .compactMap { $0 }
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private let memory: MemoryModel
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "wade", category: "execution")
    private static let primaryKey = "execution.primary"
    private static let fallbackKey = "execution.fallback"
    private static let timeoutKey = "execution.timeout"

    init(memory: MemoryModel) {
        self.memory = memory
        let d = UserDefaults.standard
        primaryID = d.string(forKey: Self.primaryKey).flatMap { ProviderCatalog.find($0)?.id }
            ?? ProviderCatalog.defaultPrimaryID
        let storedTimeout = d.double(forKey: Self.timeoutKey)
        let defaultTimeout = Double(ProviderChain.defaultFirstTokenTimeout.components.seconds)
            + Double(ProviderChain.defaultFirstTokenTimeout.components.attoseconds) / 1e18
        timeoutSeconds = storedTimeout > 0 ? min(max(storedTimeout, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
                                          : defaultTimeout
        if let stored = d.string(forKey: Self.fallbackKey) {
            fallbackID = stored.isEmpty ? nil : ProviderCatalog.find(stored)?.id
        } else {
            fallbackID = ProviderCatalog.defaultFallbackID
        }
    }

    func saveKey(_ key: String, for vendor: Vendor) {
        APIKeyStore.save(key, for: vendor)
        refreshKeys()
    }

    func removeKey(for vendor: Vendor) {
        APIKeyStore.delete(vendor)
        refreshKeys()
    }

    private func refreshKeys() {
        keyed = Set(Vendor.allCases.filter { APIKeyStore.read($0) != nil })
    }

    func run(_ trigger: TriggerFired) {
        task?.cancel()
        let prompt = ExecutionPrompt(trigger: trigger, facts: memory.facts, corrections: memory.corrections)
        let chain = chain
        current = Suggestion(id: trigger.suggestionId, mode: trigger.mode, concepts: trigger.jspaceConcepts)
        log.info("execution: \(chain.map(\.id).joined(separator: " → "), privacy: .public) for \(trigger.kind ?? "?", privacy: .public)/\(trigger.mode ?? "?", privacy: .public)")

        task = Task { [weak self] in
            let timeout = Duration.milliseconds(Int((self?.timeoutSeconds ?? 2.5) * 1000))
            let stream = ProviderChain.run(chain, prompt: prompt, firstTokenTimeout: timeout) { descriptor in
                descriptor.makeProvider(key: APIKeyStore.read(descriptor.vendor))
            }
            do {
                for try await event in stream {
                    guard let self, !Task.isCancelled, var s = self.current else { return }
                    // Mutate a local copy, then assign: reading and writing `current` in one
                    // expression is an exclusivity violation (a runtime abort).
                    switch event {
                    case .skipped(let title, let reason):
                        s.skipped.append("\(title): \(reason)")
                    case .using(let title, let offDevice):
                        s.providerName = title
                        s.sendsDataOffDevice = offDevice
                    case .text(let delta):
                        if s.firstTokenAfter == nil { s.firstTokenAfter = Date().timeIntervalSince(s.startedAt) }
                        s.text += delta
                    }
                    self.current = s
                }
                guard let self else { return }
                self.finish(self.isNothing(self.current?.text ?? "") ? .dropped : .done)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.finish(.failed(error.localizedDescription))
            }
        }
    }

    /// A made-up trigger shaped like the UX demo's "code fast" moment, to test streaming end to
    /// end without waiting for a real Stage 2 fire.
    func runSample() {
        run(Self.sampleTrigger())
    }

    static func sampleTrigger() -> TriggerFired {
        TriggerFired(
            suggestionId: "sample-\(UUID().uuidString.prefix(8))", gateScore: 0,
            jspaceConcepts: ["download", "clone"],
            tkgDigest: "In Google Chrome ('dejesusbg/monet: A lightweight JavaScript library…', github.com) for 16s.",
            timestamp: Date().timeIntervalSince1970, mode: "coding", kind: "settled",
            context: ["app": "Google Chrome", "title": "dejesusbg/monet",
                      "url": "https://github.com/dejesusbg/monet",
                      "excerpt": "Code · Local · Codespaces · Clone · HTTPS · SSH · GitHub CLI · https://github.com/dejesusbg/monet.git · Clone using the web URL. · Download ZIP"])
    }

    private func finish(_ status: Status) {
        guard var c = current else { return }
        c.status = status
        c.finishedAfter = Date().timeIntervalSince(c.startedAt)
        current = c
        log.info("execution done: \(String(describing: status), privacy: .public) via \(c.providerName, privacy: .public) first token \(c.firstTokenAfter ?? -1)s total \(c.finishedAfter ?? -1)s skipped \(c.skipped.count)")
    }

    private func isNothing(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .uppercased() == ExecutionPrompt.nothing
    }
}
