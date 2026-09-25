import Foundation
import Testing
import WadeCore
import WadeIPC
@testable import WadeExecution

private func events(_ raw: String, _ decode: (SSEParser.Event) -> StreamEvent) -> [StreamEvent] {
    var parser = SSEParser()
    return raw.components(separatedBy: "\n").compactMap { parser.feed($0) }.map(decode)
}

private func trigger(context: [String: String]? = nil) -> TriggerFired {
    TriggerFired(suggestionId: "s", gateScore: 0, jspaceConcepts: ["download", "clone"],
                 tkgDigest: "In Chrome ('monet', github.com) for 15s.", timestamp: 1,
                 mode: "coding", kind: "settled", context: context)
}

@Suite struct AnthropicWireTests {
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
        #expect(events(raw, AnthropicWire().decode).filter { $0 != .ignored } == [.text("Clone "), .text("it."), .done(reason: "end_turn")])
    }

    @Test func decodesMidStreamErrorAndHTTPErrors() {
        let raw = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n"
        #expect(events(raw, AnthropicWire().decode) == [.error(type: "overloaded_error", message: "Overloaded")])
        let e = AnthropicWire().httpError(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        #expect(e == .http(status: 401, type: "authentication_error", message: "invalid x-api-key"))
    }

    @Test func requestHeadersAndBody() throws {
        let r = try AnthropicWire().request(model: "claude-haiku-4-5", apiKey: "sk-test",
                                            prompt: ExecutionPrompt(trigger: trigger(), facts: [], corrections: []), maxTokens: 300)
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "claude-haiku-4-5" && body["stream"] as? Bool == true)
    }
}

@Suite struct GeminiWireTests {
    @Test func decodesIncrementalTextSkippingThoughts() {
        let raw = """
        data: {"candidates":[{"content":{"parts":[{"text":"thinking…","thought":true}],"role":"model"}}]}

        data: {"candidates":[{"content":{"parts":[{"text":"Clone it with "}],"role":"model"}}]}

        data: {"candidates":[{"content":{"parts":[{"text":"git clone."}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"totalTokenCount":42}}

        """
        #expect(events(raw, GeminiWire().decode).filter { $0 != .ignored } == [.text("Clone it with "), .text("git clone.")])
    }

