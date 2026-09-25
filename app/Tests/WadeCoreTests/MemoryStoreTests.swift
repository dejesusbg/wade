import Foundation
import Testing
@testable import WadeCore

@Suite struct MemoryStoreTests {
    @Test func startsEmpty() throws {
        let store = try MemoryStore(url: nil)
        #expect(try store.onboardingFacts().isEmpty)
        #expect(try store.correctionFacts().isEmpty)
        #expect(try store.enabledIntegrations().isEmpty)
        #expect(!store.onboardingCompleted)
    }

    @Test func onboardingFactsCRUD() throws {
        let store = try MemoryStore(url: nil)
        let fact = try store.addOnboardingFact("  I'm a nurse \n")
        #expect(fact.text == "I'm a nurse")
        try store.addOnboardingFact("I work night shifts")
        try store.updateOnboardingFact(id: fact.id, text: "I'm an ICU nurse")
        #expect(try store.onboardingFacts().map(\.text) == ["I'm an ICU nurse", "I work night shifts"])
        try store.deleteOnboardingFact(id: fact.id)
        #expect(try store.onboardingFacts().map(\.text) == ["I work night shifts"])
    }

    @Test func integrationOptInsUpsert() throws {
        let store = try MemoryStore(url: nil)
        try store.setIntegration("github", enabled: true)
        try store.setIntegration("filesystem", enabled: true)
        try store.setIntegration("filesystem", enabled: false)
        #expect(try store.enabledIntegrations() == ["github"])
    }

    @Test func correctionsAreProvenanceTaggedAndSeparate() throws {
        let store = try MemoryStore(url: nil)
        try store.addOnboardingFact("I'm a nurse")
        let c = try store.addCorrection(
            suggestionId: "s1", suggestion: "clone the repo", correction: "just the release binary next time")
        #expect(try store.correctionFacts() == [c])
        #expect(c.provenance == "user_correction")
        let r = try store.addCorrection(suggestionId: "s2", suggestion: "fork the repo",
                                        correction: "Not helpful here", provenance: .rejection)
        #expect(try store.correctionFacts().map(\.provenance) == ["user_correction", "user_rejection"])
        #expect(r.provenance == "user_rejection")
        #expect(try store.onboardingFacts().count == 1)
    }

    @Test func persistsAcrossReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "wade-test-\(UUID().uuidString)/memory.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try MemoryStore(url: url)
            try store.addOnboardingFact("I use GitHub daily")
            try store.setIntegration("github", enabled: true)
            store.onboardingCompleted = true
        }
        let reopened = try MemoryStore(url: url)
        #expect(try reopened.onboardingFacts().map(\.text) == ["I use GitHub daily"])
        #expect(try reopened.enabledIntegrations() == ["github"])
        #expect(reopened.onboardingCompleted)
    }
}
