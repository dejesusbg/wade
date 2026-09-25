import Foundation

/// Plain-HTTPS provider: the Messages API over URLSession with SSE streaming, no SDK (Swift has
/// no official Anthropic SDK; raw HTTP is the documented route). The hedge against rough edges
/// in the Foundation Models route (CLAUDE.md §8), and the place a future remote-MCP connector
/// (`mcp_servers`) would plug in, since the Foundation Models package doesn't expose it.
public struct DirectAPIProvider: ExecutionProvider {
    public let model: String
    public let displayName: String
    public let sendsDataOffDevice = true
    private let apiKey: String?
    private let endpoint: URL
    private let maxTokens: Int

    public init(model: String, displayName: String, apiKey: String?,
                endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
                maxTokens: Int = 300) {
        self.model = model
        self.displayName = displayName
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.maxTokens = maxTokens  // a two-sentence suggestion; not a long generation
    }

    func request(for prompt: ExecutionPrompt) throws -> URLRequest {
        guard let apiKey, !apiKey.isEmpty else { throw ExecutionError.missingAPIKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": prompt.instructions,
            "messages": [["role": "user", "content": prompt.message]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
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
                        throw Self.httpError(status: status, body: body)
                    }
                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        // `lines` drops blank lines, which is what ends an SSE event; each
                        // Messages API event is one `event:` line then one `data:` line, so a
                        // data line completes the event.
                        _ = parser.feed(line)
                        guard line.hasPrefix("data:"), let event = parser.feed("") else { continue }
                        switch MessagesStreamEvent.decode(event) {
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

    static func httpError(status: Int, body: String) -> ExecutionError {
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let err = json?["error"] as? [String: Any]
        return .http(status: status, type: err?["type"] as? String,
                     message: err?["message"] as? String ?? String(body.prefix(200)))
    }
}
