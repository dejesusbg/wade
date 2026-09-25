import Foundation

/// The execution stage (CLAUDE.md §5.5): turns a Stage 2 fire into a written suggestion.
///
/// Every backend is an interchangeable implementation of this one protocol, the fallback
/// included; nothing is special-cased. Implementations yield *text deltas* (new text only), so
/// the UI appends without caring which provider is running. Tool activity (a read-only tool ran,
/// an action was proposed) is reported through the `ToolBox`, the same way for every provider.
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
    /// Whether this provider can call tools. Those that can't simply write text.
    var supportsTools: Bool { get }
    func generate(prompt: ExecutionPrompt, tools: ToolBox) -> AsyncThrowingStream<String, Error>
}

public enum ExecutionError: LocalizedError, Equatable {
    case missingAPIKey(String)
    case modelUnavailable(String)
    case http(status: Int, type: String?, message: String)
    case stream(type: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let vendor):
            "No \(vendor) API key. Add one in Settings → Suggestions."
        case .modelUnavailable(let reason):
            "The model isn't available: \(reason)"
        case .http(let status, let type, let message):
            "API error \(status)\(type.map { " (\($0))" } ?? ""): \(message)"
        case .stream(let type, let message):
            "Stream error (\(type)): \(message)"
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
