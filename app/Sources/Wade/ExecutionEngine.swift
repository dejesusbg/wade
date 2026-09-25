import Foundation
import WadeExecution
import WadeIPC
import os

/// Runs the execution stage for each Stage 2 fire and exposes the streaming text to SwiftUI.
/// Placeholder surface for Phase 4; Phase 6 replaces the window with the menu-bar popover.
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
        let providerName: String
        let sendsDataOffDevice: Bool
        var text = ""
        var status = Status.streaming
        let startedAt = Date()
        var firstTokenAfter: TimeInterval?
        var finishedAfter: TimeInterval?
    }

    private(set) var current: Suggestion?

    var selected: ProviderChoice {
        didSet { UserDefaults.standard.set(selected.rawValue, forKey: Self.providerKey) }
    }
    private(set) var hasAPIKey = APIKeyStore.read() != nil

    /// What will actually run: Claude choices need a key; without one, the on-device model.
    var effective: ProviderChoice { ProviderChoice.effective(selected: selected, apiKey: hasAPIKey ? "x" : nil) }

    private let memory: MemoryModel
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "wade", category: "execution")
    private static let providerKey = "executionProvider"

    init(memory: MemoryModel) {
        self.memory = memory
        let stored = UserDefaults.standard.string(forKey: Self.providerKey).flatMap(ProviderChoice.init)
        selected = stored ?? .default
    }

    func saveAPIKey(_ key: String) {
        APIKeyStore.save(key)
        hasAPIKey = APIKeyStore.read() != nil
    }

    func removeAPIKey() {
        APIKeyStore.delete()
        hasAPIKey = false
    }

    func run(_ trigger: TriggerFired) {
        task?.cancel()
        let prompt = ExecutionPrompt(trigger: trigger, facts: memory.facts, corrections: memory.corrections)
        let choice = effective
        let provider = choice.makeProvider(apiKey: choice.usesClaude ? APIKeyStore.read() : nil)
        current = Suggestion(id: trigger.suggestionId, mode: trigger.mode, concepts: trigger.jspaceConcepts,
                             providerName: provider.displayName, sendsDataOffDevice: provider.sendsDataOffDevice)
        log.info("execution: \(provider.displayName, privacy: .public) for \(trigger.kind ?? "?", privacy: .public)/\(trigger.mode ?? "?", privacy: .public)")

        task = Task { [weak self] in
            do {
                for try await delta in provider.generate(prompt: prompt, tools: []) {
                    guard let self, !Task.isCancelled else { return }
                    // Read `current` into locals before writing it: reading and writing the same
                    // property in one expression is an exclusivity violation (a runtime abort).
                    if var s = self.current {
                        if s.firstTokenAfter == nil { s.firstTokenAfter = Date().timeIntervalSince(s.startedAt) }
                        s.text += delta
                        self.current = s
                    }
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
        run(TriggerFired(
            suggestionId: "sample-\(UUID().uuidString.prefix(8))", gateScore: 0,
            jspaceConcepts: ["download", "clone"],
            tkgDigest: "In Google Chrome ('dejesusbg/monet: A lightweight JavaScript library…', github.com) for 16s.",
            timestamp: Date().timeIntervalSince1970, mode: "coding", kind: "settled",
            context: ["app": "Google Chrome", "title": "dejesusbg/monet",
                      "url": "https://github.com/dejesusbg/monet",
                      "excerpt": "Code · Local · Codespaces · Clone · HTTPS · SSH · GitHub CLI · https://github.com/dejesusbg/monet.git · Clone using the web URL. · Download ZIP"]))
    }

    private func finish(_ status: Status) {
        guard var c = current else { return }
        c.status = status
        c.finishedAfter = Date().timeIntervalSince(c.startedAt)
        current = c
        log.info("execution done: \(String(describing: status), privacy: .public) first token \(c.firstTokenAfter ?? -1)s total \(c.finishedAfter ?? -1)s")
    }

    private func isNothing(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .uppercased() == ExecutionPrompt.nothing
    }
}
