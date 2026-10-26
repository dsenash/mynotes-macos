import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DBValue {
    case text(String)
    case blob(Data)
    case int(Int64)
    case real(Double)
    case null

    static func uuid(_ id: UUID?) -> DBValue {
        if let id { return .text(id.uuidString) }
        return .null
    }
}

struct DBError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Row {
    let stmt: OpaquePointer

    func text(_ i: Int32) -> String? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func real(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }

    func blob(_ i: Int32) -> Data? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: n)
    }
}

/// Тонкая обёртка над системным SQLite. Используется только из главного потока.
final class Database {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw DBError(message: lastError()) }
        try script("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        try script("""
        CREATE TABLE IF NOT EXISTS projects (
            id        TEXT PRIMARY KEY,
            parent_id TEXT REFERENCES projects(id) ON DELETE CASCADE,
            name      TEXT NOT NULL,
            sort      INTEGER NOT NULL DEFAULT 0,
            created   REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS notes (
            id         TEXT PRIMARY KEY,
            project_id TEXT REFERENCES projects(id) ON DELETE CASCADE,
            title      TEXT NOT NULL DEFAULT '',
            body       BLOB,
            plain      TEXT NOT NULL DEFAULT '',
            created    REAL NOT NULL,
            updated    REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_notes_project ON notes(project_id);
        CREATE INDEX IF NOT EXISTS idx_projects_parent ON projects(parent_id);
        """)

        // Миграция: цвет названия проекта (добавлен в версии 1.1).
        let columns = try rows("PRAGMA table_info(projects)") { (r: Row) -> String in r.text(1) ?? "" }
        if !columns.contains("color") {
            try script("ALTER TABLE projects ADD COLUMN color TEXT;")
        }
        // Миграция 1.2: начертание названия и время изменения проекта (нужно для синхронизации).
        if !columns.contains("font_style") {
            try script("ALTER TABLE projects ADD COLUMN font_style INTEGER NOT NULL DEFAULT 0;")
        }
        if !columns.contains("updated") {
            try script("ALTER TABLE projects ADD COLUMN updated REAL;")
        }
        try script("UPDATE projects SET updated = created WHERE updated IS NULL;")
        // Миграция 1.10: метка «Устаревшая» у заметок.
        let noteColumns = try rows("PRAGMA table_info(notes)") { (r: Row) -> String in r.text(1) ?? "" }
        if !noteColumns.contains("expired") {
            try script("ALTER TABLE notes ADD COLUMN expired INTEGER NOT NULL DEFAULT 0;")
        }
    }

    deinit { sqlite3_close(handle) }

    private func lastError() -> String {
        guard let handle else { return "База данных не открыта" }
        return String(cString: sqlite3_errmsg(handle))
    }

    /// Выполняет несколько SQL-команд подряд (без параметров).
    func script(_ sql: String) throws {
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK { throw DBError(message: lastError()) }
    }

    func execute(_ sql: String, _ params: [DBValue] = []) throws {
        try rows(sql, params) { (_: Row) -> Int in 0 }
    }

    @discardableResult
    func rows<T>(_ sql: String, _ params: [DBValue] = [], _ map: (Row) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DBError(message: lastError())
        }
        defer { sqlite3_finalize(stmt) }

        for (offset, value) in params.enumerated() {
            let idx = Int32(offset + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .blob(let d):
                if d.isEmpty {
                    sqlite3_bind_zeroblob(stmt, idx, 0)
                } else {
                    d.withUnsafeBytes { raw in
                        _ = sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(d.count), SQLITE_TRANSIENT)
                    }
                }
            case .int(let i): sqlite3_bind_int64(stmt, idx, i)
            case .real(let r): sqlite3_bind_double(stmt, idx, r)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }

        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out.append(map(Row(stmt: stmt)))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DBError(message: lastError())
            }
        }
        return out
    }

    func transaction(_ body: () throws -> Void) throws {
        try script("BEGIN")
        do {
            try body()
            try script("COMMIT")
        } catch {
            try? script("ROLLBACK")
            throw error
        }
    }
}
