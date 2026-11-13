import Foundation
import SwiftUI

struct BookHits: Identifiable {
    let bookID: UUID
    let hits: [SearchHit]

    var id: UUID { bookID }
}

/// Runs a query against the index and groups the results by book.
@MainActor
@Observable
final class SearchModel {
    private(set) var groups: [BookHits] = []
    private(set) var totalHits = 0
    private(set) var highlightTerms: [String] = []
    private(set) var lastQuery = ""
    private(set) var hitLimitReached = false

    static let limit = 500

    func run(query: String, matchAll: Bool, bookIDs: Set<UUID>?, store: LibraryStore) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let built = QueryBuilder.build(trimmed, matchAll: matchAll) else {
            clear()
            lastQuery = trimmed
            return
        }

        let hits = await store.index.search(built.expression, bookIDs: bookIDs, limit: SearchModel.limit)
        guard !Task.isCancelled else { return }

        var order: [UUID] = []
        var buckets: [UUID: [SearchHit]] = [:]
        for hit in hits {
            if buckets[hit.bookID] == nil { order.append(hit.bookID) }
            buckets[hit.bookID, default: []].append(hit)
        }
        groups = order.compactMap { id in
            guard store.book(id: id) != nil, let list = buckets[id] else { return nil }
            return BookHits(bookID: id, hits: list)
        }
        totalHits = groups.reduce(0) { $0 + $1.hits.count }
        hitLimitReached = hits.count >= SearchModel.limit
        highlightTerms = built.highlightTerms
        lastQuery = trimmed
    }

    func clear() {
        groups = []
        totalHits = 0
        highlightTerms = []
        lastQuery = ""
        hitLimitReached = false
    }

    func isCurrent(for query: String) -> Bool {
        lastQuery == query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
