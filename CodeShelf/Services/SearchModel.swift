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
    /// Explains results that didn't come from an exact index match.
    var note: String? = nil

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
    /// Reading the code book PDFs directly because the index had no match.
    private(set) var isScanningPDFs = false
    /// Searched code books but nothing turned up in any of them (even reading the PDFs directly).
    private(set) var missedCodeBooks = false

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
        var codeIDs: Set<UUID> = []
        for tier in SearchTier.allCases {
            var ids = Set(store.books.filter { SearchTier.of($0.category) == tier }.map(\.id))
            if let bookIDs { ids.formIntersection(bookIDs) }
            if tier == .codes { codeIDs = ids }
            guard !ids.isEmpty else { continue }

            let hits = await store.index.search(built.expression, bookIDs: ids, limit: tier.limit)
            guard !Task.isCancelled else { return }
            let groups = Self.group(hits, store: store)
            if !groups.isEmpty {
                results.append(TierHits(tier: tier, groups: groups, limitReached: hits.count >= tier.limit))
            }
        }

        // Nothing in the code books: try a looser clause-number match, then read the PDFs themselves.
        // Bulletins are included too, in case a code book was filed as one.
        var scanned = false
        let fallbackIDs = Set(store.books.filter { SearchTier.of($0.category) != .manuals }.map(\.id))
            .intersection(bookIDs ?? Set(store.books.map(\.id)))
        if !fallbackIDs.isEmpty && !results.contains(where: { $0.tier == .codes }) {
            let number = built.sectionNumbers.first ?? trimmed
            if let lenient = built.lenientExpression {
                let hits = await store.index.search(lenient, bookIDs: fallbackIDs, limit: SearchTier.codes.limit)
                guard !Task.isCancelled else { return }
                Self.merge(
                    hits, into: &results, store: store,
                    note: "No exact match for \(number). These pages have \(number) run into the next word or number (e.g. \(number)1 or \(number)Appliances)."
                )
            }
            if !results.contains(where: { $0.tier == .codes }), let phrase = Self.scanPhrase(trimmed, query: built) {
                // Show what's found so far while the PDFs are read.
                publish(results, built: built, query: trimmed)
                isScanningPDFs = true
                var found: [SearchHit] = []
                let targets = store.books
                    .filter { fallbackIDs.contains($0.id) }
                    .sorted { SearchTier.of($0.category) < SearchTier.of($1.category) }
                    .map { PDFTextScan.Target(bookID: $0.id, url: store.fileURL(for: $0)) }
                for target in targets {
                    found += await PDFTextScan.find(phrase, in: target)
                    if Task.isCancelled { break }
                }
                isScanningPDFs = false
                guard !Task.isCancelled else { return }
                scanned = true
                Self.merge(
                    found, into: &results, store: store,
                    note: "Found by reading the PDF directly. The search index didn't have it: the book may still be indexing, or the PDF prints “\(phrase)” joined to the word before it."
                )
            }
        }

        publish(results, built: built, query: trimmed)
        missedCodeBooks = !codeIDs.isEmpty && !results.contains(where: { $0.tier == .codes }) && (scanned || built.lenientExpression == nil)
    }

    private func publish(_ results: [TierHits], built: SearchQuery, query: String) {
        tiers = results
        totalHits = results.reduce(0) { $0 + $1.pageCount }
        highlightTerms = built.highlightTerms
        lastQuery = query
        missedCodeBooks = false
    }

    /// What to look for when reading PDFs directly: the clause or rule number typed (e.g. "4.7.4").
    /// Only numbers are scanned for, so ordinary word searches stay instant.
    private static func scanPhrase(_ text: String, query: SearchQuery) -> String? {
        guard let number = query.sectionNumbers.first, number.count >= 3 else { return nil }
        return number
    }

    /// Adds fallback hits to the results, each under its book's tier, with a note saying how they were found.
    private static func merge(_ hits: [SearchHit], into results: inout [TierHits], store: LibraryStore, note: String) {
        guard !hits.isEmpty else { return }
        for tier in SearchTier.allCases {
            let tierHits = hits.filter { hit in store.book(id: hit.bookID).map { SearchTier.of($0.category) == tier } ?? false }
            let groups = group(tierHits, store: store)
            guard !groups.isEmpty else { continue }
            let existing = results.firstIndex { $0.tier == tier }
            let known = Set(existing.map { results[$0].groups.map(\.bookID) } ?? [])
            let added = groups.filter { !known.contains($0.bookID) }
            guard !added.isEmpty else { continue }
            if let existing {
                let current = results[existing]
                results[existing] = TierHits(tier: tier, groups: current.groups + added, limitReached: current.limitReached, note: current.note ?? note)
            } else {
                results.append(TierHits(tier: tier, groups: added, limitReached: false, note: note))
            }
        }
        results.sort { $0.tier < $1.tier }
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
        isScanningPDFs = false
        missedCodeBooks = false
    }

    func isCurrent(for query: String) -> Bool {
        lastQuery == query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
