import CSQLite
import Foundation

public struct SQLiteError: Error, CustomStringConvertible {
    public var code: Int32
    public var message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal, explicit SQLite wrapper. Not thread-safe by itself: `HistoryStore` confines it
/// to a serial queue. Chosen over a third-party ORM to avoid a dependency for ~5 tables
/// (ADR 0002).
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(code: result, message: message)
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw SQLiteError(code: result, message: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw lastError(result) }
        return Statement(statement, database: self)
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get throws {
            let statement = try prepare("PRAGMA user_version")
            return try statement.step() ? Int(statement.int64(0)) : 0
        }
    }

    func setUserVersion(_ version: Int) throws { try execute("PRAGMA user_version = \(version)") }

    func lastError(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
}

final class Statement {
    private let statement: OpaquePointer
    private unowned let database: SQLiteDatabase

    init(_ statement: OpaquePointer, database: SQLiteDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit { sqlite3_finalize(statement) }

    @discardableResult
    func bind(_ values: Any?...) throws -> Statement {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case nil: result = sqlite3_bind_null(statement, index)
            case let value as Int: result = sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Int64: result = sqlite3_bind_int64(statement, index, value)
            case let value as Double: result = sqlite3_bind_double(statement, index, value)
            case let value as String: result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case let value as Data:
                result = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
                }
            default:
                throw SQLiteError(code: SQLITE_MISUSE, message: "Unsupported bind type \(type(of: value))")
            }
            guard result == SQLITE_OK else { throw database.lastError(result) }
        }
        return self
    }

    /// Returns true while rows are available.
    func step() throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw database.lastError(result)
        }
    }

    func run() throws { while try step() {} }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func string(_ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
    func data(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
