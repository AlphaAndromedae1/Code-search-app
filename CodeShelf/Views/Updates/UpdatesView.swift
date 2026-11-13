import SwiftUI

/// New bulletins, amendments and code news from the official sources the user follows.
struct UpdatesView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(UpdatesStore.self) private var updates
    @AppStorage(AppSettings.cityKey) private var city = ""
    @State private var showAddSource = false

    var body: some View {
        NavigationStack {
            List {
                checkSection

                if !updates.items.isEmpty {
                    Section {
                        ForEach(updates.sortedItems) { item in
                            NavigationLink(value: BrowserRoute(url: URL(string: item.url) ?? fallbackURL, purpose: .bulletin)) {
                                UpdateItemRow(item: item, sourceName: updates.source(id: item.sourceID)?.name ?? "")
                            }
                            .swipeActions {
                                Button("Dismiss") { updates.dismiss(item) }
                                    .tint(.gray)
                            }
                        }
                    } header: {
                        HStack {
                            Text("New Since Last Check")
                            Spacer()
                            Button("Clear All") { updates.dismissAll() }
                                .font(.caption)
                        }
                    } footer: {
                        Text("Most relevant first: items naming a code in your library or a rule number. Open one and tap Save to keep it — saved bulletins are linked to the rules they mention.")
                    }
                }

                followingSection

                let suggestions = updates.suggestions(books: store.books, city: city)
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { suggestion in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestion.source.name)
                                    Text(suggestion.source.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Follow") { updates.follow(suggestion.source) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    } header: {
                        Text("Suggested for Your Library")
                    } footer: {
                        Text("Ontario sources — ESA, CSA, TSSA, e-Laws, the Ministry and OBOA — matched to the codes in your library.")
                    }
                }

                Section {
                    LocationFields()
                } header: {
                    Text("Your Municipality")
                } footer: {
                    Text("Used to suggest a search for your municipality's by-law and building news.")
                }

                Section("Bulletins You Already Have") {
                    Label("Import bulletin PDFs (for example the ESA bulletins that come with your OESC) from the Library tab. They're filed under Bulletins & Updates.", systemImage: "tray.and.arrow.down")
                    Label("While reading a code, a 📣 button appears when a saved bulletin mentions a rule on that page.", systemImage: "megaphone")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Updates")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSource = true
                    } label: {
                        Label("Add Source", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSource) {
                AddSourceSheet()
            }
            .navigationDestination(for: BrowserRoute.self) { route in
                WebCodeBrowser(route: route)
            }
        }
    }

    private var fallbackURL: URL {
        URL(string: "https://www.google.com")!
    }

    @ViewBuilder
    private var checkSection: some View {
        Section {
            Button {
                let terms = store.libraryTerms
                Task { await updates.checkAll(libraryTerms: terms) }
            } label: {
                HStack(spacing: 10) {
                    if updates.isChecking {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(updates.isChecking ? updates.progressText : "Check for New Bulletins")
                }
            }
            .disabled(updates.isChecking || !updates.followed.contains(where: \.checkable))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(lastCheckText)
                if !updates.lastProblems.isEmpty {
                    Text("Couldn't read: \(updates.lastProblems.joined(separator: ", ")). Open them below to check by hand.")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var followingSection: some View {
        Section {
            if updates.followed.isEmpty {
                Text("Not following any sources yet. Follow a suggestion below or add your own with +.")
                    .foregroundStyle(.secondary)
            }
            ForEach(updates.followed) { source in
                NavigationLink(value: BrowserRoute(url: URL(string: source.url) ?? fallbackURL, purpose: .bulletin, sourceID: source.id)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name)
                        Text(followingDetail(source))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Unfollow", role: .destructive) { updates.unfollow(source.id) }
                }
            }
        } header: {
            Text("Following")
        }
    }

    private var lastCheckText: String {
        guard let date = updates.lastCheck else {
            return "Checks only happen when you tap the button. The first check of each page records what's already there; later checks show what's new."
        }
        return "Last checked \(date.formatted(.relative(presentation: .named)))."
    }

    private func followingDetail(_ source: UpdateSource) -> String {
        if !source.checkable { return "Web search — open to look for recent items" }
        guard let checked = source.lastChecked else { return "Not checked yet" }
        return "Checked \(checked.formatted(.relative(presentation: .named)))"
    }
}

private struct UpdateItemRow: View {
    let item: UpdateItem
    let sourceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.body.weight(.medium))
                .lineLimit(3)
            Text("\(sourceName) · found \(item.found.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !item.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AddSourceSheet: View {
    @Environment(UpdatesStore.self) private var updates
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. City Building Division news)", text: $name)
                    TextField("Web address", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Use a page that lists bulletins, notices or news as links — for example your building department's news page or an authority's bulletins page.")
                }
                if failed {
                    Text("That doesn't look like a web address.")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Add Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Follow") {
                        if updates.addCustomSource(name: name, address: address) {
                            dismiss()
                        } else {
                            failed = true
                        }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// Bulletins in the library that mention rules printed on the current code page.
struct BulletinMatch: Identifiable {
    let reference: String
    let hit: SearchHit

    var id: String { hit.id + "|" + reference }
}

struct BulletinMatchesSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let matches: [BulletinMatch]
    let onOpen: (ReaderRoute) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(references, id: \.self) { reference in
                    Section {
                        ForEach(matches.filter { $0.reference == reference }) { match in
                            Button {
                                onOpen(ReaderRoute(bookID: match.hit.bookID, pageIndex: match.hit.pageIndex, terms: [reference]))
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(store.book(id: match.hit.bookID)?.displayName ?? "Bulletin")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(store.pageDescription(bookID: match.hit.bookID, pageIndex: match.hit.pageIndex))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(SnippetFormatter.attributed(match.hit.snippet))
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                        .lineLimit(3)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Mentions \(reference)")
                    }
                }
            }
            .navigationTitle("Related Bulletins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var references: [String] {
        var ordered: [String] = []
        for match in matches where !ordered.contains(match.reference) {
            ordered.append(match.reference)
        }
        return ordered
    }
}
