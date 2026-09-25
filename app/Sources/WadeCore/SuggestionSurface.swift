import Foundation

/// When the menu-bar popover opens by itself, and what the icon shows (CLAUDE.md §5.1, Phase 6).
/// Pure, so it's testable without AppKit.
public enum SuggestionSurface {
    /// What the execution stage is doing with the latest suggestion.
    public enum Phase: Equatable, Sendable {
        case none
        case composing(hasText: Bool)
        case finished(hasText: Bool)
        case quiet   // the model found nothing worth offering
        case failed
    }

    public enum Icon: Equatable, Sendable {
        case notObserving, idle, composing, ready

        public var symbolName: String {
            switch self {
            case .notObserving: "circle.dashed"
            case .idle: "circle"
            case .composing: "circle.dotted.circle"
            case .ready: "circle.fill"
            }
        }
    }

    /// `seen`: the user has opened the popover for this suggestion (or it opened itself).
    public static func icon(observing: Bool, phase: Phase, seen: Bool) -> Icon {
        guard observing else { return .notObserving }
        switch phase {
        case .composing: return .composing
        case .finished(let hasText): return hasText && !seen ? .ready : .idle
        case .none, .quiet, .failed: return .idle
        }
    }

    /// Open on the first words, never for an empty, quiet or failed suggestion, and at most once
    /// per suggestion: if the user closes it, it stays closed (the icon still shows it's there).
    public static func shouldAutoOpen(phase: Phase, alreadyShown: Bool) -> Bool {
        guard !alreadyShown else { return false }
        switch phase {
        case .composing(let hasText), .finished(let hasText): return hasText
        case .none, .quiet, .failed: return false
        }
    }
}
