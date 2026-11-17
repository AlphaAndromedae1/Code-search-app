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
            }
            ForEach(model.tiers) { tier in
                Section {
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
