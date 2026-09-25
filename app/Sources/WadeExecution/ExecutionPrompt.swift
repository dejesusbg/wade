import Foundation
import WadeCore
import WadeIPC

/// Everything the execution model sees (CLAUDE.md §9 Phase 4): the Stage 2 fire (mode, J-space
/// concepts, digest, screen context) plus what the user has told Wade (onboarding facts) and
/// what they corrected before (correction facts).
public struct ExecutionPrompt: Sendable, Equatable {
    public var mode: String?
    public var kind: String?
    public var concepts: [String]
    public var digest: String
    public var context: [String: String]
    public var facts: [String]
    public var corrections: [(suggestion: String, correction: String)]

    /// Reply the model gives when it has nothing genuinely useful: the suggestion is dropped.
    public static let nothing = "NOTHING"

    public init(trigger: TriggerFired, facts: [OnboardingFact], corrections: [CorrectionFact]) {
        mode = trigger.mode
        kind = trigger.kind
        concepts = trigger.jspaceConcepts
        digest = trigger.tkgDigest
        context = trigger.context ?? [:]
        self.facts = facts.map(\.text)
        self.corrections = corrections.suffix(10).map { ($0.suggestion, $0.correction) }
    }

    public static func == (a: ExecutionPrompt, b: ExecutionPrompt) -> Bool {
        a.instructions == b.instructions && a.message == b.message
    }

    /// System-level instructions: stable across suggestions (cache-friendly for cloud providers).
    public var instructions: String { instructions(toolsAvailable: false) }

    /// Instructions, plus how to use tools when the provider offers some for this suggestion.
    public func instructions(toolsAvailable: Bool) -> String {
        guard toolsAvailable else { return baseInstructions }
        return baseInstructions + " " + Self.toolGuidance
    }

    static let toolGuidance = """
        You have tools. Step 1: if one of your tools would do the helpful thing itself (for \
        example save a note, create an issue), CALL THAT TOOL NOW with complete arguments. It will \
        not run until the user clicks "Do it", so calling it is safe and is how you offer it. You \
        may also call a read-only tool first to be more specific. Step 2: write the one-sentence \
        offer, e.g. "Save this paragraph to your notes?". Never claim an action already happened.
        """

    private var baseInstructions: String {
        """
        You are Wade, a quiet assistant in the user's Mac menu bar. Something on their screen \
        suggests help may be welcome right now. Write ONE short, concrete suggestion: at most two \
        sentences, under 40 words. Start with the action itself (for example "Clone it with …", \
        "The error means …"). No greeting, no preamble, no questions back. Use the details on \
        screen (names, URLs, error text) so it's specific. Reply in the language the user is \
        working in. If there's nothing genuinely useful to offer, reply with exactly \(Self.nothing).
        """
    }

    /// The per-suggestion message.
    public var message: String {
        var parts: [String] = []

        var why = "Why Wade is speaking up"
        if let mode { why += " (mode: \(mode))" }
        why += ":"
        var whyLines = ["- Recent activity: \(digest)"]
        if !concepts.isEmpty {
            whyLines.append("- What Wade noticed (its internal reading): \(concepts.joined(separator: ", "))")
        }
        parts.append(([why] + whyLines).joined(separator: "\n"))

        let screenFields: [(String, String)] = [
            ("App", "app"), ("Window", "title"), ("Address", "url"), ("On screen", "excerpt"),
            ("Selected text", "selection"), ("Error message", "error_text"),
        ]
        let screen = screenFields.compactMap { label, key in
            context[key].flatMap { $0.isEmpty ? nil : "- \(label): \($0)" }
        }
        if !screen.isEmpty {
            parts.append((["What's on screen:"] + screen).joined(separator: "\n"))
        }

        if !facts.isEmpty {
            parts.append((["What the user has told Wade about themselves:"] + facts.map { "- \($0)" })
                .joined(separator: "\n"))
        }
        if !corrections.isEmpty {
            let lines = corrections.map { "- Wade suggested \"\($0.suggestion)\"; the user said: \"\($0.correction)\"" }
            parts.append((["Earlier corrections (respect them):"] + lines).joined(separator: "\n"))
        }

        parts.append("Write the suggestion now, or \(Self.nothing).")
        return parts.joined(separator: "\n\n")
    }

    /// The message for a provider that has tools: the action comes first.
    public var messageWithTools: String {
        message.replacingOccurrences(
            of: "Write the suggestion now, or \(Self.nothing).",
            with: "If a tool would do the helpful thing, call it first (it only runs when the user agrees). Then write the one-sentence offer, or \(Self.nothing).")
    }
}
