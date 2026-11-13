import SwiftUI

struct CrossRefRoute: Hashable {
    let id: UUID
}

/// Bookmarks and cross-references in one place.
struct SavedView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case bookmarks = "Bookmarks"
        case links = "Cross-References"

        var id: String { rawValue }
    }

    @Environment(LibraryStore.self) private var store
    @State private var segment: Segment = .bookmarks

    var body: some View {
        NavigationStack {
            Group {
                switch segment {
                case .bookmarks:
                    bookmarksList
                case .links:
                    crossRefList
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Show", selection: $segment) {
                    ForEach(Segment.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle("Saved")
            .navigationDestination(for: ReaderRoute.self) { route in
                ReaderView(route: route)
            }
            .navigationDestination(for: CrossRefRoute.self) { route in
                CrossRefDetailView(refID: route.id)
            }
        }
    }

    @ViewBuilder
    private var bookmarksList: some View {
        if store.bookmarks.isEmpty {
            ContentUnavailableView(
                "No Bookmarks",
                systemImage: "bookmark",
                description: Text("Tap the bookmark button while reading to save a page with a note.")
            )
        } else {
            List {
                ForEach(booksWithBookmarks) { book in
                    Section(book.displayName) {
                        ForEach(bookmarks(for: book.id)) { bookmark in
                            NavigationLink(value: ReaderRoute(bookID: bookmark.bookID, pageIndex: bookmark.pageIndex)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(bookmark.title)
                                        .font(.body.weight(.medium))
                                    Text(store.pageDescription(bookID: bookmark.bookID, pageIndex: bookmark.pageIndex))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !bookmark.note.isEmpty {
                                        Text(bookmark.note)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.deleteBookmark(id: bookmark.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var crossRefList: some View {
        if store.crossRefs.isEmpty {
            ContentUnavailableView(
                "No Cross-References",
                systemImage: "link",
                description: Text("Link related sections across books — like an OESC rule and the CE Code rule it amends, or an OBC article and your municipality's by-law. Use “Link Page” in the reader's ••• menu, or the link button on the Compare tab.")
            )
        } else {
            List {
                ForEach(store.crossRefs) { reference in
                    NavigationLink(value: CrossRefRoute(id: reference.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reference.title)
                                .font(.headline)
                            Text(reference.refs.map { store.shortDescribe($0) }.joined(separator: "  ↔  "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if !reference.note.isEmpty {
                                Text(reference.note)
                                    .font(.callout)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            store.deleteCrossRef(id: reference.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var booksWithBookmarks: [Book] {
        let ids = Set(store.bookmarks.map(\.bookID))
        return store.books.filter { ids.contains($0.id) }
    }

    private func bookmarks(for bookID: UUID) -> [Bookmark] {
        store.bookmarks
            .filter { $0.bookID == bookID }
            .sorted { $0.pageIndex < $1.pageIndex }
    }
}

struct CrossRefDetailView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    let refID: UUID
    @State private var title = ""
    @State private var note = ""
    @State private var loaded = false

    var body: some View {
        if let reference = store.crossRefs.first(where: { $0.id == refID }) {
            Form {
                Section("Title") {
                    TextField("Title", text: $title)
                }
                Section("Note") {
                    TextField("How these sections relate, local amendments, etc.", text: $note, axis: .vertical)
                        .lineLimit(3...10)
                }
                Section {
                    ForEach(reference.refs, id: \.self) { ref in
                        NavigationLink(value: ReaderRoute(bookID: ref.bookID, pageIndex: ref.pageIndex)) {
                            Label(store.describe(ref), systemImage: "doc.text")
                        }
                    }
                    .onDelete { offsets in
                        store.removePages(at: offsets, fromCrossRef: refID)
                    }
                } header: {
                    Text("Linked Pages")
                } footer: {
                    Text("Add more pages from any book with “Link Page to Cross-Reference” in the reader's ••• menu.")
                }
                if reference.refs.count >= 2 {
                    Section {
                        Button {
                            router.openInCompare(left: reference.refs[0], right: reference.refs[1])
                        } label: {
                            Label("Open First Two Side by Side", systemImage: "rectangle.split.2x1")
                        }
                    }
                }
                Section {
                    Button("Delete Cross-Reference", role: .destructive) {
                        store.deleteCrossRef(id: refID)
                        dismiss()
                    }
                }
            }
            .navigationTitle(reference.title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !loaded else { return }
                title = reference.title
                note = reference.note
                loaded = true
            }
            .onChange(of: title) { _, newValue in
                if loaded { store.updateCrossRef(id: refID, title: newValue, note: nil) }
            }
            .onChange(of: note) { _, newValue in
                if loaded { store.updateCrossRef(id: refID, title: nil, note: newValue) }
            }
        } else {
            ContentUnavailableView("Cross-Reference Deleted", systemImage: "link")
        }
    }
}
