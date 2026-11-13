import PDFKit
import SwiftUI

struct ReaderRoute: Hashable {
    var bookID: UUID
    var pageIndex: Int
    var terms: [String] = []
}

struct ReaderView: View {
    private enum ReaderSheet: Identifiable {
        case outline
        case find
        case crossSearch(String)
        case bookmark(Bookmark?, String)
        case link
        case linked
        case bulletins
        case web(URL)

        var id: String {
            switch self {
            case .outline: return "outline"
            case .find: return "find"
            case .crossSearch: return "crossSearch"
            case .bookmark: return "bookmark"
            case .link: return "link"
            case .linked: return "linked"
            case .bulletins: return "bulletins"
            case .web: return "web"
            }
        }
    }

    @Environment(LibraryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    let route: ReaderRoute

    @State private var document: PDFDocument? = nil
    @State private var loadFailed = false
    @State private var currentPage: Int
    @State private var jump: JumpRequest? = nil
    @State private var proxy = PDFViewProxy()
    @State private var outline: [OutlineItem]? = nil
    @State private var sheet: ReaderSheet? = nil
    @State private var showGoTo = false
    @State private var goToText = ""
    @State private var pendingRoute: ReaderRoute? = nil
    @State private var pushedRoute: ReaderRoute? = nil
    @State private var bulletinMatches: [BulletinMatch] = []

    init(route: ReaderRoute) {
        self.route = route
        _currentPage = State(initialValue: route.pageIndex)
        _jump = State(initialValue: JumpRequest(pageIndex: route.pageIndex, terms: route.terms))
    }

    var body: some View {
        Group {
            if let document {
                PDFKitView(document: document, jump: jump, proxy: proxy) { page in
                    currentPage = page
                }
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) { bottomBar }
            } else if loadFailed {
                ContentUnavailableView(
                    "Can't Open This Book",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The PDF file is missing or unreadable.")
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle(book?.displayName ?? "Book")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            guard document == nil else { return }
            if let opened = store.openDocument(bookID: route.bookID) {
                document = opened
            } else {
                loadFailed = true
            }
        }
        .task(id: "\(currentPage)|\(store.bulletinBookIDs.count)|\(document != nil)") {
            await findRelatedBulletins()
        }
        .onDisappear {
            store.setLastPage(bookID: route.bookID, page: currentPage)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                store.setLastPage(bookID: route.bookID, page: currentPage)
            }
        }
        .sheet(item: $sheet, onDismiss: {
            if let next = pendingRoute {
                pendingRoute = nil
                pushedRoute = next
            }
        }, content: { item in
            sheetContent(item)
        })
        .alert("Go to Page", isPresented: $showGoTo) {
            TextField("Page", text: $goToText)
                .keyboardType(.numbersAndPunctuation)
            Button("Go") { goToPage(goToText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a printed page number (like 3-12) or a PDF page number (1–\(document?.pageCount ?? 0)).")
        }
        .navigationDestination(item: $pushedRoute) { next in
            ReaderView(route: next)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                sheet = .find
            } label: {
                Label("Search This Book", systemImage: "magnifyingglass")
            }
            Button {
                sheet = .crossSearch(selectionQuery())
            } label: {
                Label("Find in Other Books", systemImage: "books.vertical")
            }
            Button {
                openBookmarkEditor()
            } label: {
                Label("Bookmark", systemImage: currentBookmark == nil ? "bookmark" : "bookmark.fill")
            }
            Menu {
                Button {
                    showOutline()
                } label: {
                    Label("Table of Contents", systemImage: "list.bullet.indent")
                }
                Button {
                    goToText = ""
                    showGoTo = true
                } label: {
                    Label("Go to Page…", systemImage: "arrow.right.circle")
                }
                Divider()
                Button {
                    sheet = .crossSearch(selectionQuery())
                } label: {
                    Label("Find Selection in Other Books", systemImage: "text.magnifyingglass")
                }
                Button {
                    sheet = .link
                } label: {
                    Label("Link Page to Cross-Reference…", systemImage: "link")
                }
                Button {
                    router.openInCompare(left: PageRef(bookID: route.bookID, pageIndex: currentPage), right: nil)
                } label: {
                    Label("Open in Compare", systemImage: "rectangle.split.2x1")
                }
                if let source = sourceURL {
                    Divider()
                    Button {
                        sheet = .web(source)
                    } label: {
                        Label("View Online / Update Copy", systemImage: "globe")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                goToText = ""
                showGoTo = true
            } label: {
                Text(pageIndicator)
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            if !bulletinMatches.isEmpty {
                let count = Set(bulletinMatches.map(\.hit.bookID)).count
                Button {
                    sheet = .bulletins
                } label: {
                    Label("\(count) bulletin\(count == 1 ? "" : "s")", systemImage: "megaphone.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.orange.opacity(0.22), in: Capsule())
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if !linkedRefs.isEmpty {
                Button {
                    sheet = .linked
                } label: {
                    Label("\(linkedRefs.count) linked", systemImage: "link")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func sheetContent(_ item: ReaderSheet) -> some View {
        switch item {
        case .outline:
            OutlineSheet(items: outline ?? []) { page in
                jump = JumpRequest(pageIndex: page)
            }
        case .find:
            SearchSheet(title: "Search \(book?.displayName ?? "Book")", scope: .only(route.bookID), initialQuery: "") { picked in
                jump = JumpRequest(pageIndex: picked.pageIndex, terms: picked.terms)
            }
        case .crossSearch(let initial):
            SearchSheet(title: "Other Books", scope: .excluding(route.bookID), initialQuery: initial) { picked in
                pendingRoute = picked
            }
        case .bookmark(let existing, let suggestion):
            BookmarkEditor(existing: existing, bookID: route.bookID, pageIndex: currentPage, suggestedTitle: suggestion)
        case .link:
            LinkPageSheet(refs: [PageRef(bookID: route.bookID, pageIndex: currentPage)])
        case .linked:
            LinkedRefsSheet(current: PageRef(bookID: route.bookID, pageIndex: currentPage)) { picked in
                pendingRoute = picked
            }
        case .bulletins:
            BulletinMatchesSheet(matches: bulletinMatches) { picked in
                pendingRoute = picked
            }
        case .web(let url):
            NavigationStack {
                WebCodeBrowser(route: BrowserRoute(
                    url: url,
                    purpose: book?.category == .bulletin ? .bulletin : .municipal,
                    replacing: route.bookID
                ))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { sheet = nil }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private var book: Book? {
        store.book(id: route.bookID)
    }

    private var sourceURL: URL? {
        guard let address = book?.sourceURL, !address.isEmpty else { return nil }
        return URL(string: address)
    }

    /// Looks up saved bulletins that mention the section/rule numbers printed on this page.
    private func findRelatedBulletins() async {
        let bulletinIDs = store.bulletinBookIDs.subtracting([route.bookID])
        guard !bulletinIDs.isEmpty,
              book?.category != .bulletin,
              let document,
              currentPage >= 0, currentPage < document.pageCount,
              let text = document.page(at: currentPage)?.string
        else {
            bulletinMatches = []
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }

        var found: [BulletinMatch] = []
        var seenPages = Set<String>()
        for reference in RuleReferences.headings(in: text, limit: 8) {
            guard let query = QueryBuilder.build("\"\(reference)\"") else { continue }
            let hits = await store.index.search(query.expression, bookIDs: bulletinIDs, limit: 6)
            for hit in hits where seenPages.insert(hit.id).inserted {
                found.append(BulletinMatch(reference: reference, hit: hit))
            }
        }
        if !Task.isCancelled {
            bulletinMatches = found
        }
    }

    private var currentBookmark: Bookmark? {
        store.bookmark(bookID: route.bookID, page: currentPage)
    }

    private var linkedRefs: [CrossReference] {
        store.crossRefs(containing: PageRef(bookID: route.bookID, pageIndex: currentPage))
    }

    private var pageIndicator: String {
        let description = store.pageDescription(bookID: route.bookID, pageIndex: currentPage)
        guard let count = document?.pageCount, count > 0 else { return description }
        return "\(description)  /  \(count)"
    }

    /// The current text selection, cleaned up to use as a search query.
    private func selectionQuery() -> String {
        let collapsed = proxy.selectedText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(80))
    }

    private func openBookmarkEditor() {
        let selected = selectionQuery()
        let suggestion = selected.isEmpty
            ? store.pageDescription(bookID: route.bookID, pageIndex: currentPage)
            : String(selected.prefix(60))
        sheet = .bookmark(currentBookmark, suggestion)
    }

    private func showOutline() {
        if outline == nil, let document {
            outline = OutlineBuilder.build(document)
        }
        sheet = .outline
    }

    private func goToPage(_ text: String) {
        guard let document else { return }
        let wanted = text.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return }
        // Printed page labels first (e.g. "3-12", "xiv"), then plain PDF page numbers.
        for index in 0..<document.pageCount {
            if let label = document.page(at: index)?.label,
               label.caseInsensitiveCompare(wanted) == .orderedSame {
                jump = JumpRequest(pageIndex: index)
                return
            }
        }
        if let number = Int(wanted), number >= 1, number <= document.pageCount {
            jump = JumpRequest(pageIndex: number - 1)
        }
    }
}
