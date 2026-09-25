import Foundation
import WadeExecution

/// Wade-level tools composed from MCP tools (CLAUDE.md §5.6, "tool composition"). A small model
/// struggles with raw `write_file`, which needs an absolute path inside an allowed folder it
/// doesn't know; `save_note(title, content)` is easy to call, and Wade maps it onto the
/// filesystem server's `write_file` with a safe path it builds itself. Composed tools are still
/// subject to the action rule: `save_note` writes, so it only ever runs on the user's click.
public enum ComposedTools {
    public static let saveNoteName = "wade__save_note"

    public static func saveNote() -> MCPTool {
        MCPTool(
            name: saveNoteName,
            description: "Save text to the user's notes as a Markdown note. Use it to offer keeping a selected passage, a quote, or a summary.",
            inputSchema: #"""
            {"type":"object","properties":{
              "title":{"type":"string","description":"Short note title, a few words"},
              "content":{"type":"string","description":"The note's text (Markdown). Include the source URL if known."}
            },"required":["title","content"]}
            """#,
            readOnly: false,
            integration: "filesystem")
    }

    /// Translate a composed call into the underlying MCP call: (tool name on the server, arguments).
    static func expand(_ tool: MCPTool, argumentsJSON: String, notesFolder: String?, now: Date = .now)
        throws -> (serverTool: String, argumentsJSON: String) {
        guard tool.name == saveNoteName else { throw ToolError.unavailable("unknown composed tool \(tool.name)") }
        guard let folder = notesFolder else { throw ToolError.unavailable("No notes folder is set up (Settings → Integrations → Files).") }
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let title = (args["title"] as? String ?? "Note").trimmingCharacters(in: .whitespacesAndNewlines)
        let content = args["content"] as? String ?? ""
        let path = (folder as NSString).appendingPathComponent("\(datePrefix(now)) \(safeFileName(title)).md")
        let body = "# \(title)\n\n\(content)\n"
        let data = try JSONSerialization.data(withJSONObject: ["path": path, "content": body])
        return ("write_file", String(data: data, encoding: .utf8) ?? "{}")
    }

    /// Keeps letters, digits, spaces and a few separators; caps the length. Never a path.
    static func safeFileName(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_,."))
        let cleaned = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
            .split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return String((cleaned.isEmpty ? "Note" : cleaned).prefix(60))
    }

    static func datePrefix(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"  // seconds: two notes with one title in the same minute must not overwrite each other
        return f.string(from: date)
    }
}
