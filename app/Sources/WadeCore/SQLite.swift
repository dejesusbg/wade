import Foundation
import SQLite3

/// Minimal SQLite wrapper — just enough for the memory stores. Not thread-safe; callers confine it.
final class SQLiteDatabase {
    enum Value {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
    }

    struct Error: Swift.Error, CustomStringConvertible {
        let description: String
    }

    typealias Row = [String: Value]

    private var handle: OpaquePointer?

    /// `path == nil` opens a private in-memory database (tests).
    init(path: URL?) throws {
        let location = path?.path(percentEncoded: false) ?? ":memory:"
        if let dir = path?.deletingLastPathComponent() {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard sqlite3_open(location, &handle) == SQLITE_OK else {
            defer { sqlite3_close(handle) }
            throw Error(description: "open \(location): \(String(cString: sqlite3_errmsg(handle)))")
        }
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(handle) }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func execute(_ sql: String, _ bindings: [Value] = []) throws {
        _ = try query(sql, bindings)
    }

    @discardableResult
    func query(_ sql: String, _ bindings: [Value] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError(sql) }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }

        var rows: [Row] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                var row: Row = [:]
                for col in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, col))
                    row[name] = switch sqlite3_column_type(stmt, col) {
                    case SQLITE_INTEGER: .int(sqlite3_column_int64(stmt, col))
                    case SQLITE_FLOAT: .real(sqlite3_column_double(stmt, col))
                    case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(stmt, col)))
                    default: .null
                    }
                }
                rows.append(row)
            case SQLITE_DONE:
                return rows
            default:
                throw lastError(sql)
            }
        }
    }

    private func lastError(_ sql: String) -> Error {
        Error(description: "\(String(cString: sqlite3_errmsg(handle))) — in: \(sql)")
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension SQLiteDatabase.Value {
    var string: String? { if case .text(let s) = self { s } else { nil } }
    var int: Int64? { if case .int(let n) = self { n } else { nil } }
    var double: Double? {
        switch self {
        case .real(let d): d
        case .int(let n): Double(n)
        default: nil
        }
    }
}
