import SwiftUI

/// The user's Ontario municipality, shared by the by-law finder and the Updates tab.
struct LocationFields: View {
    @AppStorage(AppSettings.cityKey) private var city = ""

    var body: some View {
        TextField("Municipality (e.g. Ottawa, Barrie, Township of Oro-Medonte)", text: $city)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
    }
}

/// Ontario's codes on e-Laws, and the user's municipal by-laws, opened in the in-app browser.
struct MunicipalCodeView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.cityKey) private var city = ""
    @AppStorage(AppSettings.municipalHomeKey) private var municipalHome = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LocationFields()
                } header: {
                    Text("Your Municipality")
                }

                if let home = URL(string: municipalHome), !municipalHome.isEmpty {
                    Section {
                        NavigationLink(value: BrowserRoute(url: home, purpose: .municipal)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Open My By-laws", systemImage: "building.columns.fill")
                                    .font(.headline)
                                Text(home.host ?? municipalHome)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Forget This Site", role: .destructive) {
                            municipalHome = ""
                        }
                    } header: {
                        Text("Your By-laws")
                    }
                }

                Section {
                    let sources = MunicipalSources.sources(city: city)
                    if sources.isEmpty {
                        Text("Enter your municipality above to find its by-laws.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sources) { source in
                        NavigationLink(value: BrowserRoute(url: source.url, purpose: .municipal)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.name)
                                Text(source.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Find Your By-laws")
                } footer: {
                    Text("Ontario municipalities publish their own by-laws. Once you reach yours, tap ☆ in the browser so it opens straight there next time.")
                }

                Section {
                    ForEach(Ontario.laws) { law in
                        if let url = law.url {
                            NavigationLink(value: BrowserRoute(url: url, purpose: .regulation(law.id))) {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: law.category.symbol)
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(law.name) — \(law.citation)")
                                        Text(law.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Ontario Laws (e-Laws)")
                } footer: {
                    Text("e-Laws is the official source of Ontario's statutes and regulations. The Fire Code is published there in full; the Building Code and OESC regulations adopt their code books by reference and list every amendment.")
                }

                Section("How Saving Works") {
                    Label("Open the page you need — a by-law, or a regulation on e-Laws — then tap Save.", systemImage: "1.circle")
                    Label("CodeShelf saves it as a searchable PDF with its web address and the date. Linked PDFs are saved as-is.", systemImage: "2.circle")
                    Label("Search it with your other codes, compare it side by side, and link it to the code articles it relates to.", systemImage: "3.circle")
                }
                .font(.callout)

                if !savedPages.isEmpty {
                    Section {
                        ForEach(savedPages) { book in
                            if let url = URL(string: book.sourceURL) {
                                NavigationLink(value: BrowserRoute(url: url, purpose: book.category == .bulletin ? .bulletin : .municipal, replacing: book.id)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(book.displayName)
                                        Text([book.jurisdiction, book.edition].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Saved From the Web")
                    } footer: {
                        Text("Open one to check the live page for changes, then tap Save to replace your copy. Bookmarks and links are kept.")
                    }
                }
            }
            .navigationTitle("Ontario Laws & By-laws")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: BrowserRoute.self) { route in
                WebCodeBrowser(route: route)
            }
        }
    }

    private var savedPages: [Book] {
        store.books
            .filter { !$0.sourceURL.isEmpty }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}
