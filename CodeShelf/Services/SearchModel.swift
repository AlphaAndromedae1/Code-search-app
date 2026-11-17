import Foundation
import SwiftUI

struct BookHits: Identifiable {
    let bookID: UUID
    let hits: [SearchHit]

    var id: UUID { bookID }
}

/// Which kind of document a result came from. Code books always come first,
/// so a long manufacturer manual can never push the code you're looking for off the list.
enum SearchTier: Int, CaseIterable, Identifiable, Comparable {
    case codes
    case bulletins
    case manuals

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .codes: return "Code Books"
        case .bulletins: return "Bulletins & Updates"
        case .manuals: return "Manufacturer Instructions"
        }
    }

    var symbol: String {
        switch self {
        case .codes: return "books.vertical"
        case .bulletins: return "megaphone"
        case .manuals: return "wrench.and.screwdriver"
        }
    }

    /// How many matching pages to collect for each kind.
    var limit: Int {
        switch self {
        case .codes: return 400
        case .bulletins: return 100
        case .manuals: return 150
        }
    }

    static func of(_ category: CodeCategory) -> SearchTier {
        switch category {
        case .manufacturer: return .manuals
        case .bulletin: return .bulletins
        default: return .codes
        }
    }

    static func < (lhs: SearchTier, rhs: SearchTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct TierHits: Identifiable {
    let tier: SearchTier
    let groups: [BookHits]
    let limitReached: Bool

    var id: SearchTier { tier }
    var pageCount: Int { groups.reduce(0) { $0 + $1.hits.count } }
}

/// Runs a query against the index: code books first, then bulletins, then manufacturer
/// instructions — each ranked by relevance and grouped by book.
@MainActor
@Observable
final class SearchModel {
    private(set) var tiers: [TierHits] = []
    private(set) var totalHits = 0
    private(set) var highlightTerms: [String] = []
    private(set) var lastQuery = ""

    var groups: [BookHits] { tiers.flatMap(\.groups) }
    var hitLimitReached: Bool { tiers.contains(where: \.limitReached) }

    func run(query: String, matchAll: Bool, bookIDs: Set<UUID>?, store: LibraryStore) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let built = QueryBuilder.build(trimmed, matchAll: matchAll) else {
            clear()
            lastQuery = trimmed
            return
        }

        var results: [TierHits] = []
        for tier in SearchTier.allCases {
            var ids = Set(store.books.filter { SearchTier.of($0.category) == tier }.map(\.id))
            if let bookIDs { ids.formIntersection(bookIDs) }
            guard !ids.isEmpty else { continue }

            let hits = await store.index.search(built.expression, bookIDs: ids, limit: tier.limit)
            guard !Task.isCancelled else { return }
            let groups = Self.group(hits, store: store)
            if !groups.isEmpty {
                results.append(TierHits(tier: tier, groups: groups, limitReached: hits.count >= tier.limit))
            }
        }

        tiers = results
        totalHits = results.reduce(0) { $0 + $1.pageCount }
        highlightTerms = built.highlightTerms
        lastQuery = trimmed
    }

    /// Groups hits by book; the book with the best-ranked page comes first.
    private static func group(_ hits: [SearchHit], store: LibraryStore) -> [BookHits] {
        var order: [UUID] = []
        var buckets: [UUID: [SearchHit]] = [:]
        for hit in hits {
            if buckets[hit.bookID] == nil { order.append(hit.bookID) }
            buckets[hit.bookID, default: []].append(hit)
        }
        return order.compactMap { id in
            guard store.book(id: id) != nil, let list = buckets[id] else { return nil }
            return BookHits(bookID: id, hits: list)
        }
    }

    func clear() {
        tiers = []
        totalHits = 0
        highlightTerms = []
        lastQuery = ""
    }

    func isCurrent(for query: String) -> Bool {
        lastQuery == query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
