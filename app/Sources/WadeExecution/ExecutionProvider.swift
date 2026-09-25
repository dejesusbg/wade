import Foundation

/// The execution stage (CLAUDE.md §5.5): turns a Stage 2 fire into a written suggestion.
///
/// Every backend is an interchangeable implementation of this one protocol, the fallback
/// included; nothing is special-cased. Implementations yield *text deltas* (new text only), so
/// the UI appends without caring which provider is running.
///
/// Deviation from the brief's sketch (`AsyncStream<String>`): the stream is *throwing*, so a
/// missing key, a rate limit or a network failure reaches the UI instead of silently ending the
/// stream.
///
/// This call is always separate from Stage 2's trigger check (CLAUDE.md §4): different process,
/// different model, and it never sees activations.
public protocol ExecutionProvider: Sendable {
    /// Short name for Settings and logs, e.g. "Claude Haiku 4.5 (Foundation Models)".
    var displayName: String { get }
    /// True when prompts leave the Mac (sent to a cloud API). Surfaced in Settings.
    var sendsDataOffDevice: Bool { get }
    func generate(prompt: ExecutionPrompt, tools: [MCPTool]) -> AsyncThrowingStream<String, Error>
}

/// Placeholder for Phase 5's MCP tool layer: accepted by every provider now, used by none yet.
public struct MCPTool: Sendable, Hashable {
    public let name: String
    public let description: String
    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public enum ExecutionError: LocalizedError, Equatable {
    case missingAPIKey
    case modelUnavailable(String)
    case http(status: Int, type: String?, message: String)
    case stream(type: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No Claude API key. Add one in Settings → Suggestions, or switch to the on-device model."
        case .modelUnavailable(let reason):
            "The model isn't available: \(reason)"
        case .http(let status, let type, let message):
            "Claude API error \(status)\(type.map { " (\($0))" } ?? ""): \(message)"
        case .stream(let type, let message):
            "Claude stream error (\(type)): \(message)"
        }
    }
}

/// Converts a stream of cumulative snapshots ("Hel", "Hello", "Hello wor") into deltas
/// ("Hel", "lo", " wor"). Foundation Models streams snapshots; the protocol promises deltas.
struct SnapshotDiffer {
    private var last = ""

    mutating func delta(for snapshot: String) -> String {
        defer { last = snapshot }
        if snapshot.hasPrefix(last) {
            return String(snapshot.dropFirst(last.count))
        }
        // The model revised earlier text (rare). Emit nothing rather than duplicating; the
        // final snapshot is still available to callers that need it.
        return ""
    }
}
