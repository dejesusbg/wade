import ClaudeForFoundationModels
import Foundation

/// Every execution backend Settings can pick. "What's selected by default" and "what's possible
/// to select" are separate questions (CLAUDE.md §5.5): all entries go through the same
/// `ExecutionProvider` protocol; the default is just one of them.
public enum ProviderChoice: String, CaseIterable, Identifiable, Sendable {
    case claudeHaikuAFM = "claude-haiku-4-5.afm"
    case claudeSonnetAFM = "claude-sonnet-5.afm"
    case claudeOpusAFM = "claude-opus-5.afm"
    case claudeHaikuDirect = "claude-haiku-4-5.direct"
    case onDevice = "apple-on-device"

    /// The brief's default: fast and cheap, for a background utility writing two-sentence
    /// suggestions (latency and cost matter more than depth here).
    public static let `default`: ProviderChoice = .claudeHaikuAFM

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claudeHaikuAFM: "Claude Haiku 4.5 (fast, default)"
        case .claudeSonnetAFM: "Claude Sonnet 5 (stronger)"
        case .claudeOpusAFM: "Claude Opus 5 (strongest, slower)"
        case .claudeHaikuDirect: "Claude Haiku 4.5, direct API (fallback route)"
        case .onDevice: "Apple on-device model (private, offline)"
        }
    }

    public var usesClaude: Bool { self != .onDevice }

    public func makeProvider(apiKey: String?) -> any ExecutionProvider {
        switch self {
        case .claudeHaikuAFM: AFMProvider(backend: .claude(.haiku4_5, apiKey: apiKey), displayName: title)
        case .claudeSonnetAFM: AFMProvider(backend: .claude(.sonnet5, apiKey: apiKey), displayName: title)
        case .claudeOpusAFM: AFMProvider(backend: .claude(.opus5, apiKey: apiKey), displayName: title)
        case .claudeHaikuDirect: DirectAPIProvider(model: "claude-haiku-4-5", displayName: title, apiKey: apiKey)
        case .onDevice: AFMProvider(backend: .onDevice, displayName: title)
        }
    }

    /// The provider actually used: a Claude choice without a key falls back to on-device, so
    /// nothing is sent off the Mac until the user has explicitly added a key.
    public static func effective(selected: ProviderChoice, apiKey: String?) -> ProviderChoice {
        selected.usesClaude && (apiKey ?? "").isEmpty ? .onDevice : selected
    }
}
