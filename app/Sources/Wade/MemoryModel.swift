import Foundation
import WadeCore
import os

/// Observable view of the memory stores for SwiftUI. Every mutation writes through to SQLite
/// and then re-reads, so the UI always shows exactly what's persisted.
@MainActor
@Observable
final class MemoryModel {
    private(set) var facts: [OnboardingFact] = []
    private(set) var enabledIntegrations: Set<String> = []
    private(set) var corrections: [CorrectionFact] = []
    private(set) var onboardingCompleted = false
    private(set) var lastError: String?

    private let store: MemoryStore
    private let log = Logger(subsystem: "wade", category: "memory")

    init(url: URL? = MemoryStore.defaultURL) {
        do {
            store = try MemoryStore(url: url)
        } catch {
            // Keep the app usable; the UI surfaces that nothing will be saved.
            Logger(subsystem: "wade", category: "memory").error("falling back to in-memory store: \(error)")
            store = try! MemoryStore(url: nil)
            lastError = "Couldn't open Wade's memory file; changes won't be saved. (\(error))"
        }
        reload()
    }

    func reload() {
        do {
            facts = try store.onboardingFacts()
            enabledIntegrations = try store.enabledIntegrations()
            corrections = try store.correctionFacts()
        } catch {
            report(error)
        }
        onboardingCompleted = store.onboardingCompleted
    }

    func addFact(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        mutate { try store.addOnboardingFact(text) }
    }

    func updateFact(_ id: Int64, text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleteFact(id)
        } else {
            mutate { try store.updateOnboardingFact(id: id, text: text) }
        }
    }

    func deleteFact(_ id: Int64) { mutate { try store.deleteOnboardingFact(id: id) } }

    func setIntegration(_ id: String, enabled: Bool) {
        mutate { try store.setIntegration(id, enabled: enabled) }
    }

    func deleteCorrection(_ id: Int64) { mutate { try store.deleteCorrection(id: id) } }

    /// Explicit feedback on one suggestion (Phase 6's reject / correct).
    func addCorrection(suggestionId: String, suggestion: String, correction: String,
                       provenance: CorrectionFact.Provenance) {
        let text = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        mutate {
            try store.addCorrection(suggestionId: suggestionId, suggestion: suggestion,
                                    correction: text, provenance: provenance)
        }
    }

    func completeOnboarding() {
        store.onboardingCompleted = true
        reload()
    }

    /// Write through to SQLite, then re-read so the UI reflects what's actually persisted.
    private func mutate(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            report(error)
        }
        reload()
    }

    private func report(_ error: Error) {
        log.error("\(error)")
        lastError = "\(error)"
    }
}
