import PDFKit
import SwiftUI

// MARK: - Table of contents

struct OutlineItem: Identifiable {
    let id = UUID()
    let title: String
    let pageIndex: Int?
    var children: [OutlineItem]?
}

enum OutlineBuilder {
    /// Reads the PDF's bookmark tree (most code book PDFs ship with one).
    static func build(_ document: PDFDocument) -> [OutlineItem] {
        guard let root = document.outlineRoot else { return [] }
        var budget = 8000
        return children(of: root, in: document, depth: 0, budget: &budget)
    }

    private static func children(of node: PDFOutline, in document: PDFDocument, depth: Int, budget: inout Int) -> [OutlineItem] {
        var items: [OutlineItem] = []
        for i in 0..<node.numberOfChildren {
            guard budget > 0, let child = node.child(at: i) else { break }
            budget -= 1
            var page: Int?
            if let target = child.destination?.page {
                page = document.index(for: target)
            } else if let action = child.action as? PDFActionGoTo, let target = action.destination.page {
                page = document.index(for: target)
            }
            let nested = depth < 8 ? children(of: child, in: document, depth: depth + 1, budget: &budget) : []
            let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            items.append(OutlineItem(title: title.isEmpty ? "Untitled" : title, pageIndex: page, children: nested.isEmpty ? nil : nested))
        }
        return items
    }

    static func flatten(_ items: [OutlineItem]) -> [OutlineItem] {
        var result: [OutlineItem] = []
        for item in items {
            result.append(item)
            if let children = item.children {
                result.append(contentsOf: flatten(children))
            }
        }
        return result
    }
}

struct OutlineSheet: View {
    @Environment(\.dismiss) private var dismiss
    let items: [OutlineItem]
    let onSelect: (Int) -> Void
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No Table of Contents",
                        systemImage: "list.bullet.indent",
                        description: Text("This PDF doesn't include bookmarks. Use search to find sections.")
                    )
                } else if filter.trimmingCharacters(in: .whitespaces).isEmpty {
                    List(items, children: \.children) { item in
                        row(item)
                    }
                } else {
                    List(filtered) { item in
                        row(item)
                    }
                }
            }
            .searchable(text: $filter, prompt: "Filter chapters and sections")
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var filtered: [OutlineItem] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        return OutlineBuilder.flatten(items).filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    private func row(_ item: OutlineItem) -> some View {
        Button {
            if let page = item.pageIndex {
                onSelect(page)
                dismiss()
            }
        } label: {
            HStack {
                Text(item.title)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer()
                if let page = item.pageIndex {
                    Text("\(page + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .disabled(item.pageIndex == nil)
    }
}

// MARK: - Bookmarks

struct BookmarkEditor: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let existing: Bookmark?
    let bookID: UUID
    let pageIndex: Int
    @State private var title: String
    @State private var note: String

    init(existing: Bookmark?, bookID: UUID, pageIndex: Int, suggestedTitle: String) {
        self.existing = existing
        self.bookID = bookID
        self.pageIndex = pageIndex
        _title = State(initialValue: existing?.title ?? suggestedTitle)
        _note = State(initialValue: existing?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(3...10)
                } footer: {
                    Text(store.describe(PageRef(bookID: bookID, pageIndex: pageIndex)))
                }
                if let existing {
                    Section {
                        Button("Remove Bookmark", role: .destructive) {
                            store.deleteBookmark(id: existing.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Bookmark" : "Edit Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var bookmark = existing ?? Bookmark(bookID: bookID, pageIndex: pageIndex, title: "")
        bookmark.title = trimmed.isEmpty ? "Page \(pageIndex + 1)" : trimmed
        bookmark.note = note
        store.saveBookmark(bookmark)
    }
}

// MARK: - Cross-references

/// Create a new cross-reference from one or more pages, or add them to an existing one.
struct LinkPageSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let refs: [PageRef]
    @State private var title = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Pages") {
                    ForEach(refs, id: \.self) { ref in
                        Label(store.describe(ref), systemImage: "doc.text")
                    }
                }

                Section {
                    TextField("Title", text: $title, prompt: Text(defaultTitle))
                    TextField("Note (e.g. city amends this section)", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                    Button {
                        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.createCrossRef(title: finalTitle.isEmpty ? defaultTitle : finalTitle, note: note, refs: refs)
                        dismiss()
                    } label: {
                        Label("Create Cross-Reference", systemImage: "link.badge.plus")
                    }
                } header: {
                    Text("New Cross-Reference")
                }

                if !store.crossRefs.isEmpty {
                    Section("Or Add to an Existing One") {
                        ForEach(store.crossRefs) { reference in
                            let alreadyLinked = refs.allSatisfy { reference.refs.contains($0) }
                            Button {
                                store.addPages(refs, toCrossRef: reference.id)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reference.title)
                                        .foregroundStyle(.primary)
                                    Text(alreadyLinked ? "Already linked" : "\(reference.refs.count) page\(reference.refs.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(alreadyLinked)
                        }
                    }
                }
            }
            .navigationTitle("Link Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var defaultTitle: String {
        refs.map { store.shortDescribe($0) }.joined(separator: " ↔ ")
    }
}

/// Shows the cross-references that include the current page.
struct LinkedRefsSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let current: PageRef
    let onOpen: (ReaderRoute) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.crossRefs(containing: current)) { reference in
                    Section {
                        if !reference.note.isEmpty {
                            Text(reference.note)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        let others = reference.refs.filter { $0 != current }
                        if others.isEmpty {
                            Text("No other pages linked yet.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(others, id: \.self) { ref in
                            Button {
                                onOpen(ReaderRoute(bookID: ref.bookID, pageIndex: ref.pageIndex))
                                dismiss()
                            } label: {
                                Label(store.describe(ref), systemImage: "arrow.turn.down.right")
                            }
                        }
                    } header: {
                        Text(reference.title)
                    }
                }
            }
            .navigationTitle("Linked References")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
