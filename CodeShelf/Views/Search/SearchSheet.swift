import SwiftUI

/// A self-contained search, presented from the reader:
/// "search this book" or "find this selection in my other books".
struct SearchSheet: View {
    enum Scope {
        case all
        case only(UUID)
        case excluding(UUID)
    }

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let title: String
    let scope: Scope
    let onSelect: (ReaderRoute) -> Void
    @State private var query: String
    @State private var model = SearchModel()

    init(title: String, scope: Scope, initialQuery: String, onSelect: @escaping (ReaderRoute) -> Void) {
        self.title = title
        self.scope = scope
        self.onSelect = onSelect
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        NavigationStack {
            Group {
                if trimmedQuery.isEmpty {
                    ContentUnavailableView(
                        "Type to Search",
                        systemImage: "magnifyingglass",
                        description: Text(hint)
                    )
                } else if model.groups.isEmpty {
                    if model.isCurrent(for: query) {
                        ContentUnavailableView.search(text: trimmedQuery)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    SearchResultsList(model: model, mode: .select({ route in
                        onSelect(route)
                        dismiss()
                    }))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Section number, words, or \"phrase\""
            )
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await model.run(query: query, matchAll: true, bookIDs: scopeIDs, store: store)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hint: String {
        switch scope {
        case .all:
            return "Search every book in your library."
        case .only:
            return "Search for a section number, words, or a phrase in this book."
        case .excluding:
            return "Tip: select text on the page first (like a section number) and it will be searched in your other books automatically."
        }
    }

    private var scopeIDs: Set<UUID>? {
        switch scope {
        case .all:
            return nil
        case .only(let id):
            return [id]
        case .excluding(let id):
            return Set(store.books.map(\.id)).subtracting([id])
        }
    }
}
