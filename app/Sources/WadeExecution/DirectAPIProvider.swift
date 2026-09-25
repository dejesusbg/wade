import Foundation

/// The plain-HTTPS route (CLAUDE.md §5.5), vendor-neutral: HTTP, SSE parsing and error mapping
/// are shared, and a small `DirectWire` per vendor owns its request format and turn loop
/// (including tool calls, where the vendor supports them here). The hedge against rough edges in
/// the Foundation Models route (§8).
public struct DirectAPIProvider: ExecutionProvider {
    let wire: any DirectWire
    public let model: String
    public let displayName: String
    public let sendsDataOffDevice = true
    public var supportsTools: Bool { wire.supportsTools }
    private let apiKey: String?
    private let maxTokens: Int

    public init(wire: any DirectWire, model: String, apiKey: String?, displayName: String, maxTokens: Int = 1024) {
        self.wire = wire
        self.model = model
        self.apiKey = apiKey
        self.displayName = displayName
        // Room for a two-sentence answer plus any reasoning the vendor counts against output.
        self.maxTokens = maxTokens
    }

    public func generate(prompt: ExecutionPrompt, tools: ToolBox) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let apiKey, !apiKey.isEmpty else { throw ExecutionError.missingAPIKey(wire.vendorName) }
                    try await wire.run(model: model, apiKey: apiKey, prompt: prompt, maxTokens: maxTokens,
                                       tools: wire.supportsTools ? tools : .none) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// One vendor's HTTP format and turn loop.
public protocol DirectWire: Sendable {
    var vendorName: String { get }
    var supportsTools: Bool { get }
    func run(model: String, apiKey: String, prompt: ExecutionPrompt, maxTokens: Int, tools: ToolBox,
             emit: @escaping @Sendable (String) -> Void) async throws
}

public enum StreamEvent: Equatable {
    case text(String)
    case done(reason: String?)
    case error(type: String, message: String)
    case ignored
}

/// POST a request and stream its SSE events. Non-200 responses become `ExecutionError.http`.
func streamEvents(_ request: URLRequest, httpError: @escaping @Sendable (Int, String) -> ExecutionError)
    -> AsyncThrowingStream<SSEParser.Event, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    var body = ""
                    for try await line in bytes.lines { body += line }
                    throw httpError(status, body)
                }
                var parser = SSEParser()
                let debug = ProcessInfo.processInfo.environment["WADE_DEBUG_SSE"] == "1"
                for try await line in bytes.lines {
                    if debug { FileHandle.standardError.write(Data("[sse] \(line.prefix(240))\n".utf8)) }
                    // `lines` drops the blank line that ends an SSE event; each event from these
                    // APIs has a single `data:` line, so a data line completes it.
                    _ = parser.feed(line)
                    if line.hasPrefix("data:"), let event = parser.feed("") { continuation.yield(event) }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private func parse(_ text: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
}

// MARK: - Anthropic Messages API

public struct AnthropicWire: DirectWire {
    public let vendorName = "Anthropic Claude"
    /// Tool use on this route (tool_use / tool_result loop, or the remote MCP connector) is left
    /// for when there are Claude credits to test it; Claude gets tools via Foundation Models.
    public let supportsTools = false
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

    public func run(model: String, apiKey: String, prompt: ExecutionPrompt, maxTokens: Int, tools: ToolBox,
                    emit: @escaping @Sendable (String) -> Void) async throws {
        let req = try request(model: model, apiKey: apiKey, prompt: prompt, maxTokens: maxTokens)
        for try await event in streamEvents(req, httpError: { httpError(status: $0, body: $1) }) {
            switch decode(event) {
            case .text(let text): emit(text)
            case .error(let type, let message): throw ExecutionError.stream(type: type, message: message)
            case .done, .ignored: break
            }
        }
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
    public let supportsTools = true
    static let maxToolRounds = 4
    public init() {}

    public func request(model: String, apiKey: String, prompt: ExecutionPrompt, maxTokens: Int,
                        contents: [[String: Any]]? = nil, tools: [MCPTool] = []) throws -> URLRequest {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse")!
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 60
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")  // header, never the URL
        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": prompt.instructions(toolsAvailable: !tools.isEmpty)]]],
            "contents": contents ?? [["role": "user", "parts": [["text": prompt.message]]]],
            // Minimal thinking: a two-sentence suggestion doesn't need reasoning, and thinking
            // delays the first word. (`thinkingBudget: 0` is rejected by 3.x models; this isn't.)
            "generationConfig": ["maxOutputTokens": maxTokens, "thinkingConfig": ["thinkingLevel": "minimal"]],
        ]
        if !tools.isEmpty {
            body["tools"] = [["functionDeclarations": tools.map {
                ["name": $0.name, "description": $0.description, "parameters": $0.schemaObject] as [String: Any]
            }]]
        }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    /// Streams a turn; when the model calls functions, answers them through the ToolBox (read-only
    /// ones run, others become proposals) and continues. Gemini 3 requires the model's parts,
    /// including `thoughtSignature`, to be echoed back verbatim, so raw parts are kept.
    public func run(model: String, apiKey: String, prompt: ExecutionPrompt, maxTokens: Int, tools: ToolBox,
                    emit: @escaping @Sendable (String) -> Void) async throws {
        let text = tools.tools.isEmpty ? prompt.message : prompt.messageWithTools
        var contents: [[String: Any]] = [["role": "user", "parts": [["text": text]]]]
        for _ in 0..<Self.maxToolRounds {
            let req = try request(model: model, apiKey: apiKey, prompt: prompt, maxTokens: maxTokens,
                                  contents: contents, tools: tools.tools)
            var modelParts: [[String: Any]] = []
            var calls: [(name: String, argumentsJSON: String)] = []
            for try await event in streamEvents(req, httpError: { httpError(status: $0, body: $1) }) {
                guard let json = parse(event.data) else { continue }
                if let err = json["error"] as? [String: Any] {
                    throw ExecutionError.stream(type: err["status"] as? String ?? "error", message: err["message"] as? String ?? "")
                }
                let chunk = Self.parts(json)
                modelParts += chunk
                for part in chunk {
                    if let call = part["functionCall"] as? [String: Any], let name = call["name"] as? String {
                        let data = try? JSONSerialization.data(withJSONObject: call["args"] ?? [String: Any]())
                        calls.append((name, data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"))
                    } else if (part["thought"] as? Bool) != true, let text = part["text"] as? String, !text.isEmpty {
                        emit(text)
                    }
                }
            }
            guard !calls.isEmpty else { return }
            contents.append(["role": "model", "parts": modelParts])
            var responses: [[String: Any]] = []
            for call in calls {
                let result = await tools.handle(call.name, argumentsJSON: call.argumentsJSON)
                responses.append(["functionResponse": ["name": call.name, "response": ["result": result]]])
            }
            contents.append(["role": "user", "parts": responses])  // all responses in one turn
        }
    }

    static func parts(_ json: [String: Any]) -> [[String: Any]] {
        let candidate = (json["candidates"] as? [[String: Any]])?.first
        return ((candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
    }

    /// Text-only decoding of one chunk.
    public func decode(_ event: SSEParser.Event) -> StreamEvent {
        guard let json = parse(event.data) else { return .ignored }
        if let err = json["error"] as? [String: Any] {
            return .error(type: err["status"] as? String ?? "error", message: err["message"] as? String ?? "")
        }
        let parts = Self.parts(json)
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        if !text.isEmpty { return .text(text) }
        let candidate = (json["candidates"] as? [[String: Any]])?.first
        if let reason = candidate?["finishReason"] as? String { return .done(reason: reason) }
        return .ignored
    }

    public func httpError(status: Int, body: String) -> ExecutionError {
        let err = parse(body)?["error"] as? [String: Any]
        return .http(status: status, type: err?["status"] as? String,
                     message: err?["message"] as? String ?? String(body.prefix(200)))
    }
}
