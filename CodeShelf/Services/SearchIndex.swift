import Foundation
import SQLite3

struct SearchHit: Identifiable, Hashable, Sendable {
    let bookID: UUID
    let pageIndex: Int
    /// Snippet text with matches wrapped in `SearchIndex.markStart` / `markEnd`.
    let snippet: String
    /// Lower is better (FTS5 bm25).
    let rank: Double

    var id: String { "\(bookID.uuidString)#\(pageIndex)" }
}

struct PageText: Sendable {
    let page: Int
    let text: String
}

enum SearchIndexError: Error, LocalizedError {
    case openFailed(String)
    case schemaFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "Could not open the search index: \(message)"
        case .schemaFailed(let message): return "Could not create the search index: \(message)"
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Full-text index of every page of every book, backed by SQLite FTS5.
actor SearchIndex {
    static let markStart = "\u{E000}"
    static let markEnd = "\u{E001}"

    private var db: OpaquePointer?
    private let usesFTS5: Bool

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw SearchIndexError.openFailed(message)
        }
        guard let connection = handle else {
            throw SearchIndexError.openFailed("no database handle")
        }

        SearchIndex.exec(connection, "PRAGMA journal_mode=WAL")
        SearchIndex.exec(connection, "PRAGMA synchronous=NORMAL")

        let fts5: Bool
        if let existing = SearchIndex.scalarText(connection, "SELECT sql FROM sqlite_master WHERE name = 'pages'") {
            fts5 = existing.lowercased().contains("fts5")
        } else if SearchIndex.exec(connection, "CREATE VIRTUAL TABLE pages USING fts5(body, book_id UNINDEXED, page UNINDEXED, tokenize = 'unicode61 remove_diacritics 2')") {
            fts5 = true
        } else if SearchIndex.exec(connection, "CREATE VIRTUAL TABLE pages USING fts4(body, book_id, page, notindexed=book_id, notindexed=page, tokenize=unicode61 \"remove_diacritics=2\")") {
            fts5 = false
        } else {
            let message = String(cString: sqlite3_errmsg(connection))
            sqlite3_close(connection)
            throw SearchIndexError.schemaFailed(message)
        }

        db = connection
        usesFTS5 = fts5
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Writing

    func insert(bookID: UUID, pages: [PageText]) {
        guard let db, !pages.isEmpty else { return }
        SearchIndex.exec(db, "BEGIN IMMEDIATE")
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO pages(body, book_id, page) VALUES (?, ?, ?)", -1, &stmt, nil) == SQLITE_OK {
            let id = bookID.uuidString
            for page in pages {
                let clean = page.text.replacingOccurrences(of: "\u{0}", with: " ")
                sqlite3_bind_text(stmt, 1, clean, -1, sqliteTransient)
                sqlite3_bind_text(stmt, 2, id, -1, sqliteTransient)
                sqlite3_bind_int64(stmt, 3, Int64(page.page))
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
            }
        }
        sqlite3_finalize(stmt)
        SearchIndex.exec(db, "COMMIT")
    }

    func deletePages(bookID: UUID, fromPage: Int) {
        run("DELETE FROM pages WHERE book_id = ? AND page >= ?", .text(bookID.uuidString), .int(fromPage))
    }

    func deleteBook(_ bookID: UUID) {
        run("DELETE FROM pages WHERE book_id = ?", .text(bookID.uuidString))
    }

    /// Merges internal b-trees so queries stay fast after a big import.
    func optimize() {
        run("INSERT INTO pages(pages) VALUES('optimize')")
    }

    // MARK: - Reading

    /// - Parameters:
    ///   - expression: An FTS MATCH expression built by `QueryBuilder`.
    ///   - bookIDs: Restrict to these books, or `nil` for all books.
    func search(_ expression: String, bookIDs: Set<UUID>?, limit: Int) -> [SearchHit] {
        guard let db else { return [] }
        if let bookIDs, bookIDs.isEmpty { return [] }

        let start = SearchIndex.markStart
        let end = SearchIndex.markEnd
        var sql: String
        if usesFTS5 {
            sql = "SELECT book_id, page, snippet(pages, 0, '\(start)', '\(end)', '…', 24), rank FROM pages WHERE pages MATCH ?"
        } else {
            sql = "SELECT book_id, page, snippet(pages, '\(start)', '\(end)', '…', 0, 24), 0 FROM pages WHERE pages MATCH ?"
        }
        if let bookIDs {
            // UUID strings are hex + dashes only, safe to inline.
            let list = bookIDs.map { "'\($0.uuidString)'" }.joined(separator: ",")
            sql += " AND book_id IN (\(list))"
        }
        sql += usesFTS5 ? " ORDER BY rank" : " ORDER BY book_id, page"
        sql += " LIMIT \(limit)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, expression, -1, sqliteTransient)

        var hits: [SearchHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idText)) else { continue }
            let page = Int(sqlite3_column_int64(stmt, 1))
            let snippet = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let rank = sqlite3_column_double(stmt, 3)
            hits.append(SearchHit(bookID: id, pageIndex: page, snippet: snippet, rank: rank))
        }
        return hits
    }

    /// The text stored for one page: exactly what a search can match on it.
    func pageText(bookID: UUID, page: Int) -> String? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT body FROM pages WHERE book_id = ? AND page = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, bookID.uuidString, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 2, Int64(page))
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    /// Pages of a book that hold enough text to be found by a search.
    func textPageCount(bookID: UUID) -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM pages WHERE book_id = ? AND length(body) > 40", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, bookID.uuidString, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func pageCountsByBook() -> [UUID: Int] {
        guard let db else { return [:] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT book_id, count(*) FROM pages GROUP BY book_id", -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var result: [UUID: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0), let id = UUID(uuidString: String(cString: text)) {
                result[id] = Int(sqlite3_column_int64(stmt, 1))
            }
        }
        return result
    }

    // MARK: - Helpers

    private enum Value {
        case text(String)
        case int(Int)
    }

    private func run(_ sql: String, _ values: Value...) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (offset, value) in values.enumerated() {
            let position = Int32(offset + 1)
            switch value {
            case .text(let string):
                sqlite3_bind_text(stmt, position, string, -1, sqliteTransient)
            case .int(let number):
                sqlite3_bind_int64(stmt, position, Int64(number))
            }
        }
        while sqlite3_step(stmt) == SQLITE_ROW {}
    }

    @discardableResult
    private static func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func scalarText(_ db: OpaquePointer, _ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }
}
