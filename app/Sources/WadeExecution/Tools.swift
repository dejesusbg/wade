import Foundation

// Tool abstractions shared by every execution provider (CLAUDE.md §5.6). The MCP specifics live
// in WadeTools; providers only see these types.
//
// The action rule (user decision, 2026-09-25): a tool marked read-only by its server may run
// while a suggestion is being composed, to make it specific. Every other tool, including
// unmarked ones (the safe default is "ask"), never runs during composition: calling it records
// a `ProposedAction` that runs only when the user clicks "Do it".

/// One callable tool, as offered to a model for this suggestion.
public struct MCPTool: Sendable, Hashable {
    public let name: String          // unique across servers, e.g. "files.write_file"
    public let description: String
    public let inputSchema: String   // JSON Schema (object) as JSON text
    public let readOnly: Bool        // server says readOnlyHint: true
    public let integration: String   // e.g. "filesystem", "github"

    public init(name: String, description: String, inputSchema: String = #"{"type":"object"}"#,
                readOnly: Bool = false, integration: String = "") {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.integration = integration
    }

    /// "github__fork_repository" → "fork repository"; "wade__save_note" → "save note".
    public var actionPhrase: String {
        let base = name.components(separatedBy: "__").last ?? name
        return base.replacingOccurrences(of: "_", with: " ")
    }

    /// The schema as a JSON object (for wire formats that embed it).
    public var schemaObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(inputSchema.utf8)) as? [String: Any]) ?? ["type": "object"]
    }
}

/// A side-effecting call the model wants to make; runs only on the user's click.
public struct ProposedAction: Sendable, Equatable, Identifiable {
    public let id: String
    public let tool: MCPTool
    public let argumentsJSON: String

    public init(tool: MCPTool, argumentsJSON: String) {
        self.id = UUID().uuidString
        self.tool = tool
        self.argumentsJSON = argumentsJSON
    }
}

/// Executes tools. Implemented by WadeTools over MCP; faked in tests.
public protocol ToolRunner: Sendable {
    /// Run a tool with JSON-object arguments; returns the tool's text output.
    func call(_ tool: MCPTool, argumentsJSON: String) async throws -> String
}

/// What a provider streams: text for the user, plus tool activity.
public enum ExecutionEvent: Sendable, Equatable {
    case text(String)
    case toolRan(name: String, ok: Bool)
    case proposed(ProposedAction)
}

/// The tools for one suggestion, and how calls to them are handled. Shared by every provider,
/// so the action rule is enforced in exactly one place.
public struct ToolBox: Sendable {
    public let tools: [MCPTool]
    public let runner: (any ToolRunner)?
    public let onEvent: @Sendable (ExecutionEvent) -> Void

    public init(tools: [MCPTool], runner: (any ToolRunner)?, onEvent: @escaping @Sendable (ExecutionEvent) -> Void) {
        self.tools = tools
        self.runner = runner
        self.onEvent = onEvent
    }

    public static let none = ToolBox(tools: [], runner: nil, onEvent: { _ in })

    public func tool(named name: String) -> MCPTool? { tools.first { $0.name == name } }

    /// Handle a model's call: run it if read-only, otherwise propose it. Returns the text the
    /// model sees as the tool result.
    public func handle(_ name: String, argumentsJSON: String) async -> String {
        guard let tool = tool(named: name) else { return "Error: unknown tool \(name)." }
        if !tool.readOnly {
            onEvent(.proposed(ProposedAction(tool: tool, argumentsJSON: argumentsJSON)))
            // Name the exact action: small models otherwise describe a neighbouring one (e.g. the
            // text said "clone" while the button forked, 5 of 5 runs).
            return """
                Not run yet. The user now sees a "Do it" button for exactly this action: \(tool.actionPhrase) \
                \(argumentsJSON). Write ONE sentence offering this same action (say "\(tool.actionPhrase)", \
                not a different verb), e.g. "\(tool.actionPhrase.prefix(1).uppercased() + tool.actionPhrase.dropFirst()) …?"
                """
        }
        guard let runner else { return "Error: tools are unavailable." }
        do {
            let output = try await runner.call(tool, argumentsJSON: argumentsJSON)
            onEvent(.toolRan(name: name, ok: true))
            return String(output.prefix(4_000))  // keep small models' context in budget
        } catch {
            onEvent(.toolRan(name: name, ok: false))
            return "Error: \(error.localizedDescription)"
        }
    }
}
