import SwiftUI

/// The main "search everything" tab.
struct SearchView: View {
    @Environment(LibraryStore.self) private var store
    @State private var model = SearchModel()
    @State private var query = ""
    @State private var matchAll = true
    @State private var category: CodeCategory? = nil
    @State private var codesOnly = false
    @State private var selectedBooks: Set<UUID> = []
    @State private var showBookPicker = false
    @AppStorage(AppSettings.recentSearchesKey) private var recentStorage = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Section number, words, or \"exact phrase\""
                )
                .onSubmit(of: .search) { remember(query) }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { filterMenu }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !store.books.isEmpty { filterBar }
                }
                .task(id: searchKey) { await performSearch() }
                .sheet(isPresented: $showBookPicker) {
                    BookPickerSheet(selection: $selectedBooks)
                }
                .navigationDestination(for: ReaderRoute.self) { route in
                    ReaderView(route: route)
                }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.books.isEmpty {
            ContentUnavailableView(
                "No Code Books Yet",
                systemImage: "books.vertical",
                description: Text("Import your PDFs from the Library tab, then search across all of them here.")
            )
        } else if trimmedQuery.isEmpty {
            idleView
        } else if model.groups.isEmpty {
            if model.isCurrent(for: query) {
                ContentUnavailableView.search(text: trimmedQuery)
            } else {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            SearchResultsList(model: model, mode: .navigate)
        }
    }

    private var idleView: some View {
        List {
            if !recentSearches.isEmpty {
                Section {
                    ForEach(recentSearches, id: \.self) { recent in
                        Button {
                            query = recent
                        } label: {
                            Label(recent, systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.primary)
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Button("Clear") { recentStorage = "" }
                            .font(.caption)
                    }
                }
            }
            Section("How to search") {
                Label("Type a rule or article number like 26-700 or 9.10.14.5", systemImage: "number")
                Label("Words find pages containing all of them", systemImage: "text.word.spacing")
                Label("Put a phrase in quotes for an exact match", systemImage: "quote.opening")
                Label("Code books are always listed before manufacturer instructions", systemImage: "books.vertical")
                Label("Filter by category or pick specific books", systemImage: "line.3.horizontal.decrease.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var filterBar: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("All", systemImage: "square.grid.2x2", selected: category == nil && !codesOnly) {
                        category = nil
                        codesOnly = false
                    }
                    if hasCodeBooks {
                        chip("Code Books", systemImage: "books.vertical", selected: codesOnly) {
                            codesOnly.toggle()
                            category = nil
                        }
                    }
                    ForEach(availableCategories) { item in
                        chip(item.label, systemImage: item.symbol, selected: category == item) {
                            category = (category == item) ? nil : item
                            codesOnly = false
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            indexingStatus
            if !selectedBooks.isEmpty {
                Text("Searching \(selectedBooks.count) selected book\(selectedBooks.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
        }
        .background(.bar)
    }

    /// Names the code books that can't be fully searched yet, so a missing result is explained.
    @ViewBuilder
    private var indexingStatus: some View {
        let pending = store.codeBooksStillIndexing
        let unreadable = store.books.filter { SearchTier.of($0.category) == .codes && $0.hasNoSearchableText }
        if !pending.isEmpty {
            Label(pendingText(pending), systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal)
                .padding(.bottom, 6)
        } else if store.hasPendingIndexing {
            Label("Code books are ready. Still indexing manufacturer instructions.", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 6)
        }
        if !unreadable.isEmpty {
            Label(
                "No searchable text in \(unreadable.map(\.displayName).joined(separator: ", ")). If it's a scan, turn on Settings › Read Scanned Pages (OCR), then use Rebuild Search Index on the book in Library.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .multilineTextAlignment(.leading)
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
    }

    private func pendingText(_ books: [Book]) -> String {
        let names = books.prefix(3).map { book -> String in
            let progress = store.indexing[book.id] ?? IndexProgress(done: book.indexedPages, total: book.pageCount)
            return "\(book.displayName) (\(Int(progress.fraction * 100))%)"
        }
        let more = books.count > 3 ? " and \(books.count - 3) more" : ""
        return "Still indexing \(names.joined(separator: ", "))\(more) — pages not reached yet won't show up."
    }

    private var hasCodeBooks: Bool {
        store.books.contains { SearchTier.of($0.category) == .codes }
    }

    private func chip(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color(uiColor: .secondarySystemBackground), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Match", selection: $matchAll) {
                Text("Match all words").tag(true)
                Text("Match any word").tag(false)
            }
            Button {
                showBookPicker = true
            } label: {
                Label(selectedBooks.isEmpty ? "Choose Books…" : "Books (\(selectedBooks.count))…", systemImage: "books.vertical")
            }
            if hasFilters {
                Button(role: .destructive) {
                    selectedBooks = []
                    category = nil
                    codesOnly = false
                    matchAll = true
                } label: {
                    Label("Clear Filters", systemImage: "xmark.circle")
                }
            }
        } label: {
            Label("Filters", systemImage: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    // MARK: Logic

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasFilters: Bool {
        category != nil || codesOnly || !selectedBooks.isEmpty || !matchAll
    }

    private var availableCategories: [CodeCategory] {
        let present = Set(store.books.map(\.category))
        return CodeCategory.allCases.filter { present.contains($0) }
    }

    private var scopeIDs: Set<UUID>? {
        guard category != nil || codesOnly || !selectedBooks.isEmpty else { return nil }
        var ids = Set(store.books.map(\.id))
        if let category {
            ids = Set(store.books.filter { $0.category == category }.map(\.id))
        } else if codesOnly {
            ids = Set(store.books.filter { SearchTier.of($0.category) == .codes }.map(\.id))
        }
        if !selectedBooks.isEmpty {
            ids = ids.intersection(selectedBooks)
        }
        return ids
    }

    private var searchKey: String {
        let books = selectedBooks.map(\.uuidString).sorted().joined(separator: ",")
        let indexed = store.books.reduce(0) { $0 + $1.indexedPages / 50 }
        return [trimmedQuery, matchAll ? "all" : "any", category?.rawValue ?? (codesOnly ? "codes" : ""), books,
                "\(store.books.count)", "\(indexed)"]
            .joined(separator: "|")
    }

    private func performSearch() async {
        let current = query
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.clear()
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        await model.run(query: current, matchAll: matchAll, bookIDs: scopeIDs, store: store)
    }

    private var recentSearches: [String] {
        recentStorage
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func remember(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        recentStorage = list.prefix(12).joined(separator: "\n")
    }
}

/// Multi-select list of books to limit a search to.
struct BookPickerSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Set<UUID>

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.books) { book in
                    Button {
                        if selection.contains(book.id) {
                            selection.remove(book.id)
                        } else {
                            selection.insert(book.id)
                        }
                    } label: {
                        HStack {
                            Label(book.displayName, systemImage: book.category.symbol)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selection.contains(book.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("All Books") {
                        selection = []
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
