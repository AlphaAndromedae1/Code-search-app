import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.ocrKey) private var ocrEnabled = true
    @AppStorage(AppSettings.autoCheckKey) private var autoCheck = true
    @AppStorage(AppSettings.notifyKey) private var notify = true
    @AppStorage(AppSettings.autoEquipmentKey) private var autoEquipment = true
    @Environment(\.openURL) private var openURL
    @State private var pdfBytes: Int64 = 0
    @State private var indexBytes: Int64 = 0
    @State private var confirmRebuild = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Check TSSA & CSA Updates Automatically", isOn: $autoCheck)
                    Toggle("Notify Me About New Updates", isOn: $notify)
                    Toggle("Download Manufacturer Instructions", isOn: $autoEquipment)
                } header: {
                    Text("Automatic Updates")
                } footer: {
                    Text("Checks the TSSA, CSA and e-Laws sources you follow when you open the app (if 6+ hours have passed) and in the background a few times a day, as iOS allows. The Fuel Equipment Library's manufacturer instructions are downloaded and refreshed when a manufacturer posts a newer version.")
                }
                .onChange(of: notify) { _, enabled in
                    if enabled { Task { await Notifier.requestPermissionIfNeeded() } }
                }
                .onChange(of: autoCheck) { _, enabled in
                    if enabled { BackgroundRefresh.schedule() }
                }

                Section {
                    Toggle("Read Scanned Pages (OCR)", isOn: $ocrEnabled)
                } footer: {
                    Text("Pages with no selectable text are read with on-device text recognition so they can be searched. Scanned books take longer to index. Applies to books indexed from now on; use Rebuild to re-read existing books.")
                }

                Section("Storage") {
                    LabeledContent("Code books", value: "\(store.books.count)")
                    LabeledContent("PDF files", value: ByteCountFormatter.string(fromByteCount: pdfBytes, countStyle: .file))
                    LabeledContent("Search index", value: ByteCountFormatter.string(fromByteCount: indexBytes, countStyle: .file))
                }

                Section {
                    Button("Rebuild All Search Indexes") {
                        confirmRebuild = true
                    }
                } footer: {
                    Text("Re-reads every PDF. Use this if search results seem incomplete.")
                }

                Section("Search Tips") {
                    tip("9.10.14.5", "Finds that exact article — not 9.10.14.50.")
                    tip("smoke alarm", "Pages containing both words, including word starts like “alarms”.")
                    tip("\"means of egress\"", "Exact phrase when wrapped in quotes.")
                    tip("guard OR handrail", "Either word. The filter menu in Search can also switch to “match any word”.")
                    tip("26-700", "CE Code / OESC rule numbers work the same way.")
                    tip("6.18.2", "So do CSA B149 gas code clause numbers.")
                }

                Section {
                    Button {
                        if let url = URL(string: "shareddocuments://" + DocumentsFolder.root.path) {
                            openURL(url)
                        }
                    } label: {
                        Label("Open CodeShelf Folder in Files", systemImage: "folder")
                    }
                } header: {
                    Text("Files App")
                } footer: {
                    Text("Your PDFs are in Files › On My iPhone › CodeShelf, in Code Books, Manufacturer Instructions, Bulletins and By-laws. Copy PDFs into any of these (or a folder you create there) and they're added automatically. Moving or renaming keeps bookmarks; deleting a PDF there removes it from CodeShelf.")
                }

                Section {
                    NavigationLink {
                        ImportLogView()
                    } label: {
                        Label("Import Log", systemImage: "list.bullet.rectangle")
                    }
                } footer: {
                    Text("Step-by-step record of recent PDF imports — useful if a file won't import.")
                }

                Section("Privacy") {
                    Text("Your PDFs, search index, bookmarks and cross-references stay on this device. CodeShelf goes online only to check the TSSA, CSA and e-Laws pages you follow, to download manufacturer instructions from the manufacturers' sites, and when you browse in the app.")
                        .font(.callout)
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                let summary = store.storageSummary()
                pdfBytes = summary.books
                indexBytes = summary.index
            }
            .confirmationDialog("Rebuild every search index?", isPresented: $confirmRebuild, titleVisibility: .visible) {
                Button("Rebuild") { store.reindexAll() }
            } message: {
                Text("Search results may be incomplete until indexing finishes.")
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func tip(_ example: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(example)
                .font(.body.monospaced())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Recent import steps, so a failing PDF import can be diagnosed.
struct ImportLogView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        List {
            if store.importLog.isEmpty {
                Text("No imports yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(store.importLog.reversed().enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Import Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = store.importLog.joined(separator: "\n")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) {
                    store.clearImportLog()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
        }
    }
}
