import Foundation
import Testing
import WadeCore
import WadeIPC
@testable import WadeExecution

@Suite struct SSETests {
    private func events(_ raw: String) -> [MessagesStreamEvent] {
        var parser = SSEParser()
        return raw.components(separatedBy: "\n").compactMap { parser.feed($0) }.map(MessagesStreamEvent.decode)
    }

    @Test func decodesTextDeltasAndIgnoresTheRest() {
        let raw = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message"}}

        event: ping
        data: {"type":"ping"}

        : keep-alive comment

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Clone "}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"it."}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let got = events(raw).filter { $0 != .ignored }
        #expect(got == [.text("Clone "), .text("it."), .done(stopReason: "end_turn")])
    }

    @Test func decodesMidStreamError() {
        let raw = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n"
        #expect(events(raw) == [.error(type: "overloaded_error", message: "Overloaded")])
    }

    @Test func handlesCRLF() {
        var parser = SSEParser()
        _ = parser.feed("event: content_block_delta\r")
        _ = parser.feed("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}\r")
        #expect(parser.feed("\r").map(MessagesStreamEvent.decode) == .text("x"))
    }

    @Test func mapsHTTPErrors() {
        let e = DirectAPIProvider.httpError(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        #expect(e == .http(status: 401, type: "authentication_error", message: "invalid x-api-key"))
    }
}

@Suite struct SnapshotDifferTests {
    @Test func turnsCumulativeSnapshotsIntoDeltas() {
        var d = SnapshotDiffer()
        #expect(["Hel", "Hello", "Hello wor", "Hello world"].map { d.delta(for: $0) } == ["Hel", "lo", " wor", "ld"])
    }
}

@Suite struct ExecutionPromptTests {
    private func trigger() -> TriggerFired {
        TriggerFired(suggestionId: "s", gateScore: 0, jspaceConcepts: ["download", "clone"],
                     tkgDigest: "In Chrome ('monet', github.com) for 15s.", timestamp: 1,
                     mode: "coding", kind: "settled",
                     context: ["app": "Chrome", "url": "https://github.com/dejesusbg/monet", "excerpt": "Clone HTTPS SSH"])
    }

    @Test func includesTriggerContextFactsAndCorrections() {
        let now = Date()
        let prompt = ExecutionPrompt(
            trigger: trigger(),
            facts: [OnboardingFact(id: 1, text: "I use GitHub daily", createdAt: now, updatedAt: now)],
            corrections: [CorrectionFact(id: 1, suggestionId: "old", suggestion: "clone the repo",
                                         correction: "just the release binary next time",
                                         provenance: "user_correction", createdAt: now)])
        let m = prompt.message
        #expect(m.contains("(mode: coding)") && m.contains("download, clone"))
        #expect(m.contains("- Address: https://github.com/dejesusbg/monet"))
        #expect(m.contains("- I use GitHub daily"))
        #expect(m.contains("just the release binary next time"))
        #expect(!m.contains("Selected text"))  // absent fields are omitted
        #expect(prompt.instructions.contains(ExecutionPrompt.nothing))
    }

    @Test func instructionsAreStableAcrossSuggestions() {
        let a = ExecutionPrompt(trigger: trigger(), facts: [], corrections: [])
        var t = trigger(); t.tkgDigest = "different"
        let b = ExecutionPrompt(trigger: t, facts: [], corrections: [])
        #expect(a.instructions == b.instructions && a.message != b.message)
    }
}

@Suite struct ProviderChoiceTests {
    @Test func defaultIsClaudeHaikuViaFoundationModels() {
        #expect(ProviderChoice.default == .claudeHaikuAFM)
    }

    @Test func claudeWithoutKeyFallsBackToOnDevice() {
        #expect(ProviderChoice.effective(selected: .claudeHaikuAFM, apiKey: nil) == .onDevice)
        #expect(ProviderChoice.effective(selected: .claudeHaikuAFM, apiKey: "") == .onDevice)
        #expect(ProviderChoice.effective(selected: .claudeHaikuAFM, apiKey: "sk-ant-x") == .claudeHaikuAFM)
        #expect(!ProviderChoice.onDevice.makeProvider(apiKey: nil).sendsDataOffDevice)
        #expect(ProviderChoice.claudeHaikuDirect.makeProvider(apiKey: "k").sendsDataOffDevice)
    }

    @Test func directRequestHasTheRequiredHeadersAndBody() throws {
        let p = DirectAPIProvider(model: "claude-haiku-4-5", displayName: "x", apiKey: "sk-test")
        let r = try p.request(for: ExecutionPrompt(
            trigger: TriggerFired(suggestionId: "s", gateScore: 0, jspaceConcepts: [], tkgDigest: "d", timestamp: 1),
            facts: [], corrections: []))
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "claude-haiku-4-5" && body["stream"] as? Bool == true)
        #expect(throws: ExecutionError.missingAPIKey) {
            try DirectAPIProvider(model: "m", displayName: "x", apiKey: nil)
                .request(for: ExecutionPrompt(trigger: TriggerFired(suggestionId: "s", gateScore: 0,
                    jspaceConcepts: [], tkgDigest: "d", timestamp: 1), facts: [], corrections: []))
        }
    }
}
