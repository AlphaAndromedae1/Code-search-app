import PDFKit
import SwiftUI

/// State for one side of the compare screen.
@MainActor
@Observable
final class ComparePane {
    var bookID: UUID?
    var document: PDFDocument?
    var currentPage = 0
    var jump: JumpRequest?
    var hits: [SearchHit] = []
    var hitIndex = 0
    var terms: [String] = []
    var message: String?

    var pageRef: PageRef? {
        guard let bookID else { return nil }
        return PageRef(bookID: bookID, pageIndex: currentPage)
    }

    func open(_ ref: PageRef, store: LibraryStore) {
        bookID = ref.bookID
        document = store.openDocument(bookID: ref.bookID)
        currentPage = ref.pageIndex
        jump = JumpRequest(pageIndex: ref.pageIndex)
        clearSearch()
    }

    func clearSearch() {
        hits = []
        hitIndex = 0
        terms = []
        message = nil
    }

    /// Searches this pane's book and jumps to the best match.
    func search(_ query: SearchQuery, store: LibraryStore) async {
        guard let bookID else { return }
        let found = await store.index.search(query.expression, bookIDs: [bookID], limit: 300)
        terms = query.highlightTerms
        hits = found.sorted { $0.pageIndex < $1.pageIndex }
        if let best = found.first, let position = hits.firstIndex(where: { $0.pageIndex == best.pageIndex }) {
            hitIndex = position
            jump = JumpRequest(pageIndex: best.pageIndex, terms: terms)
            message = nil
        } else {
            hitIndex = 0
            message = "No matches"
        }
    }

    func step(_ delta: Int) {
        guard !hits.isEmpty else { return }
        hitIndex = (hitIndex + delta + hits.count) % hits.count
        jump = JumpRequest(pageIndex: hits[hitIndex].pageIndex, terms: terms)
    }
}

/// Two code books side by side (stacked on iPhone portrait), with one search box
/// that finds the same section or words in both.
struct CompareView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var top = ComparePane()
    @State private var bottom = ComparePane()
    @State private var query = ""
    @State private var showLinkSheet = false
    @FocusState private var queryFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if store.books.isEmpty {
                    ContentUnavailableView(
                        "Nothing to Compare Yet",
                        systemImage: "rectangle.split.2x1",
                        description: Text("Import your code books, then view any two side by side here — for example the OESC and the CE Code, or the OBC and your municipality's by-law.")
                    )
                } else {
                    VStack(spacing: 0) {
                        searchBar
                        GeometryReader { geometry in
                            let wide = geometry.size.width > geometry.size.height * 1.1
                            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                            layout {
                                CompareColumn(pane: top) { id in pick(id, for: top) }
                                Rectangle()
                                    .fill(Color(uiColor: .separator))
                                    .frame(width: wide ? 1 : nil, height: wide ? nil : 1)
                                CompareColumn(pane: bottom) { id in pick(id, for: bottom) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        swapPanes()
                    } label: {
                        Label("Swap", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(top.bookID == nil && bottom.bookID == nil)

                    Button {
                        showLinkSheet = true
                    } label: {
                        Label("Link These Pages", systemImage: "link.badge.plus")
                    }
                    .disabled(top.bookID == nil || bottom.bookID == nil)
                }
            }
            .sheet(isPresented: $showLinkSheet) {
                LinkPageSheet(refs: [top.pageRef, bottom.pageRef].compactMap { $0 })
            }
            .onAppear {
                apply(router.compareRequest)
                fillEmptyPanes()
            }
            .onChange(of: router.compareRequest) { _, request in
                apply(request)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search both, e.g. 9.10.19.1 or smoke alarm", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($queryFocused)
                    .onSubmit { runSearch() }
                if !query.isEmpty {
                    Button {
                        query = ""
                        top.clearSearch()
                        bottom.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

            Button("Find") { runSearch() }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func runSearch() {
        queryFocused = false
        guard let built = QueryBuilder.build(query) else { return }
        let first = top
        let second = bottom
        Task {
            await first.search(built, store: store)
            await second.search(built, store: store)
        }
    }

    private func pick(_ bookID: UUID, for pane: ComparePane) {
        let page = store.book(id: bookID)?.lastPage ?? 0
        pane.open(PageRef(bookID: bookID, pageIndex: page), store: store)
        if let built = QueryBuilder.build(query) {
            Task { await pane.search(built, store: store) }
        }
    }

    private func apply(_ request: CompareRequest?) {
        guard let request else { return }
        if let left = request.left { top.open(left, store: store) }
        if let right = request.right { bottom.open(right, store: store) }
        router.compareRequest = nil
    }

    /// Start with the first two books so the screen isn't empty.
    private func fillEmptyPanes() {
        let books = store.books
        if top.bookID == nil, let first = books.first(where: { $0.id != bottom.bookID }) {
            top.open(PageRef(bookID: first.id, pageIndex: first.lastPage), store: store)
        }
        if bottom.bookID == nil, let second = books.first(where: { $0.id != top.bookID }) {
            bottom.open(PageRef(bookID: second.id, pageIndex: second.lastPage), store: store)
        }
    }

    private func swapPanes() {
        let upper = top.pageRef
        let lower = bottom.pageRef
        if let lower { top.open(lower, store: store) }
        if let upper { bottom.open(upper, store: store) }
    }
}

struct CompareColumn: View {
    @Environment(LibraryStore.self) private var store
    let pane: ComparePane
    let onPick: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if let document = pane.document {
                PDFKitView(document: document, jump: pane.jump, proxy: nil) { page in
                    pane.currentPage = page
                }
            } else {
                ContentUnavailableView {
                    Label("Choose a Book", systemImage: "book")
                } description: {
                    Text("Pick a code book to show on this side.")
                } actions: {
                    bookMenu
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var currentBook: Book? {
        pane.bookID.flatMap { store.book(id: $0) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            bookMenu
            Spacer(minLength: 4)
            if !pane.hits.isEmpty {
                Button {
                    pane.step(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                Text("\(pane.hitIndex + 1)/\(pane.hits.count)")
                    .font(.caption.monospacedDigit())
                Button {
                    pane.step(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
            } else if let message = pane.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let id = pane.bookID {
                Text(store.pageDescription(bookID: id, pageIndex: pane.currentPage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var bookMenu: some View {
        Menu {
            ForEach(CodeCategory.allCases) { category in
                let books = store.books.filter { $0.category == category }
                if !books.isEmpty {
                    Section(category.label) {
                        ForEach(books) { book in
                            Button(book.displayName) { onPick(book.id) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: currentBook?.category.symbol ?? "book")
                Text(currentBook?.displayName ?? "Choose Book")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.subheadline.weight(.semibold))
        }
    }
}
