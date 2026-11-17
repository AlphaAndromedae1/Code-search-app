import Foundation
import PDFKit

/// Last-resort search that reads the PDFs themselves instead of the search index.
/// Finds text the index can't, such as a clause number printed against the word before it
/// ("Clause4.7.4"), or pages that haven't been indexed yet.
enum PDFTextScan {
    struct Target: Sendable {
        let bookID: UUID
        let url: URL
    }

    /// Pages containing `text` (case-insensitive), at most `limit` per book.
    static func find(_ text: String, in target: Target, limit: Int = 60) async -> [SearchHit] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [SearchHit] in
            guard let document = PDFDocument(url: target.url) else { return [] }
            if document.isLocked { _ = document.unlock(withPassword: "") }
            var hits: [SearchHit] = []
            var seenPages = Set<Int>()
            for selection in document.findString(needle, withOptions: [.caseInsensitive]) {
                guard let page = selection.pages.first else { continue }
                let pageIndex = document.index(for: page)
                guard pageIndex != NSNotFound, seenPages.insert(pageIndex).inserted else { continue }
                hits.append(SearchHit(
                    bookID: target.bookID,
                    pageIndex: pageIndex,
                    snippet: snippet(around: selection, needle: needle),
                    rank: Double(hits.count)
                ))
                if hits.count >= limit { break }
            }
            return hits
        }.value
    }

    /// The matched text with some context, marked up like an index snippet.
    private static func snippet(around selection: PDFSelection, needle: String) -> String {
        guard let context = selection.copy() as? PDFSelection else { return needle }
        context.extend(atStart: 60)
        context.extend(atEnd: 90)
        let text = (context.string ?? needle)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard let range = text.range(of: needle, options: .caseInsensitive) else { return text }
        let before = String(text[..<range.lowerBound])
        let match = String(text[range])
        let after = String(text[range.upperBound...])
        return "…\(before)\(SearchIndex.markStart)\(match)\(SearchIndex.markEnd)\(after)…"
    }
}
