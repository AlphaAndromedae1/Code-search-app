import SwiftUI

/// Results grouped by book. Used by the Search tab and the in-reader search sheets.
struct SearchResultsList: View {
    enum Mode {
        /// Push a reader onto the surrounding NavigationStack.
        case navigate
        /// Hand the chosen page back to the caller.
        case select((ReaderRoute) -> Void)
    }

    @Environment(LibraryStore.self) private var store
    let model: SearchModel
    let mode: Mode
    @State private var expanded: Set<UUID> = []

    private let previewCount = 5

    var body: some View {
        List {
            Section {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if model.isScanningPDFs {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Not in the search index. Reading your code books directly…")
                            .font(.callout)
                    }
                }
            }
            if model.missedCodeBooks {
                CodeBookSearchStatus(query: model.lastQuery)
            }
            ForEach(model.tiers) { tier in
                Section {
                    if let note = tier.note {
                        Label(note, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Label(tier.tier.label, systemImage: tier.tier.symbol)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(tier.pageCount) page\(tier.pageCount == 1 ? "" : "s")")
                            .font(.caption)
                    }
                    .textCase(nil)
                }
                ForEach(tier.groups) { group in
                    bookSection(group)
                }
            }
        }
        .listStyle(.insetGrouped)
        .onChange(of: model.lastQuery) { _, _ in
            expanded = []
        }
    }

    @ViewBuilder
    private func bookSection(_ group: BookHits) -> some View {
        if let book = store.book(id: group.bookID) {
            Section {
                ForEach(visibleHits(for: group)) { hit in
                    row(for: hit)
                }
                if group.hits.count > previewCount && !expanded.contains(group.bookID) {
                    Button("Show all \(group.hits.count) pages") {
                        expanded.insert(group.bookID)
                    }
                    .font(.callout)
                }
            } header: {
                HStack {
                    Label(book.displayName, systemImage: book.category.symbol)
                    Spacer()
                    Text("\(group.hits.count)")
                        .monospacedDigit()
                }
            }
        }
    }

    private var summary: String {
        let pages = model.totalHits
        let books = model.groups.count
        var text = "\(pages) matching page\(pages == 1 ? "" : "s") in \(books) book\(books == 1 ? "" : "s"). Code books first, best matches first."
        if model.hitLimitReached {
            text += " Showing the top matches — add words to narrow it down."
        }
        return text
    }

    private func visibleHits(for group: BookHits) -> [SearchHit] {
        expanded.contains(group.bookID) ? group.hits : Array(group.hits.prefix(previewCount))
    }

    @ViewBuilder
    private func row(for hit: SearchHit) -> some View {
        let route = ReaderRoute(bookID: hit.bookID, pageIndex: hit.pageIndex, terms: model.highlightTerms)
        switch mode {
        case .navigate:
            NavigationLink(value: route) {
                SearchHitRow(hit: hit)
            }
        case .select(let handler):
            Button {
                handler(route)
            } label: {
                SearchHitRow(hit: hit)
            }
            .buttonStyle(.plain)
        }
    }
}

struct SearchHitRow: View {
    @Environment(LibraryStore.self) private var store
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.pageDescription(bookID: hit.bookID, pageIndex: hit.pageIndex))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(SnippetFormatter.attributed(hit.snippet))
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(4)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Explains why a search found nothing in the code books: still indexing, no readable text,
/// or the text CodeShelf reads doesn't contain it, with what to do about each.
struct CodeBookSearchStatus: View {
    @Environment(LibraryStore.self) private var store
    let query: String

    var body: some View {
        Section {
            ForEach(codeBooks) { book in
                VStack(alignment: .leading, spacing: 3) {
                    Label(book.displayName, systemImage: book.category.symbol)
                        .font(.subheadline.weight(.semibold))
                    Text(status(of: book))
                        .font(.caption)
                        .foregroundStyle(book.hasNoSearchableText || !book.isIndexed ? Color.orange : Color.secondary)
                    if book.isIndexed && !book.forceOCR {
                        Button("Re-read This Book with OCR") {
                            store.rereadWithOCR(bookID: book.id)
                        }
                        .font(.caption)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Not found in your code books")
        } footer: {
            Text("Open the page where “\(query)” is printed and choose ••• › Show Searchable Text. It shows exactly what CodeShelf can read on that page. If the text is scrambled or missing, use Re-read This Book with OCR, which reads the printed page instead. It takes a few minutes for a large book; keep CodeShelf open while it runs.")
        }
    }

    private var codeBooks: [Book] {
        store.books.filter { SearchTier.of($0.category) == .codes }
    }

    private func status(of book: Book) -> String {
        if !book.isIndexed {
            let progress = store.indexing[book.id] ?? IndexProgress(done: book.indexedPages, total: book.pageCount)
            return "Still indexing: \(book.indexedPages) of \(book.pageCount) pages (\(Int(progress.fraction * 100))%). Keep CodeShelf open so it can finish."
        }
        if book.hasNoSearchableText {
            return "No readable text in this PDF (\(book.pageCount) pages)."
        }
        var parts = ["\(book.pageCount) pages indexed"]
        if book.textPages >= 0 { parts.append("\(book.textPages) with text") }
        if book.ocrPages > 0 { parts.append("\(book.ocrPages) read with OCR") }
        if book.forceOCR { parts.append("OCR on every page") }
        return parts.joined(separator: " · ") + ". “\(query)” isn't in the text CodeShelf reads."
    }
}
