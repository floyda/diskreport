import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error, CustomStringConvertible {
    case open(String)
    case exec(sql: String, message: String)
    case prepare(sql: String, message: String)
    case step(sql: String, message: String)

    public var description: String {
        switch self {
        case .open(let m): return "sqlite open failed: \(m)"
        case .exec(let sql, let m): return "sqlite exec failed (\(m)): \(sql)"
        case .prepare(let sql, let m): return "sqlite prepare failed (\(m)): \(sql)"
        case .step(let sql, let m): return "sqlite step failed (\(m)): \(sql)"
        }
    }
}

/// Minimal sqlite3 wrapper. Not thread-safe; one Database per thread/actor.
final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw DatabaseError.open(message)
        }
        handle = db
    }

    deinit { sqlite3_close(handle) }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }
    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.exec(sql: sql, message: errorMessage)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepare(sql: sql, message: errorMessage)
        }
        return Statement(stmt: stmt, sql: sql, db: self)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

final class Statement {
    private let stmt: OpaquePointer
    private let sql: String
    private unowned let db: Database

    init(stmt: OpaquePointer, sql: String, db: Database) {
        self.stmt = stmt
        self.sql = sql
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    @discardableResult
    func bind(_ index: Int32, _ value: Int64?) -> Statement {
        if let value { sqlite3_bind_int64(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: String?) -> Statement {
        if let value { sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, index) }
        return self
    }

    /// Advances one row. Returns true when a row is available, false when done.
    func step() throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw DatabaseError.step(sql: sql, message: db.errorMessage)
        }
    }

    /// Runs a statement that returns no rows.
    func run() throws {
        while try step() {}
    }

    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(stmt, column) }
    func optionalInt64(_ column: Int32) -> Int64? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : int64(column)
    }
    func text(_ column: Int32) -> String { String(cString: sqlite3_column_text(stmt, column)) }
    func optionalText(_ column: Int32) -> String? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : text(column)
    }
}
