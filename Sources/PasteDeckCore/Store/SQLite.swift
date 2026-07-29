import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` tells SQLite to copy the bound bytes; the C macro isn't
/// importable so it has to be re-created here.
private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var description: String {
        var text = "SQLite error \(code): \(message)"
        if let sql { text += "\n  in: \(sql)" }
        return text
    }
}

/// A value that can be bound to a statement parameter or read from a column.
public enum SQLValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(_ value: Int64) { self = .integer(value) }
    public init(_ value: Int) { self = .integer(Int64(value)) }
    public init(_ value: Bool) { self = .integer(value ? 1 : 0) }
    public init(_ value: Double) { self = .real(value) }
    public init(_ value: Date) { self = .real(value.timeIntervalSince1970) }
    public init(_ value: String) { self = .text(value) }
    public init(_ value: Data) { self = .blob(value) }
    public init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    public init(_ value: Int64?) { self = value.map { .integer($0) } ?? .null }
    public init(_ value: Data?) { self = value.map { .blob($0) } ?? .null }
    public init(_ value: Date?) { self = value.map { .real($0.timeIntervalSince1970) } ?? .null }
}

// MARK: - Row

/// One result row, materialised so it stays valid after the statement steps on.
public struct Row {
    private let columns: [String: Int]
    private let values: [SQLValue]

    init(columns: [String: Int], values: [SQLValue]) {
        self.columns = columns
        self.values = values
    }

    public func value(_ name: String) -> SQLValue {
        guard let index = columns[name], index < values.count else { return .null }
        return values[index]
    }

    public func int(_ name: String) -> Int64? {
        switch value(name) {
        case .integer(let v): return v
        case .real(let v): return Int64(v)
        case .text(let v): return Int64(v)
        default: return nil
        }
    }

    public func double(_ name: String) -> Double? {
        switch value(name) {
        case .real(let v): return v
        case .integer(let v): return Double(v)
        case .text(let v): return Double(v)
        default: return nil
        }
    }

    public func string(_ name: String) -> String? {
        switch value(name) {
        case .text(let v): return v
        case .integer(let v): return String(v)
        case .real(let v): return String(v)
        default: return nil
        }
    }

    public func data(_ name: String) -> Data? {
        if case .blob(let v) = value(name) { return v }
        return nil
    }

    public func bool(_ name: String) -> Bool { (int(name) ?? 0) != 0 }
    public func date(_ name: String) -> Date? { double(name).map(Date.init(timeIntervalSince1970:)) }
}

// MARK: - Connection

/// A single sqlite3 connection. Not thread-safe on its own — always reach it
/// through ``Database``, which serialises access.
public final class SQLiteConnection {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close_v2(db)
            throw SQLiteError(code: result, message: message, sql: path)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    private func lastError(_ code: Int32, sql: String?) -> SQLiteError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
        return SQLiteError(code: code, message: message, sql: sql)
    }

    /// Runs one or more statements, ignoring any rows they produce.
    public func execute(_ sql: String) throws {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "closed", sql: sql) }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw SQLiteError(code: result, message: message, sql: sql)
        }
    }

    /// Runs a statement that returns no rows, and reports how many rows changed.
    @discardableResult
    public func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw lastError(result, sql: sql) }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [Row] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        var columns: [String: Int] = [:]
        columns.reserveCapacity(columnCount)
        for index in 0..<columnCount {
            if let name = sqlite3_column_name(statement, Int32(index)) {
                columns[String(cString: name)] = index
            }
        }

        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw lastError(step, sql: sql) }

            var values: [SQLValue] = []
            values.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                values.append(columnValue(statement, Int32(index)))
            }
            rows.append(Row(columns: columns, values: values))
        }
        return rows
    }

    /// First column of the first row, or nil.
    public func scalar(_ sql: String, _ parameters: [SQLValue] = []) throws -> SQLValue? {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw lastError(step, sql: sql) }
        return columnValue(statement, 0)
    }

    public var lastInsertRowID: Int64 {
        handle.map { sqlite3_last_insert_rowid($0) } ?? 0
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Internals

    private func prepare(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer? {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "closed", sql: sql) }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw lastError(result, sql: sql)
        }

        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == parameters.count else {
            sqlite3_finalize(statement)
            throw SQLiteError(
                code: SQLITE_MISUSE,
                message: "expected \(expected) parameters, got \(parameters.count)",
                sql: sql
            )
        }

        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let bindResult: Int32
            switch parameter {
            case .null:
                bindResult = sqlite3_bind_null(statement, index)
            case .integer(let value):
                bindResult = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                bindResult = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                bindResult = sqlite3_bind_text(statement, index, value, -1, transientDestructor)
            case .blob(let value):
                bindResult = value.isEmpty
                    ? sqlite3_bind_zeroblob(statement, index, 0)
                    : value.withUnsafeBytes {
                        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transientDestructor)
                    }
            }
            guard bindResult == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw lastError(bindResult, sql: sql)
            }
        }
        return statement
    }

    private func columnValue(_ statement: OpaquePointer?, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }
}

// MARK: - Database

/// Serialises all access to a connection on a private queue, so the rest of the
/// app can call in from any thread without thinking about it.
public final class Database: @unchecked Sendable {
    private let connection: SQLiteConnection
    private let queue: DispatchQueue

    public let path: String

    public init(path: String, label: String = "app.pastedeck.db") throws {
        self.path = path
        self.queue = DispatchQueue(label: label)
        self.connection = try SQLiteConnection(path: path)
        try queue.sync {
            try connection.execute("PRAGMA journal_mode = WAL")
            try connection.execute("PRAGMA synchronous = NORMAL")
            try connection.execute("PRAGMA foreign_keys = ON")
            try connection.execute("PRAGMA temp_store = MEMORY")
        }
    }

    /// In-memory database, for tests.
    public static func inMemory() throws -> Database {
        try Database(path: ":memory:", label: "app.pastedeck.db.memory")
    }

    @discardableResult
    public func read<T>(_ body: (SQLiteConnection) throws -> T) rethrows -> T {
        try queue.sync { try body(connection) }
    }

    @discardableResult
    public func write<T>(_ body: (SQLiteConnection) throws -> T) rethrows -> T {
        try queue.sync { try body(connection) }
    }

    /// Wraps `body` in an IMMEDIATE transaction on the serial queue.
    @discardableResult
    public func transaction<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        try queue.sync { try connection.transaction { try body(connection) } }
    }

    public func checkpoint() {
        queue.async { [connection] in
            try? connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    public func vacuum() {
        queue.async { [connection] in
            try? connection.execute("VACUUM")
        }
    }
}
