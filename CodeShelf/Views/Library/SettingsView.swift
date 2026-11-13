import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.ocrKey) private var ocrEnabled = true
    @State private var pdfBytes: Int64 = 0
    @State private var indexBytes: Int64 = 0
    @State private var confirmRebuild = false

    var body: some View {
        NavigationStack {
            Form {
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

                Section("Privacy") {
                    Text("Your PDFs, search index, bookmarks and cross-references stay on this device. CodeShelf only goes online when you browse for municipal codes or bulletins, or tap “Check for New Bulletins” — and then only to the pages you follow.")
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
