import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var showMunicipal = false
    @State private var editingBook: Book? = nil
    @State private var pendingDelete: Book? = nil
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.books.isEmpty {
                    emptyState
                } else {
                    bookList
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showImporter = true
                        } label: {
                            Label("Import PDF Files…", systemImage: "doc.badge.plus")
                        }
                        Button {
                            showMunicipal = true
                        } label: {
                            Label("Ontario Laws & By-laws…", systemImage: "building.columns")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    Task { await store.importPDFs(from: urls) }
                case .failure(let error):
                    store.alertMessage = error.localizedDescription
                }
            }
            .sheet(item: $editingBook) { book in
                BookEditView(book: book)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showMunicipal) {
                MunicipalCodeView()
            }
            .confirmationDialog("Delete this code book?", isPresented: deleteBinding, titleVisibility: .visible, presenting: pendingDelete) { book in
                Button("Delete “\(book.displayName)”", role: .destructive) {
                    store.delete(book)
                }
            } message: { _ in
                Text("The PDF, its search index, and its bookmarks and cross-reference links will be removed from CodeShelf.")
            }
            .navigationDestination(for: ReaderRoute.self) { route in
                ReaderView(route: route)
            }
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Code Books Yet", systemImage: "books.vertical")
        } description: {
            Text("Import the code book PDFs you own — OBC, OESC, CE Code, National Codes, fire, plumbing, municipal by-laws and more. Each one is indexed on this device so you can search them all at once.")
        } actions: {
            Button {
                showImporter = true
            } label: {
                Label("Import PDFs", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Button {
                showMunicipal = true
            } label: {
                Label("Ontario Laws & My By-laws", systemImage: "building.columns")
            }
            .buttonStyle(.bordered)
        }
    }

    private var bookList: some View {
        List {
            if store.hasPendingIndexing {
                Section {
                    Label("Books are being indexed for search. You can read them while this runs.", systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(visibleCategories) { category in
                Section {
                    ForEach(books(in: category)) { book in
                        NavigationLink(value: ReaderRoute(bookID: book.id, pageIndex: book.lastPage)) {
                            BookRow(book: book)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = book
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                editingBook = book
                            } label: {
                                Label("Info", systemImage: "info.circle")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                editingBook = book
                            } label: {
                                Label("Edit Info", systemImage: "pencil")
                            }
                            Button {
                                store.reindex(bookID: book.id)
                            } label: {
                                Label("Rebuild Search Index", systemImage: "arrow.clockwise")
                            }
                            Button(role: .destructive) {
                                pendingDelete = book
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Label(category.label, systemImage: category.symbol)
                }
            }
        }
        .searchable(text: $filter, prompt: "Filter by name, jurisdiction, year")
    }

    private var visibleCategories: [CodeCategory] {
        CodeCategory.allCases.filter { !books(in: $0).isEmpty }
    }

    private func books(in category: CodeCategory) -> [Book] {
        store.books
            .filter { $0.category == category && matchesFilter($0) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func matchesFilter(_ book: Book) -> Bool {
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        return [book.title, book.shortName, book.jurisdiction, book.edition, book.category.label]
            .contains { $0.localizedCaseInsensitiveContains(text) }
    }
}

struct BookRow: View {
    @Environment(LibraryStore.self) private var store
    let book: Book
    @State private var thumbnail: UIImage? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: .secondarySystemBackground))
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: book.category.symbol)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(uiColor: .separator), lineWidth: 0.5)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(book.displayName)
                    .font(.headline)
                    .lineLimit(2)
                if book.displayName != book.title {
                    Text(book.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let progress = store.indexing[book.id] {
                    ProgressView(value: progress.fraction) {
                        Text("Indexing \(progress.done) of \(progress.total) pages")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .progressViewStyle(.linear)
                } else if !book.isIndexed {
                    Text("Waiting to index")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
        .task(id: book.id) {
            thumbnail = await store.thumbnail(for: book)
        }
    }

    private var detailLine: String {
        var parts: [String] = []
        if !book.subtitle.isEmpty { parts.append(book.subtitle) }
        parts.append("\(book.pageCount) pages")
        if book.ocrPages > 0 { parts.append("\(book.ocrPages) scanned") }
        return parts.joined(separator: " · ")
    }
}
