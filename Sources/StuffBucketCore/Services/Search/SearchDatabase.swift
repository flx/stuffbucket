import Foundation
import SQLite3

final class SearchDatabase {
    static let shared = SearchDatabase()

    private let queue = DispatchQueue(label: "StuffBucket.SearchDatabase")
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let schemaVersion: Int32 = 2
    private var db: OpaquePointer?

    private init() {
        queue.sync {
            openDatabase()
            createSchema()
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func upsert(document: SearchDocument) {
        queue.async {
            guard let db = self.db else { return }
            let deleteSQL = "DELETE FROM items_fts WHERE id = ?;"
            var deleteStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(deleteStmt, 1, document.id.uuidString, -1, self.sqliteTransient)
                sqlite3_step(deleteStmt)
            }
            sqlite3_finalize(deleteStmt)

            let insertSQL = """
            INSERT INTO items_fts (id, title, tags, collection, content, annotations, ai_summary, type, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var insertStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK {
                let content = document.isProtected ? "" : document.content
                let aiSummary = document.isProtected ? "" : (document.aiSummary ?? "")
                let typeValue = document.type?.rawValue ?? ""
                let sourceValue = document.source?.rawValue ?? ""

                sqlite3_bind_text(insertStmt, 1, document.id.uuidString, -1, self.sqliteTransient)
                sqlite3_bind_text(insertStmt, 2, document.title, -1, self.sqliteTransient)
                sqlite3_bind_text(insertStmt, 3, document.tags.joined(separator: " "), -1, self.sqliteTransient)
                sqlite3_bind_text(insertStmt, 4, document.collection ?? "", -1, self.sqliteTransient)
                sqlite3_bind_text(insertStmt, 5, content, -1, self.sqliteTransient)
                sqlite3_bind_text(insertStmt, 6, "", -1, self.sqliteTransient)
                sqlite3_bind_text(insertStmt, 7, aiSummary, -1, self.sqliteTransient)
                sqlite3_bind_text(insertStmt, 8, typeValue, -1, self.sqliteTransient)
                sqlite3_bind_text(insertStmt, 9, sourceValue, -1, self.sqliteTransient)
                sqlite3_step(insertStmt)
            }
            sqlite3_finalize(insertStmt)
        }
    }

    func delete(itemID: UUID) {
        queue.async {
            guard let db = self.db else { return }
            let sql = "DELETE FROM items_fts WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, itemID.uuidString, -1, self.sqliteTransient)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func search(query: SearchQuery) -> [SearchResult] {
        let matchQuery = SearchQueryBuilder().build(query: query)
        guard !matchQuery.isEmpty else {
            return []
        }

        var results: [SearchResult] = []
        queue.sync {
            guard let db = self.db else { return }
            let sql = """
            SELECT id, title, snippet(items_fts, -1, '[', ']', '…', 12) AS snippet
            FROM items_fts
            WHERE items_fts MATCH ?
            ORDER BY bm25(items_fts, 0.0, 10.0, 6.0, 3.0, 1.0, 0.5, 0.5, 0.1, 0.1)
            LIMIT 100;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, matchQuery, -1, self.sqliteTransient)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let idText = sqlite3_column_text(stmt, 0) else { continue }
                    let idString = String(cString: idText)
                    guard let id = UUID(uuidString: idString) else { continue }
                    let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let snippet = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                    results.append(SearchResult(itemID: id, title: title, snippet: snippet))
                }
            }
            sqlite3_finalize(stmt)
        }
        return results
    }

    private func openDatabase() {
        let url = databaseURL()
        var db: OpaquePointer?
        if sqlite3_open(url.path, &db) == SQLITE_OK {
            self.db = db
        } else {
            self.db = nil
            if let db {
                sqlite3_close(db)
            }
        }
    }

    private func createSchema() {
        guard let db = db else { return }
        var version: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = sqlite3_column_int(stmt, 0)
            }
        }
        sqlite3_finalize(stmt)

        if version != schemaVersion {
            sqlite3_exec(db, "DROP TABLE IF EXISTS items_fts;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA user_version = \(schemaVersion);", nil, nil, nil)
        }

        let sql = """
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts
        USING fts5(id UNINDEXED, title, tags, collection, content, annotations, ai_summary, type, source);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func databaseURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folderURL = baseURL.appendingPathComponent("StuffBucket", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folderURL.path) {
            try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
        return folderURL.appendingPathComponent("search.sqlite")
    }
}
