import Foundation
import WadeExecution
import os

/// Runs the MCP servers for the integrations the user opted into, and routes tool calls to them.
/// It's the `ToolRunner` every execution provider uses; the action rule itself lives in
/// `ToolBox` (WadeExecution), so it's enforced once, the same way for every provider.
public actor MCPManager: ToolRunner {
    public struct Status: Sendable, Equatable {
        public var integration: String
        public var state: String      // "connected (14 tools)", "off", "error: …"
    }

    private var connections: [String: MCPConnection] = [:]
    private var specs: [String: MCPServerSpec] = [:]
    /// Where composed `save_note` writes: the first folder the user allowed for Files.
    private var notesFolder: String?
    public private(set) var statuses: [Status] = []
    private let log = Logger(subsystem: "wade", category: "tools")

    public init() {}

    /// Bring the running servers in line with the wanted set: start new ones, stop removed or
    /// changed ones. Safe to call on every settings change.
    public func apply(_ wanted: [MCPServerSpec], notesFolder: String? = nil) async {
        self.notesFolder = notesFolder
        let wantedByID = Dictionary(uniqueKeysWithValues: wanted.map { ($0.integration, $0) })
        for (id, connection) in connections where wantedByID[id] != specs[id] {
            await connection.stop()
            connections[id] = nil
            specs[id] = nil
        }
        var statuses: [Status] = []
        for spec in wanted {
            if connections[spec.integration] == nil {
                let connection = MCPConnection(spec: spec)
                do {
                    try await connection.start()
                    connections[spec.integration] = connection
                    specs[spec.integration] = spec
                } catch {
                    log.error("\(spec.integration, privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)")
                    statuses.append(Status(integration: spec.integration, state: "error: \(error.localizedDescription)"))
                    continue
                }
            }
            let count = await connections[spec.integration]?.tools.count ?? 0
            statuses.append(Status(integration: spec.integration, state: "connected (\(count) tools)"))
        }
        self.statuses = statuses
    }

    /// Every tool from connected servers, plus Wade's composed tools where their server is up.
    public func allTools() async -> [MCPTool] {
        var tools: [MCPTool] = []
        for connection in connections.values { tools += await connection.tools }
        if connections["filesystem"] != nil, notesFolder != nil { tools.append(ComposedTools.saveNote()) }
        return tools
    }

    public func call(_ tool: MCPTool, argumentsJSON: String) async throws -> String {
        guard let connection = connections[tool.integration] else {
            throw ToolError.unavailable("\(tool.integration) isn't connected")
        }
        log.info("tool call \(tool.name, privacy: .public)")
        if tool.name.hasPrefix("wade__") {
            let (serverTool, args) = try ComposedTools.expand(tool, argumentsJSON: argumentsJSON, notesFolder: notesFolder)
            let spec = specs[tool.integration]!
            let underlying = MCPTool(name: "\(spec.prefix)__\(serverTool)", description: "", readOnly: false,
                                     integration: tool.integration)
            return try await connection.call(underlying, argumentsJSON: args)
        }
        return try await connection.call(tool, argumentsJSON: argumentsJSON)
    }

    public func stopAll() async {
        for connection in connections.values { await connection.stop() }
        connections = [:]
        specs = [:]
        statuses = []
    }
}
