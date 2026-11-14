import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// Keep the installation manual for each model you install: import a PDF,
/// scan the paper copy with the camera, or find it on the manufacturer's site.
struct ManufacturerInstructionsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var info = ManualInfo()
    @State private var showImporter = false
    @State private var showScanner = false
    @State private var isSaving = false
    @State private var message: String? = nil
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        EquipmentLibraryView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Fuel Equipment Library", systemImage: "shippingbox.fill")
                                .font(.headline)
                            Text("CSST, ULC S636 venting, propane regulators, relief valves, tanks & cylinders")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Downloaded from the manufacturers and kept up to date automatically.")
                }

                if store.importsInFlight > 0 || !store.importResults.isEmpty {
                    Section {
                        ImportResultsBanner()
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                Section {
                    TextField("Manufacturer (e.g. Carrier, Lennox, Beckett)", text: $info.manufacturer)
                        .textInputAutocapitalization(.words)
                    TextField("Model number(s)", text: $info.models, prompt: Text("e.g. 59SC5A080, 59SC5A100"))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Picker("Equipment", selection: $info.equipmentType) {
                        ForEach(ManualInfo.equipmentTypes, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                } header: {
                    Text("Equipment")
                } footer: {
                    Text("Codes such as CSA B149.1 and B139 refer to the manufacturer's certified installation instructions, so keep the manual for the exact model you install.")
                }

                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import PDF", systemImage: "doc.badge.plus")
                    }
                    if VNDocumentCameraViewController.isSupported {
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan Paper Instructions", systemImage: "doc.viewfinder")
                        }
                    }
                    NavigationLink(value: BrowserRoute(url: WebLinks.webSearch(searchQuery), purpose: .manual(info))) {
                        Label("Find Online", systemImage: "globe")
                    }
                    .disabled(info.isEmpty)
                } header: {
                    Text("Add the Instructions")
                } footer: {
                    Text("Scanned pages are read with on-device text recognition so they can be searched. Online, open the manufacturer's PDF and tap Save.")
                }

                if isSaving {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Saving…")
                        }
                    }
                }

                if let message {
                    Section {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if !manuals.isEmpty {
                    Section {
                        ForEach(filteredManuals) { book in
                            NavigationLink(value: ReaderRoute(bookID: book.id, pageIndex: book.lastPage)) {
                                ManualRow(book: book)
                            }
                        }
                    } header: {
                        Text("Your Manuals (\(manuals.count))")
                    }
                }
            }
            .searchable(text: $filter, prompt: "Find a manual by manufacturer or model")
            .navigationTitle("Manufacturer Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { await importFiles(urls) }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner { images in
                    showScanner = false
                    Task { await saveScan(images) }
                } onCancel: {
                    showScanner = false
                }
                .ignoresSafeArea()
            }
            .navigationDestination(for: BrowserRoute.self) { route in
                WebCodeBrowser(route: route)
            }
            .navigationDestination(for: ReaderRoute.self) { route in
                ReaderView(route: route)
            }
        }
    }

    private var searchQuery: String {
        let firstModel = info.models.split(whereSeparator: { $0 == "," || $0 == ";" }).first.map(String.init) ?? ""
        return "\(info.manufacturer) \(firstModel) \(info.equipmentType) installation manual pdf"
    }

    private var manuals: [Book] {
        store.books
            .filter { $0.category == .manufacturer }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var filteredManuals: [Book] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return manuals }
        return manuals.filter { book in
            [book.title, book.shortName, book.jurisdiction, book.modelNumbers, book.equipmentType]
                .contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    private func importFiles(_ urls: [URL]) async {
        isSaving = true
        message = nil
        let before = store.books.count
        await store.importPDFs(from: urls, manual: info)
        isSaving = false
        let added = store.books.count - before
        if added > 0 {
            message = "Added \(added) manual\(added == 1 ? "" : "s") to your library."
        }
    }

    private func saveScan(_ images: [UIImage]) async {
        guard !images.isEmpty else { return }
        isSaving = true
        message = nil
        let data = await Task.detached(priority: .userInitiated) {
            ScanPDF.make(from: images)
        }.value
        guard let data else {
            isSaving = false
            store.alertMessage = "Couldn't create a PDF from the scan."
            return
        }
        let title = info.title.isEmpty
            ? "Scanned instructions \(Date().formatted(date: .abbreviated, time: .shortened))"
            : info.title
        let saved = await store.addWebBook(
            pdfData: data,
            title: title,
            shortName: info.shortName,
            category: .manufacturer,
            jurisdiction: info.manufacturer.trimmingCharacters(in: .whitespaces),
            sourceURL: "",
            replacing: nil,
            manual: info
        )
        isSaving = false
        if saved {
            message = "Scan saved (\(images.count) page\(images.count == 1 ? "" : "s")). Its text is being recognized for search now."
        }
    }
}

private struct ManualRow: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(book.displayName)
                .font(.body.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if !book.equipmentType.isEmpty { parts.append(book.equipmentType) }
        if !book.modelNumbers.isEmpty { parts.append("Models: \(book.modelNumbers)") }
        parts.append("\(book.pageCount) pages")
        return parts.joined(separator: " · ")
    }
}

/// Apple's document camera (edge detection, perspective correction, multi-page).
struct DocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(onFinish: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var images: [UIImage] = []
            for index in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: index))
            }
            onFinish(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }
    }
}

/// Turns scanned page images into a PDF.
enum ScanPDF {
    static func make(from images: [UIImage]) -> Data? {
        let document = PDFDocument()
        for image in images {
            guard let page = PDFPage(image: downscaled(image)) else { continue }
            document.insert(page, at: document.pageCount)
        }
        guard document.pageCount > 0 else { return nil }
        return document.dataRepresentation()
    }

    /// Keeps file sizes reasonable while staying sharp enough for text recognition.
    private static func downscaled(_ image: UIImage, maxSide: CGFloat = 2200) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
