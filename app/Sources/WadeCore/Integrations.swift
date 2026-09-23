/// Integrations the user can opt into during onboarding (CLAUDE.md §5.6). Each becomes an MCP
/// server in Phase 5; until then opting in only records the choice. Copy stays domain-general.
public struct Integration: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let summary: String
    public let systemImage: String
}

public enum IntegrationCatalog {
    public static let all: [Integration] = [
        Integration(
            id: "filesystem",
            name: "Files",
            summary: "Read and organize files in folders you choose.",
            systemImage: "folder"),
        Integration(
            id: "github",
            name: "GitHub",
            summary: "Look up repositories, issues, pull requests, and releases.",
            systemImage: "chevron.left.forwardslash.chevron.right"),
    ]
}
