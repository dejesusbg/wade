import ClaudeForFoundationModels
import Foundation

// Provider-agnostic catalog (CLAUDE.md §5.5). Every entry is vendor × model × route, built by
// the same factory into the same `ExecutionProvider` protocol. "What's selected by default" is a
// setting (a primary and an optional fallback, both picked from this list); "what's possible to
// select" is this list. Adding a provider means adding an entry here, plus a wire adapter only if
// it's a new vendor on the direct route.

public enum Vendor: String, CaseIterable, Sendable {
    case google, anthropic, apple

    public var name: String {
        switch self {
        case .google: "Google Gemini"
        case .anthropic: "Anthropic Claude"
        case .apple: "Apple"
        }
    }

    /// Cloud vendors need an API key; Apple's on-device model doesn't.
    public var needsKey: Bool { self != .apple }
}

public enum Route: String, Sendable {
    /// Apple's Foundation Models framework: `LanguageModelSession` over any `LanguageModel`.
    case foundationModels
    /// Plain HTTPS to the vendor's own API (a per-vendor wire adapter).
    case directAPI
}

public struct ProviderDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let vendor: Vendor
    public let route: Route
    public let model: String
    public let title: String
    /// Set when the entry can't run yet, and why (e.g. Firebase not configured).
    public let setupRequired: String?

    public var sendsDataOffDevice: Bool { vendor != .apple }

    /// A provider ready to run, or the reason it can't (missing key, setup not done).
    public func makeProvider(key: String?) -> Result<any ExecutionProvider, ExecutionError> {
        if let setupRequired { return .failure(.modelUnavailable(setupRequired)) }
        if vendor.needsKey, (key ?? "").isEmpty { return .failure(.missingAPIKey(vendor.name)) }
        switch (vendor, route) {
        case (.apple, _):
            return .success(AFMProvider(backend: .onDevice, displayName: title))
        case (.anthropic, .foundationModels):
            guard let model = ClaudeModelIDs.byID[model] else { return .failure(.modelUnavailable("unknown Claude model \(model)")) }
            return .success(AFMProvider(backend: .claude(model, apiKey: key), displayName: title))
        case (.anthropic, .directAPI):
            return .success(DirectAPIProvider(wire: AnthropicWire(), model: model, apiKey: key, displayName: title))
        case (.google, .directAPI):
            return .success(DirectAPIProvider(wire: GeminiWire(), model: model, apiKey: key, displayName: title))
        case (.google, .foundationModels):
            return .failure(.modelUnavailable("Gemini via Foundation Models isn't wired yet"))
        }
    }
}

public enum ProviderCatalog {
    public static let all: [ProviderDescriptor] = [
        ProviderDescriptor(id: "google.gemini-flash.direct", vendor: .google, route: .directAPI,
                           model: "gemini-flash-latest", title: "Gemini Flash (direct API)", setupRequired: nil),
        ProviderDescriptor(id: "google.gemini-flash.afm", vendor: .google, route: .foundationModels,
                           model: "gemini-flash-latest", title: "Gemini Flash (Foundation Models)",
                           setupRequired: "Needs a Firebase project, App Check and GoogleService-Info.plist (Firebase AI Logic). Not set up yet."),
        ProviderDescriptor(id: "anthropic.haiku-4-5.afm", vendor: .anthropic, route: .foundationModels,
                           model: "claude-haiku-4-5", title: "Claude Haiku 4.5 (Foundation Models)", setupRequired: nil),
        ProviderDescriptor(id: "anthropic.sonnet-5.afm", vendor: .anthropic, route: .foundationModels,
                           model: "claude-sonnet-5", title: "Claude Sonnet 5 (Foundation Models)", setupRequired: nil),
        ProviderDescriptor(id: "anthropic.opus-5.afm", vendor: .anthropic, route: .foundationModels,
                           model: "claude-opus-5", title: "Claude Opus 5 (Foundation Models)", setupRequired: nil),
        ProviderDescriptor(id: "anthropic.haiku-4-5.direct", vendor: .anthropic, route: .directAPI,
                           model: "claude-haiku-4-5", title: "Claude Haiku 4.5 (direct API)", setupRequired: nil),
        ProviderDescriptor(id: "apple.on-device", vendor: .apple, route: .foundationModels,
                           model: "system", title: "Apple on-device model (private, offline)", setupRequired: nil),
    ]

    /// Defaults (a user decision, 2026-09-25): Gemini Flash primary, since there are no Claude
    /// credits yet, departing from the brief's Claude Haiku default; Apple on-device as fallback.
    /// Both are ordinary settings, changeable in Settings → Suggestions.
    public static let defaultPrimaryID = "google.gemini-flash.direct"
    public static let defaultFallbackID: String? = "apple.on-device"

    public static func find(_ id: String?) -> ProviderDescriptor? {
        all.first { $0.id == id }
    }
}

enum ClaudeModelIDs {
    static let byID: [String: ClaudeModel] = [
        ClaudeModel.haiku4_5.id: .haiku4_5,
        ClaudeModel.sonnet5.id: .sonnet5,
        ClaudeModel.opus5.id: .opus5,
    ]
}
