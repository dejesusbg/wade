import Foundation

/// Opt-in research log of what happened to each suggestion (CLAUDE.md §9, Phase 7: "log …
/// user verdicts for offline analysis"). One JSON line per event, keyed by the backend's
/// `suggestion_id`, so `wade-eval verdicts` can join it with the backend's check log.
///
/// No text by construction: no suggestion text, no correction text, no screen content. Only
/// the event, the mode and kind, timings, the provider, and the names of proposed tools.
/// (The correction text itself lives in the corrections store, where the user can see it.)
public struct Verdict: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable {
        case composed        // the execution stage finished (see `outcome`)
        case shownAuto = "shown_auto"      // the popover opened by itself
        case opened          // the user opened the popover on it
        case closedUnseen = "closed_unseen"  // auto-opened, then closed with no interaction
        case accepted        // "Thanks"
        case rejected        // "Not helpful"
        case corrected       // "Correct…" saved
        case actionDone = "action_done"      // "Do it" succeeded
        case actionFailed = "action_failed"  // "Do it" failed
    }

    public var ts: Double
    public var suggestionId: String
    public var event: Event
    public var sample: Bool
    public var mode: String?
    public var kind: String?
    public var outcome: String?       // composed: done | dropped | failed
    public var provider: String?
    public var firstTokenS: Double?
    public var totalS: Double?
    public var tools: [String]?       // proposed tool names (composed, action_*)

    public init(ts: Double = Date().timeIntervalSince1970, suggestionId: String, event: Event,
                mode: String? = nil, kind: String? = nil, outcome: String? = nil, provider: String? = nil,
                firstTokenS: Double? = nil, totalS: Double? = nil, tools: [String]? = nil) {
        self.ts = ts
        self.suggestionId = suggestionId
        self.event = event
        self.sample = suggestionId.hasPrefix("sample")
        self.mode = mode
        self.kind = kind
        self.outcome = outcome
        self.provider = provider
        self.firstTokenS = firstTokenS
        self.totalS = totalS
        self.tools = tools
    }

    enum CodingKeys: String, CodingKey {
        case ts, event, sample, mode, kind, outcome, provider, tools
        case suggestionId = "suggestion_id"
        case firstTokenS = "first_token_s"
        case totalS = "total_s"
    }
}

public final class VerdictLog: @unchecked Sendable {
    public static let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Wade/eval/verdicts.jsonl")

    public let url: URL
    private let queue = DispatchQueue(label: "wade.verdict-log")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public init(url: URL = VerdictLog.defaultURL) {
        self.url = url
    }

    public func append(_ verdict: Verdict) {
        guard let data = try? encoder.encode(verdict) else { return }
        queue.async { [url] in
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        }
    }

    /// Waits for pending writes (tests).
    public func flush() {
        queue.sync {}
    }
}
