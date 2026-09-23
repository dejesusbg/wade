import CryptoKit
import Foundation

// Pure, clock-injected detectors that turn raw input signals into `tkg_event`s.
// They only ever see timestamps and counts, never key contents.

/// Groups key-downs into typing runs. A run ends after `gap` seconds without a key;
/// runs shorter than `minKeys` are noise and are not reported.
public struct TypingBurstDetector: Sendable {
    public struct Burst: Sendable, Equatable {
        public let start: Double
        public let end: Double
        public let keyCount: Int
        public var duration: Double { end - start }
    }

    public let gap: Double
    public let minKeys: Int
    private var start: Double?
    private var last: Double = 0
    private var count = 0

    public init(gap: Double = 2.0, minKeys: Int = 5) {
        self.gap = gap
        self.minKeys = minKeys
    }

    /// Returns the previous burst if this key starts a new run.
    public mutating func keyDown(at t: Double) -> Burst? {
        let finished = flush(now: t)
        if start == nil { start = t }
        last = t
        count += 1
        return finished
    }

    /// Call periodically; closes the current run once it has gone quiet.
    public mutating func flush(now: Double) -> Burst? {
        guard start != nil, now - last >= gap else { return nil }
        return close()
    }

    /// Closes the current run immediately (e.g. on focus change: a burst belongs to one app).
    public mutating func close() -> Burst? {
        defer { start = nil; count = 0 }
        guard let start, count >= minKeys else { return nil }
        return Burst(start: start, end: last, keyCount: count)
    }
}

/// Edge-detects idle periods from "seconds since last input" samples.
public struct IdleDetector: Sendable {
    public enum Transition: Sendable, Equatable {
        case started(at: Double)
        case ended(at: Double, idleSeconds: Double)
    }

    public let threshold: Double
    private var idleSince: Double?

    public init(threshold: Double = 30) {
        self.threshold = threshold
    }

    public var isIdle: Bool { idleSince != nil }

    public mutating func sample(secondsSinceInput: Double, now: Double) -> Transition? {
        let lastInput = now - secondsSinceInput
        if let since = idleSince {
            guard secondsSinceInput < threshold else { return nil }
            idleSince = nil
            return .ended(at: lastInput, idleSeconds: lastInput - since)
        }
        guard secondsSinceInput >= threshold else { return nil }
        idleSince = lastInput
        return .started(at: lastInput)
    }
}

/// Recognizes error-looking dialog text and reduces it to a stable signature, so the TKG can
/// link recurrences of "the same" error (REPEATS edges) without shipping the raw text around.
public enum ErrorSignature {
    // English + Spanish; matched against lowercased dialog text.
    static let keywords = [
        "error", "failed", "failure", "couldn't", "could not", "can't", "cannot", "unable",
        "denied", "invalid", "not found", "went wrong", "unexpected", "problem",
        "falló", "fallo", "no se pudo", "no se puede", "denegado", "inválido", "no encontrado", "problema",
    ]

    public static func looksLikeError(_ texts: [String]) -> Bool {
        let joined = texts.joined(separator: " ").lowercased()
        return keywords.contains { joined.contains($0) }
    }

    /// Digits are masked so "line 42" and "line 57" of the same failure share a signature.
    public static func make(from texts: [String]) -> String {
        let normalized = texts
            .map { $0.lowercased()
                .replacing(/\d+/, with: "#")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
