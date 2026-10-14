import Foundation
import SQLite3

/// A bounded-lifetime read-only transaction: schema, metadata, and rows see the same WAL snapshot.
final class BrowserSQLite {
    private var db: OpaquePointer?

    init(_ source: URL) throws {
        let result = sqlite3_open_v2(source.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; self.db = nil
            throw BrowserImportError.unreadable("Could not read the browser database. Check permissions, close Chrome, and retry.")
        }
        sqlite3_busy_timeout(db, 2000)
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db); self.db = nil
            throw BrowserImportError.unreadable("Could not start a read-only browser snapshot. Close the source browser and retry.")
        }
    }

    deinit { if let db { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) } }

    func query(_ sql: String) throws -> [[String: Any]] {
        guard let db else { throw BrowserImportError.unreadable("Browser database is closed.") }
        var statement: OpaquePointer?
        defer { if let statement { sqlite3_finalize(statement) } }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement,
              sqlite3_stmt_readonly(statement) != 0 else {
            // Do not include SQL, paths, or SQLite diagnostics that might contain cookie values.
            throw BrowserImportError.unreadable("Unsupported browser database schema. Update Facet or choose another profile.")
        }
        var rows: [[String: Any]] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = NSNumber(value: sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = NSNumber(value: sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, column) {
                        let count = Int(sqlite3_column_bytes(statement, column))
                        row[name] = String(data: Data(bytes: text, count: count), encoding: .utf8)
                    }
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column) { row[name] = Data(bytes: bytes, count: count) }
                    else { row[name] = Data() }
                default: break
                }
            }
            rows.append(row)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else {
            throw BrowserImportError.unreadable("Could not finish reading the browser database. Close the source browser and retry.")
        }
        return rows
    }
}
