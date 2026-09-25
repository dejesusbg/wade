import Foundation

/// How to launch each integration's MCP server (CLAUDE.md §5.6). New capability = a new entry
/// here (an MCP server), not a hand-written skill script.
public struct MCPServerSpec: Sendable, Equatable {
    public let integration: String   // matches IntegrationCatalog ids: "filesystem", "github"
    public let prefix: String        // tool-name namespace, e.g. "files" → "files__write_file"
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]

    /// Homebrew's bin isn't on a GUI app's PATH; servers launched via `npx` need `node` there.
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    static func locate(_ name: String) -> String? {
        searchPath.split(separator: ":").map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Official reference filesystem server, restricted to the folders the user picked.
    /// Version pinned so an upstream change can't silently alter what Wade can touch.
    public static func filesystem(folders: [String]) -> MCPServerSpec? {
        guard let npx = locate("npx"), !folders.isEmpty else { return nil }
        return MCPServerSpec(integration: "filesystem", prefix: "files", executable: npx,
                             arguments: ["-y", "@modelcontextprotocol/server-filesystem@2026.8.31"] + folders,
                             environment: ["PATH": searchPath])
    }

    /// GitHub's official MCP server (Homebrew `github-mcp-server`), default toolsets, the user's
    /// token passed only in its environment.
    public static func github(token: String) -> MCPServerSpec? {
        guard let bin = locate("github-mcp-server"), !token.isEmpty else { return nil }
        return MCPServerSpec(integration: "github", prefix: "github", executable: bin,
                             arguments: ["stdio"],
                             environment: ["PATH": searchPath, "GITHUB_PERSONAL_ACCESS_TOKEN": token])
    }
}
