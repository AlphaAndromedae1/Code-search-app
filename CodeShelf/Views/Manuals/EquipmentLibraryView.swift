import SwiftUI

/// Manufacturer installation instructions for common fuel equipment, downloaded from each
/// manufacturer and refreshed when they publish a newer version.
struct EquipmentLibraryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(EquipmentLibrary.self) private var equipment

    var body: some View {
        List {
            Section {
                Button {
                    Task { await equipment.sync(store: store) }
                } label: {
                    HStack(spacing: 10) {
                        if equipment.isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                        Text(equipment.isSyncing ? "Downloading from manufacturers…" : "Download All & Check for Updates")
                    }
                }
                .disabled(equipment.isSyncing)
            } footer: {
                Text(syncFooter)
            }

            ForEach(FuelCatalog.groups, id: \.self) { group in
                Section(FuelCatalog.heading(for: group)) {
                    ForEach(FuelCatalog.docs(for: group)) { doc in
                        row(for: doc)
                    }
                }
            }

            Section {
                Text("Always follow the instructions for the exact product and model installed, together with CSA B149.1 / B149.2 and TSSA requirements. Where the code and the instructions differ, the code adopted in Ontario applies unless the instructions are stricter.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Fuel Equipment Library")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ReaderRoute.self) { route in
            ReaderView(route: route)
        }
        .navigationDestination(for: BrowserRoute.self) { route in
            WebCodeBrowser(route: route)
        }
    }

    @ViewBuilder
    private func row(for doc: EquipmentDoc) -> some View {
        if let book = equipment.savedBook(for: doc, in: store) {
            NavigationLink(value: ReaderRoute(bookID: book.id, pageIndex: book.lastPage)) {
                DocRow(doc: doc, status: savedStatus(doc, book: book), tint: .green, symbol: "checkmark.circle.fill")
            }
        } else if doc.downloadURL != nil && equipment.status[doc.id] != .needsBrowser {
            Button {
                Task { await equipment.sync(store: store, only: [doc.id]) }
            } label: {
                DocRow(doc: doc, status: pendingStatus(doc), tint: .accentColor, symbol: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .disabled(equipment.isSyncing)
        } else {
            NavigationLink(value: BrowserRoute(url: doc.downloadURL ?? doc.searchURL, purpose: .manual(doc.manualInfo))) {
                DocRow(doc: doc, status: "Find it on the manufacturer's site, then tap Save — CodeShelf keeps it with your manuals.", tint: .orange, symbol: "globe")
            }
        }
    }

    private func savedStatus(_ doc: EquipmentDoc, book: Book) -> String {
        switch equipment.status[doc.id] {
        case .updated?: return "Updated to the manufacturer's newest version · \(book.pageCount) pages"
        case .working?: return "Checking for a newer version…"
        default: return "\(book.edition.isEmpty ? "Saved" : book.edition) · \(book.pageCount) pages"
        }
    }

    private func pendingStatus(_ doc: EquipmentDoc) -> String {
        switch equipment.status[doc.id] {
        case .working?: return "Downloading…"
        case .failed(let reason)?: return "\(reason). Tap to try again."
        default: return "Not downloaded yet — tap to download from \(doc.downloadURL?.host ?? "the manufacturer")."
        }
    }

    private var syncFooter: String {
        let automatic = AppSettings.autoDownloadEquipment
            ? "Downloads and update checks also run automatically (at most twice a day)."
            : "Automatic downloads are off in Settings."
        guard let last = equipment.lastSync else { return automatic }
        return "Last checked \(last.formatted(.relative(presentation: .named))). " + automatic
    }
}

private struct DocRow: View {
    let doc: EquipmentDoc
    let status: String
    let tint: Color
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text("\(doc.manufacturer) · \(doc.models)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
