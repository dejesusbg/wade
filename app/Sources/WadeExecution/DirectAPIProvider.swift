import Foundation

/// The plain-HTTPS route (CLAUDE.md §5.5), vendor-neutral: the HTTP loop and SSE parsing are
/// shared, and a small `DirectWire` adapter per vendor knows its endpoint, headers, body and
/// stream events. The hedge against rough edges in the Foundation Models route (§8), and where a
/// remote-MCP connector would plug in for Claude (the Foundation Models package doesn't expose one).
public struct DirectAPIProvider: ExecutionProvider {
    let wire: any DirectWire
    public let model: String
    public let displayName: String
    public let sendsDataOffDevice = true
    private let apiKey: String?
    private let maxTokens: Int

    public init(wire: any DirectWire, model: String, apiKey: String?, displayName: String, maxTokens: Int = 1024) {
        self.wire = wire
        self.model = model
        self.apiKey = apiKey
        self.displayName = displayName
        // Room for a two-sentence answer plus any model-internal reasoning the vendor counts
        // against the output budget; the prompt itself caps the visible length.
        self.maxTokens = maxTokens
    }

    func request(for prompt: ExecutionPrompt) throws -> URLRequest {
        guard let apiKey, !apiKey.isEmpty else { throw ExecutionError.missingAPIKey(wire.vendorName) }
        return try wire.request(model: model, apiKey: apiKey, prompt: prompt, maxTokens: maxTokens)
    }

    public func generate(prompt: ExecutionPrompt, tools: [MCPTool]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request(for: prompt))
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw wire.httpError(status: status, body: body)
                    }
                    var parser = SSEParser()
                    let debug = ProcessInfo.processInfo.environment["WADE_DEBUG_SSE"] == "1"
                    for try await line in bytes.lines {
                        if debug { FileHandle.standardError.write(Data("[sse] \(line.prefix(240))\n".utf8)) }
                        // `lines` drops the blank line that ends an SSE event; each event from
                        // these APIs has a single `data:` line, so a data line completes it.
                        _ = parser.feed(line)
                        guard line.hasPrefix("data:"), let event = parser.feed("") else { continue }
                        switch wire.decode(event) {
                        case .text(let text): continuation.yield(text)
                        case .error(let type, let message): throw ExecutionError.stream(type: type, message: message)
                        case .done, .ignored: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// One vendor's HTTP + streaming format.
public protocol DirectWire: Sendable {
    var vendorName: String { get }
    func request(model: String, apiKey: String, prompt: ExecutionPrompt, maxTokens: Int) throws -> URLRequest
    func decode(_ event: SSEParser.Event) -> StreamEvent
    func httpError(status: Int, body: String) -> ExecutionError
}

public enum StreamEvent: Equatable {
    case text(String)
    case done(reason: String?)
    case error(type: String, message: String)
    case ignored
}

// MARK: - Anthropic Messages API

public struct AnthropicWire: DirectWire {
    public let vendorName = "Anthropic Claude"
    public init() {}

    public func request(model: String, apiKey: String, prompt: ExecutionPrompt, maxTokens: Int) throws -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 60
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": maxTokens, "stream": true,
            "system": prompt.instructions,
            "messages": [["role": "user", "content": prompt.message]],
        ] as [String: Any])
        return r
    }

    /// content_block_delta/text_delta → text; message_delta stop_reason → done; error → error;
    /// message_start, content_block_start/stop, message_stop, ping → ignored.
    public func decode(_ event: SSEParser.Event) -> StreamEvent {
        guard let json = parse(event.data), let type = json["type"] as? String else { return .ignored }
        switch type {
        case "content_block_delta":
            let delta = json["delta"] as? [String: Any]
            if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String { return .text(text) }
            return .ignored
        case "message_delta":
            let stop = (json["delta"] as? [String: Any])?["stop_reason"] as? String
            return stop == nil ? .ignored : .done(reason: stop)
        case "error":
            let err = json["error"] as? [String: Any]
            return .error(type: err?["type"] as? String ?? "error", message: err?["message"] as? String ?? "")
        default:
            return .ignored
        }
    }

    public func httpError(status: Int, body: String) -> ExecutionError {
        let err = parse(body)?["error"] as? [String: Any]
        return .http(status: status, type: err?["type"] as? String,
                     message: err?["message"] as? String ?? String(body.prefix(200)))
    }
}

// MARK: - Google Gemini API

public struct GeminiWire: DirectWire {
    public let vendorName = "Google Gemini"
    public init() {}

    public func request(model: String, apiKey: String, prompt: ExecutionPrompt, maxTokens: Int) throws -> URLRequest {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse")!
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 60
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")  // header, never the URL
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": prompt.instructions]]],
            "contents": [["role": "user", "parts": [["text": prompt.message]]]],
            // Minimal thinking: a two-sentence suggestion doesn't need reasoning, and thinking
            // delays the first word. (`thinkingBudget: 0` is rejected by 3.x models; this isn't.)
            "generationConfig": ["maxOutputTokens": maxTokens, "thinkingConfig": ["thinkingLevel": "minimal"]],
        ] as [String: Any])
        return r
    }

    /// Each SSE chunk is a GenerateContentResponse carrying *new* text in
    /// candidates[0].content.parts[].text (parts marked `thought` are skipped), plus a
    /// finishReason on the last one.
    public func decode(_ event: SSEParser.Event) -> StreamEvent {
        guard let json = parse(event.data) else { return .ignored }
        if let err = json["error"] as? [String: Any] {
            return .error(type: err["status"] as? String ?? "error", message: err["message"] as? String ?? "")
        }
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { return .ignored }
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        if !text.isEmpty { return .text(text) }
        if let reason = candidate["finishReason"] as? String { return .done(reason: reason) }
        return .ignored
    }

    public func httpError(status: Int, body: String) -> ExecutionError {
        let err = parse(body)?["error"] as? [String: Any]
        return .http(status: status, type: err?["status"] as? String,
                     message: err?["message"] as? String ?? String(body.prefix(200)))
    }
}

private func parse(_ text: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
}