    @Test func decodesErrors() {
        let raw = "data: {\"error\":{\"code\":429,\"message\":\"Quota exceeded\",\"status\":\"RESOURCE_EXHAUSTED\"}}\n\n"
        #expect(events(raw, GeminiWire().decode) == [.error(type: "RESOURCE_EXHAUSTED", message: "Quota exceeded")])
        let e = GeminiWire().httpError(status: 400, body: #"{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}"#)
        #expect(e == .http(status: 400, type: "INVALID_ARGUMENT", message: "API key not valid"))
    }

    @Test func requestUsesHeaderKeyAndStreamingEndpoint() throws {
        let r = try GeminiWire().request(model: "gemini-flash-latest", apiKey: "AIza-test",
                                         prompt: ExecutionPrompt(trigger: trigger(), facts: [], corrections: []), maxTokens: 300,
                                         tools: [MCPTool(name: "files__list_directory", description: "List", inputSchema: #"{"type":"object","properties":{"path":{"type":"string"}}}"#, readOnly: true)])
        #expect(r.url!.absoluteString.hasSuffix("/models/gemini-flash-latest:streamGenerateContent?alt=sse"))
        #expect(!r.url!.absoluteString.contains("AIza"))  // key in the header, never the URL
        #expect(r.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-test")
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        #expect(body["systemInstruction"] != nil && body["contents"] != nil)
        let thinking = (body["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
        #expect(thinking?["thinkingLevel"] as? String == "minimal")
        let decls = ((body["tools"] as? [[String: Any]])?.first?["functionDeclarations"] as? [[String: Any]]) ?? []
        #expect(decls.first?["name"] as? String == "files__list_directory")
    }
}

@Suite struct SSEParserTests {
    @Test func handlesCRLF() {
        var parser = SSEParser()
        _ = parser.feed("event: x\r")
        _ = parser.feed("data: {\"a\":1}\r")
        #expect(parser.feed("\r") == SSEParser.Event(event: "x", data: "{\"a\":1}"))
    }

    @Test func snapshotsBecomeDeltas() {
        var d = SnapshotDiffer()
        #expect(["Hel", "Hello", "Hello wor", "Hello world"].map { d.delta(for: $0) } == ["Hel", "lo", " wor", "ld"])
    }
}

@Suite struct ExecutionPromptTests {
    @Test func includesTriggerContextFactsAndCorrections() {
        let now = Date()
        let prompt = ExecutionPrompt(
            trigger: trigger(context: ["app": "Chrome", "url": "https://github.com/dejesusbg/monet"]),
            facts: [OnboardingFact(id: 1, text: "I use GitHub daily", createdAt: now, updatedAt: now)],
            corrections: [CorrectionFact(id: 1, suggestionId: "old", suggestion: "clone the repo",
                                         correction: "just the release binary next time",
                                         provenance: "user_correction", createdAt: now)])
        let m = prompt.message
        #expect(m.contains("(mode: coding)") && m.contains("download, clone"))
        #expect(m.contains("- Address: https://github.com/dejesusbg/monet"))
        #expect(m.contains("- I use GitHub daily") && m.contains("just the release binary next time"))
        #expect(!m.contains("Selected text"))
        #expect(prompt.instructions.contains(ExecutionPrompt.nothing))
    }
}

@Suite struct CatalogTests {
    @Test func defaultsAreOnDevicePrimaryAndGeminiLiteFallback() {
        #expect(ProviderCatalog.find(ProviderCatalog.defaultPrimaryID)?.vendor == .apple)
        #expect(ProviderCatalog.find(ProviderCatalog.defaultFallbackID)?.id == "google.gemini-flash-lite.direct")
        #expect(ProviderChain.defaultFirstTokenTimeout == .seconds(5))
    }

    @Test func everyEntryResolvesOrExplainsWhyNot() {
        for d in ProviderCatalog.all {
            switch d.makeProvider(key: "k") {
            case .success(let p): #expect(p.sendsDataOffDevice == d.sendsDataOffDevice, "\(d.id)")
            case .failure: #expect(d.setupRequired != nil, "\(d.id) failed without a stated reason")
            }
        }
    }

    @Test func cloudEntriesNeedAKey() {
        let gemini = ProviderCatalog.find("google.gemini-flash.direct")!
        guard case .failure(.missingAPIKey) = gemini.makeProvider(key: nil) else {
            Issue.record("expected missingAPIKey"); return
        }
        guard case .success = ProviderCatalog.find("apple.on-device")!.makeProvider(key: nil) else {
            Issue.record("on-device needs no key"); return
        }
    }
}

/// A provider with scripted behaviour, for exercising the chain without a network.
private struct FakeProvider: ExecutionProvider {
    let displayName: String
    let sendsDataOffDevice = false
    let supportsTools = false
    let chunks: [String]
    let failAfter: Int?  // throw after this many chunks
    var delay: Duration = .zero  // before the first chunk

    func generate(prompt: ExecutionPrompt, tools: ToolBox) -> AsyncThrowingStream<String, Error> {
        let (chunks, failAfter, delay) = (chunks, failAfter, delay)
        return AsyncThrowingStream { c in
          Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            for (i, chunk) in chunks.enumerated() {
                if failAfter == i { c.finish(throwing: ExecutionError.stream(type: "boom", message: "")); return }
                c.yield(chunk)
            }
            if failAfter == chunks.count { c.finish(throwing: ExecutionError.stream(type: "boom", message: "")); return }
            c.finish()
          }
        }
    }
}

@Suite struct ProviderChainTests {
    private let a = ProviderCatalog.find("google.gemini-flash.direct")!
    private let b = ProviderCatalog.find("apple.on-device")!
    private let prompt = ExecutionPrompt(trigger: trigger(), facts: [], corrections: [])

    private func collect(timeout: Duration = .seconds(8),
                         _ resolve: @escaping ProviderChain.Resolver) async -> (events: [ProviderChain.Event], error: Bool) {
        var out: [ProviderChain.Event] = []
        do {
            for try await e in ProviderChain.run([a, b], prompt: prompt, firstTokenTimeout: timeout, resolve: resolve) { out.append(e) }
            return (out, false)
        } catch {
            return (out, true)
        }
    }

    @Test func fallbackRunsWhenPrimaryHasNoKey() async {
        let r = await collect { d in
            d.id == a.id ? .failure(.missingAPIKey("Google Gemini"))
                         : .success(FakeProvider(displayName: "B", chunks: ["hi"], failAfter: nil))
        }
        #expect(r.events.first.map { if case .skipped = $0 { true } else { false } } == true)
        #expect(r.events.contains(.text("hi")) && !r.error)
    }

    @Test func fallbackRunsWhenPrimaryFailsBeforeAnyText() async {
        let r = await collect { d in
            .success(FakeProvider(displayName: d.id, chunks: d.id == a.id ? [] : ["ok"], failAfter: d.id == a.id ? 0 : nil))
        }
        #expect(r.events.contains(.text("ok")) && !r.error)
    }

    @Test func slowPrimaryTimesOutToFallback() async {
        let r = await collect(timeout: .milliseconds(200)) { d in
            .success(FakeProvider(displayName: d.id, chunks: [d.id == a.id ? "late" : "fast"], failAfter: nil,
                                  delay: d.id == a.id ? .seconds(5) : .zero))
        }
        #expect(r.events.contains(.text("fast")) && !r.events.contains(.text("late")) && !r.error)
    }

    @Test func toolActivityCountsAsProgressForTheTimeout() async {
        // A provider that proposes an action right away, then writes text after the timeout.
        struct Proposer: ExecutionProvider {
            let displayName = "P"; let sendsDataOffDevice = false; let supportsTools = true
            func generate(prompt: ExecutionPrompt, tools: ToolBox) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { c in
                    Task {
                        _ = await tools.handle("wade__save_note", argumentsJSON: "{}")
                        try? await Task.sleep(for: .milliseconds(400))
                        c.yield("Save it?"); c.finish()
                    }
                }
            }
        }
        let save = MCPTool(name: "wade__save_note", description: "Save", readOnly: false)
        var got: [ProviderChain.Event] = []
        let stream = ProviderChain.run([a], prompt: prompt, tools: ToolBox(tools: [save], runner: nil, onEvent: { _ in }),
                                       firstTokenTimeout: .milliseconds(200)) { _ in .success(Proposer()) }
        do { for try await e in stream { got.append(e) } } catch { Issue.record("chain threw: \(error) events: \(got)") }
        #expect(got.contains(.text("Save it?")))
    }

    @Test func noSwitchingMidSentence() async {
        let r = await collect { d in
            .success(FakeProvider(displayName: d.id, chunks: ["half "], failAfter: d.id == a.id ? 1 : nil))
        }
        #expect(r.error)
        #expect(r.events.filter { if case .using = $0 { true } else { false } }.count == 1)
    }
}


/// Records calls; never touches a real server.
private final class RecordingRunner: ToolRunner, @unchecked Sendable {
    var calls: [String] = []
    func call(_ tool: MCPTool, argumentsJSON: String) async throws -> String {
        calls.append(tool.name)
        return "listing"
    }
}

@Suite struct ActionRuleTests {
    private let read = MCPTool(name: "files__list_directory", description: "List", readOnly: true, integration: "filesystem")
    private let write = MCPTool(name: "wade__save_note", description: "Save", readOnly: false, integration: "filesystem")
    private let unmarked = MCPTool(name: "github__mystery", description: "?", integration: "github")

    @Test func readOnlyRunsWriteIsOnlyProposed() async {
        let runner = RecordingRunner()
        final class Events: @unchecked Sendable { var list: [ExecutionEvent] = [] }
        let events = Events()
        let box = ToolBox(tools: [read, write, unmarked], runner: runner) { events.list.append($0) }

        #expect(await box.handle(read.name, argumentsJSON: "{}") == "listing")
        let w = await box.handle(write.name, argumentsJSON: #"{"title":"t"}"#)
        let u = await box.handle(unmarked.name, argumentsJSON: "{}")
        #expect(w.contains("Not run yet") && u.contains("Not run yet"))
        #expect(runner.calls == [read.name])  // the write and the unmarked tool never ran
        #expect(events.list.filter { if case .proposed = $0 { true } else { false } }.count == 2)
        #expect(await box.handle("files__rm_rf", argumentsJSON: "{}").hasPrefix("Error: unknown tool"))
    }

    @Test func toolPromptPutsTheActionFirst() {
        let p = ExecutionPrompt(trigger: trigger(), facts: [], corrections: [])
        #expect(p.instructions(toolsAvailable: true).contains("CALL THAT TOOL NOW"))
        #expect(!p.instructions(toolsAvailable: false).contains("tools"))
        #expect(p.messageWithTools.contains("call it first"))
    }
}
