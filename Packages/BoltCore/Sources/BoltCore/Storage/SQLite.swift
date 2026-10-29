import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public var code: Int32
    public var message: String
    public var description: String { "SQLite \(code): \(message)" }
}

/// A value bound to a `?` placeholder.
enum SQLValue {
    case int(Int64), double(Double), text(String), null

    static func of(_ v: Int?) -> SQLValue { v.map { .int(Int64($0)) } ?? .null }
    static func of(_ v: Double?) -> SQLValue { v.map { .double($0) } ?? .null }
    static func of(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
}

/// One result row, read by column index.
struct SQLRow {
    fileprivate let stmt: OpaquePointer
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    func optInt(_ i: Int32) -> Int? { isNull(i) ? nil : int(i) }
    func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
}

/// Minimal wrapper over the system sqlite3 library. Not thread-safe: use it from one actor.
final class SQLiteConnection {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `path` nil opens a private in-memory database.
    init(path: String?) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path ?? ":memory:", &db, flags, nil)
        guard rc == SQLITE_OK else {
            let err = SQLiteError(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
            sqlite3_close(db); db = nil
            throw err
        }
        if path != nil { try exec("PRAGMA journal_mode = WAL") }
        try exec("PRAGMA foreign_keys = ON")
    }

    deinit { close() }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    func exec(_ sql: String) throws {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
    }

    /// Runs `sql` with `args`, calling `row` for each result row.
    func query(_ sql: String, _ args: [SQLValue] = [], row: (SQLRow) throws -> Void = { _ in }) throws {
        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .null: rc = sqlite3_bind_null(stmt, idx)
            }
            guard rc == SQLITE_OK else { throw error(rc) }
        }
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw error(rc) }
            try row(SQLRow(stmt: stmt))
        }
    }

    func run(_ sql: String, _ args: [SQLValue] = []) throws { try query(sql, args) }

    /// First column of the first row, as an integer.
    func scalar(_ sql: String, _ args: [SQLValue] = []) throws -> Int? {
        var v: Int?
        try query(sql, args) { r in if v == nil { v = r.optInt(0) } }
        return v
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }
}
