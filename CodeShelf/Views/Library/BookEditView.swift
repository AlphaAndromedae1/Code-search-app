import SwiftUI

struct BookEditView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Book

    init(book: Book) {
        _draft = State(initialValue: book)
    }

    /// Standard equipment types, plus the book's own value if it was typed in differently.
    private var equipmentChoices: [String] {
        let list = ManualInfo.equipmentTypes
        let current = draft.equipmentType
        return current.isEmpty || list.contains(current) ? list : [current] + list
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    TextField("Short name", text: $draft.shortName, prompt: Text("e.g. OBC 2024, B149.1 2025, NFPA 13"))
                    Picker("Category", selection: $draft.category) {
                        ForEach(CodeCategory.allCases) { category in
                            Label(category.label, systemImage: category.symbol).tag(category)
                        }
                    }
                    if draft.category == .manufacturer {
                        TextField("Manufacturer", text: $draft.jurisdiction, prompt: Text("e.g. Carrier, Lennox, Beckett"))
                        TextField("Model number(s)", text: $draft.modelNumbers, prompt: Text("e.g. 59SC5A080, 59SC5A100"))
                        Picker("Equipment", selection: $draft.equipmentType) {
                            Text("—").tag("")
                            ForEach(equipmentChoices, id: \.self) { type in
                                Text(type).tag(type)
                            }
                        }
                        TextField("Revision / date", text: $draft.edition, prompt: Text("e.g. Rev. C, 2023"))
                    } else {
                        TextField("Jurisdiction / publisher", text: $draft.jurisdiction, prompt: Text("e.g. ESA, CSA, NFPA, City of Ottawa"))
                        TextField("Edition / year", text: $draft.edition, prompt: Text("e.g. 2024"))
                    }
                } header: {
                    Text("Details")
                } footer: {
                    Text("\(draft.category.label): \(draft.category.examples)")
                }

                if let live = store.book(id: draft.id), let source = URL(string: live.sourceURL), !live.sourceURL.isEmpty {
                    Section {
                        Link(destination: source) {
                            LabeledContent("Saved from", value: source.host ?? live.sourceURL)
                        }
                    } footer: {
                        Text("To update it, open Library → + → Ontario Laws & By-laws → Saved From the Web, or use ••• → View Online in the reader.")
                    }
                }

                Section("Notes") {
                    TextField("Adoption date, local amendments, etc.", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                if let live = store.book(id: draft.id) {
                    Section {
                        LabeledContent("Pages", value: "\(live.pageCount)")
                        LabeledContent("Indexed", value: live.isIndexed ? "Complete" : "\(live.indexedPages) of \(live.pageCount)")
                        LabeledContent("Scanned pages (OCR)", value: "\(live.ocrPages)")
                        LabeledContent("File size", value: ByteCountFormatter.string(fromByteCount: live.fileSize, countStyle: .file))
                        Button("Rebuild Search Index") {
                            store.reindex(bookID: live.id)
                        }
                    } header: {
                        Text("Search Index")
                    } footer: {
                        Text("Rebuild if search results for this book look incomplete, or after turning on OCR in Settings.")
                    }
                }
            }
            .navigationTitle("Book Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.updateInfo(draft)
                        dismiss()
                    }
                }
            }
        }
    }
}
