import Foundation

// The two v1 memory stores (CLAUDE.md §5.7). Same SQLite file, deliberately separate tables,
// because they differ in provenance and revision dynamics:
//
//  1. Onboarding facts — user-stated, high confidence, user-editable. Includes the
//     integrations the user opted into.
//  2. Correction facts — accumulate from denied/corrected suggestions (Phase 6), each
//     tagged with what it corrected.
//
// Explicit feedback only: nothing in here is ever inferred from passive behavior.

public struct OnboardingFact: Identifiable, Sendable, Equatable {
    public let id: Int64
    public var text: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: Int64, text: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CorrectionFact: Identifiable, Sendable, Equatable {
    public let id: Int64
    /// The `trigger_fired.suggestion_id` this corrected.
    public let suggestionId: String
    /// What Wade suggested, e.g. "clone the repo".
    public let suggestion: String
    /// What the user said instead, e.g. "just the release binary next time".
    public let correction: String
    /// Always "user_correction" in v1; kept so later versions can weight sources differently.
    public let provenance: String
    public let createdAt: Date

    public init(id: Int64, suggestionId: String, suggestion: String, correction: String,
                provenance: String, createdAt: Date) {
        self.id = id
        self.suggestionId = suggestionId
        self.suggestion = suggestion
        self.correction = correction
        self.provenance = provenance
        self.createdAt = createdAt
    }
}

public final class MemoryStore {
    private let db: SQLiteDatabase

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Wade/memory.sqlite")
    }

    /// `url == nil` gives a throwaway in-memory store.
    public init(url: URL?) throws {
        db = try SQLiteDatabase(path: url)
        try migrate()
    }

    private func migrate() throws {
        let version = try db.query("PRAGMA user_version").first?["user_version"]?.int ?? 0
        if version < 1 {
            try db.execute("""
                CREATE TABLE onboarding_facts (
                    id INTEGER PRIMARY KEY,
                    text TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute("""
                CREATE TABLE integration_opt_ins (
                    integration_id TEXT PRIMARY KEY,
                    enabled INTEGER NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute("""
                CREATE TABLE correction_facts (
                    id INTEGER PRIMARY KEY,
                    suggestion_id TEXT NOT NULL,
                    suggestion TEXT NOT NULL,
                    correction TEXT NOT NULL,
                    provenance TEXT NOT NULL DEFAULT 'user_correction',
                    created_at REAL NOT NULL
                )
                """)
            try db.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute("PRAGMA user_version = 1")
        }
    }

    // MARK: Onboarding facts

    public func onboardingFacts() throws -> [OnboardingFact] {
        try db.query("SELECT * FROM onboarding_facts ORDER BY id").map { row in
            OnboardingFact(
                id: row["id"]?.int ?? 0,
                text: row["text"]?.string ?? "",
                createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]?.double ?? 0)
            )
        }
    }

    @discardableResult
    public func addOnboardingFact(_ text: String, now: Date = .now) throws -> OnboardingFact {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ts = now.timeIntervalSince1970
        try db.execute(
            "INSERT INTO onboarding_facts (text, created_at, updated_at) VALUES (?, ?, ?)",
            [.text(text), .real(ts), .real(ts)])
        let stored = Date(timeIntervalSince1970: ts)  // what a later read returns, to the bit
        return OnboardingFact(id: db.lastInsertRowID, text: text, createdAt: stored, updatedAt: stored)
    }

    public func updateOnboardingFact(id: Int64, text: String, now: Date = .now) throws {
        try db.execute(
            "UPDATE onboarding_facts SET text = ?, updated_at = ? WHERE id = ?",
            [.text(text.trimmingCharacters(in: .whitespacesAndNewlines)), .real(now.timeIntervalSince1970), .int(id)])
    }

    public func deleteOnboardingFact(id: Int64) throws {
        try db.execute("DELETE FROM onboarding_facts WHERE id = ?", [.int(id)])
    }

    // MARK: Integration opt-ins (part of the onboarding store)

    public func enabledIntegrations() throws -> Set<String> {
        Set(try db.query("SELECT integration_id FROM integration_opt_ins WHERE enabled = 1")
            .compactMap { $0["integration_id"]?.string })
    }

    public func setIntegration(_ id: String, enabled: Bool, now: Date = .now) throws {
        try db.execute("""
            INSERT INTO integration_opt_ins (integration_id, enabled, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(integration_id) DO UPDATE SET enabled = excluded.enabled, updated_at = excluded.updated_at
            """, [.text(id), .int(enabled ? 1 : 0), .real(now.timeIntervalSince1970)])
    }

    // MARK: Correction facts (written from Phase 6's accept/reject/correct UI)

    public func correctionFacts() throws -> [CorrectionFact] {
        try db.query("SELECT * FROM correction_facts ORDER BY id").map { row in
            CorrectionFact(
                id: row["id"]?.int ?? 0,
                suggestionId: row["suggestion_id"]?.string ?? "",
                suggestion: row["suggestion"]?.string ?? "",
                correction: row["correction"]?.string ?? "",
                provenance: row["provenance"]?.string ?? "",
                createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0)
            )
        }
    }

    @discardableResult
    public func addCorrection(suggestionId: String, suggestion: String, correction: String, now: Date = .now) throws -> CorrectionFact {
        let ts = now.timeIntervalSince1970
        try db.execute(
            "INSERT INTO correction_facts (suggestion_id, suggestion, correction, created_at) VALUES (?, ?, ?, ?)",
            [.text(suggestionId), .text(suggestion), .text(correction), .real(ts)])
        return CorrectionFact(
            id: db.lastInsertRowID, suggestionId: suggestionId, suggestion: suggestion,
            correction: correction, provenance: "user_correction", createdAt: Date(timeIntervalSince1970: ts))
    }

    public func deleteCorrection(id: Int64) throws {
        try db.execute("DELETE FROM correction_facts WHERE id = ?", [.int(id)])
    }

    // MARK: App settings

    public var onboardingCompleted: Bool {
        get { (try? db.query("SELECT value FROM settings WHERE key = 'onboarding_completed'").first?["value"]?.string) == "1" }
        set {
            try? db.execute(
                "INSERT INTO settings (key, value) VALUES ('onboarding_completed', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(newValue ? "1" : "0")])
        }
    }
}
