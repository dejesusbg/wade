import Foundation
import MCP
import System
import WadeExecution

/// One running MCP server: a child process speaking MCP over stdio, and a client to it.
actor MCPConnection {
    let spec: MCPServerSpec
    private let process = Process()
    private let client = Client(name: "Wade", version: "0.1.0")
    private(set) var tools: [MCPTool] = []

    init(spec: MCPServerSpec) {
        self.spec = spec
    }

    func start() async throws {
        let toServer = Pipe(), fromServer = Pipe()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(spec.environment) { _, new in new }
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = FileHandle.nullDevice
        try process.run()

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: fromServer.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: toServer.fileHandleForWriting.fileDescriptor))
        _ = try await client.connect(transport: transport)

        var listed: [Tool] = []
        var cursor: String?
        repeat {
            let page = try await client.listTools(cursor: cursor)
            listed += page.tools
            cursor = page.nextCursor
        } while cursor != nil

        tools = listed.map { tool in
            MCPTool(name: "\(spec.prefix)__\(tool.name)",
                    description: tool.description ?? tool.name,
                    inputSchema: Self.json(tool.inputSchema) ?? #"{"type":"object"}"#,
                    // Only an explicit read-only hint counts; unmarked tools are treated as writes.
                    readOnly: tool.annotations.readOnlyHint == true,
                    integration: spec.integration)
        }
    }

    func call(_ tool: MCPTool, argumentsJSON: String) async throws -> String {
        let serverName = String(tool.name.dropFirst(spec.prefix.count + 2))
        let arguments = try JSONDecoder().decode([String: Value].self, from: Data(argumentsJSON.utf8))
        let (content, isError) = try await client.callTool(name: serverName, arguments: arguments)
        let text = content.compactMap { item -> String? in
            if case .text(let text, _, _) = item { return text }
            return nil
        }.joined(separator: "\n")
        if isError == true { throw ToolError.failed(text.isEmpty ? "\(serverName) failed" : text) }
        return text.isEmpty ? "Done." : text
    }

    func stop() async {
        await client.disconnect()
        if process.isRunning { process.terminate() }
    }

    private static func json(_ value: Value) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

public enum ToolError: LocalizedError {
    case failed(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let message): message
        case .unavailable(let message): message
        }
    }
}
