import Foundation
import FoundationModels

/// Turns an MCP tool (JSON Schema known only at runtime) into a Foundation Models `Tool`, so the
/// on-device model and Claude-via-Foundation-Models can call it. Every call goes through the
/// shared `ToolBox`, which enforces the action rule.
struct MCPBridgeTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let box: ToolBox

    init(_ tool: MCPTool, box: ToolBox) throws {
        name = tool.name
        description = tool.description
        parameters = try JSONSchemaBridge.generationSchema(for: tool)
        self.box = box
    }

    func call(arguments: GeneratedContent) async throws -> String {
        await box.handle(name, argumentsJSON: arguments.jsonString)
    }
}

/// JSON Schema (the subset MCP servers use: object, array, string, integer, number, boolean,
/// enum) → `DynamicGenerationSchema`.
enum JSONSchemaBridge {
    static func generationSchema(for tool: MCPTool) throws -> GenerationSchema {
        try GenerationSchema(root: dynamic(tool.schemaObject, name: tool.name), dependencies: [])
    }

    static func dynamic(_ schema: [String: Any], name: String) -> DynamicGenerationSchema {
        let description = schema["description"] as? String
        if let choices = schema["enum"] as? [String], !choices.isEmpty {
            return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
        }
        switch schema["type"] as? String {
        case "object":
            let required = Set(schema["required"] as? [String] ?? [])
            let props = (schema["properties"] as? [String: Any] ?? [:])
                .sorted { $0.key < $1.key }
                .compactMap { key, value -> DynamicGenerationSchema.Property? in
                    guard let sub = value as? [String: Any] else { return nil }
                    return .init(name: key, description: sub["description"] as? String,
                                 schema: dynamic(sub, name: "\(name)_\(key)"),
                                 isOptional: !required.contains(key))
                }
            return DynamicGenerationSchema(name: name, description: description, properties: props)
        case "array":
            let items = schema["items"] as? [String: Any] ?? ["type": "string"]
            return DynamicGenerationSchema(arrayOf: dynamic(items, name: "\(name)_item"))
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }
}
