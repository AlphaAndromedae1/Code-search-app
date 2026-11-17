import Foundation
import PDFKit
import SwiftUI
import UIKit

struct IndexProgress: Equatable {
    var done: Int
    var total: Int

    var fraction: Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 0
    }
}

/// Owns the library: books, bookmarks, cross-references, the search index,
/// and the background indexing queue.
@MainActor
@Observable
final class LibraryStore {
    private(set) var books: [Book] = []
    private(set) var bookmarks: [Bookmark] = []
    private(set) var crossRefs: [CrossReference] = []
    private(set) var indexing: [UUID: IndexProgress] = [:]
    private(set) var importsInFlight = 0
    private(set) var importResults: [ImportResult] = []
    private(set) var importLog: [String] = []
    var alertMessage: String?

    /// One library for the whole app (the background refresh task uses it too).
    static let shared = LibraryStore()

    let index: SearchIndex

    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var activeIndexID: UUID?
    @ObservationIgnored private var reindexAfterCancel: Set<UUID> = []
    /// Books paused so a code book could be indexed first; they go back in the queue.
    @ObservationIgnored private var preempted: Set<UUID> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var lastProgressUpdate = Date.distantPast
    @ObservationIgnored private var lastProgressSave = Date.distantPast

    @ObservationIgnored private var watcher: DocumentsWatcher?
    @ObservationIgnored private var scanDebounce: Task<Void, Never>?
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var rescanRequested = false
    /// Sizes seen on the previous scan, so a file still being copied in isn't read half-written.
    @ObservationIgnored private var pendingSizes: [String: Int64] = [:]

    private let labelDocuments = NSCache<NSUUID, PDFDocument>()
    private let thumbnails = NSCache<NSUUID, UIImage>()

    init() {
        let indexPath = AppPaths.indexFile.path
        if let opened = try? SearchIndex(path: indexPath) {
            index = opened
        } else {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: indexPath + suffix)
            }
            if let fresh = try? SearchIndex(path: indexPath) {
                index = fresh
            } else {
                index = try! SearchIndex(path: ":memory:")
            }
        }

        let data = LibraryStore.loadData()
        books = data.books
        bookmarks = data.bookmarks
        crossRefs = data.crossRefs

        if let saved = try? String(contentsOf: AppPaths.importLogFile, encoding: .utf8) {
            importLog = saved.components(separatedBy: "\n").filter { !$0.isEmpty }
        }

        labelDocuments.countLimit = 6
        thumbnails.countLimit = 300

        DocumentsFolder.prepare()
        moveExistingFilesIntoDocuments()

        watcher = DocumentsWatcher { [weak self] in
            self?.documentsChanged()
        }
        watcher?.start()

        Task {
            await self.reconcileIndex()
            await self.scanDocumentsFolder()
        }
    }

    // MARK: - Persistence

    private static func loadData() -> LibraryData {
        let url = AppPaths.libraryFile
        guard let data = try? Data(contentsOf: url) else { return LibraryData() }
        do {
            return try JSONDecoder().decode(LibraryData.self, from: data)
        } catch {
            // Keep the unreadable file instead of overwriting it.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = AppPaths.root.appendingPathComponent("library-unreadable-\(stamp).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            return LibraryData()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = LibraryData(books: books, bookmarks: bookmarks, crossRefs: crossRefs)
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: AppPaths.libraryFile, options: .atomic)
        } catch {
            alertMessage = "Couldn't save your library: \(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    // MARK: - Lookup

    func book(id: UUID) -> Book? {
        books.first { $0.id == id }
    }

    func fileURL(for book: Book) -> URL {
        if book.inDocuments {
            return DocumentsFolder.root.appendingPathComponent(book.fileName)
        }
        return AppPaths.books.appendingPathComponent(book.fileName)
    }

    /// A fresh PDFDocument for display. Each on-screen PDFView gets its own instance.
    func openDocument(bookID: UUID) -> PDFDocument? {
        guard let found = self.book(id: bookID) else { return nil }
        guard let document = PDFDocument(url: fileURL(for: found)) else { return nil }
        if document.isLocked {
            _ = document.unlock(withPassword: "")
        }
        return document
    }

    /// "p. 3-12 · PDF 88" when the PDF has printed page labels, otherwise "Page 88".
    func pageDescription(bookID: UUID, pageIndex: Int) -> String {
        let human = "\(pageIndex + 1)"
        guard let document = labelDocument(bookID),
              pageIndex >= 0, pageIndex < document.pageCount,
              let label = document.page(at: pageIndex)?.label?.trimmingCharacters(in: .whitespaces),
              !label.isEmpty, label != human
        else { return "Page \(human)" }
        return "p. \(label) · PDF \(human)"
    }

    func describe(_ ref: PageRef) -> String {
        let name = self.book(id: ref.bookID)?.displayName ?? "Removed book"
        return "\(name) — \(pageDescription(bookID: ref.bookID, pageIndex: ref.pageIndex))"
    }

    func shortDescribe(_ ref: PageRef) -> String {
        let name = self.book(id: ref.bookID)?.displayName ?? "Removed book"
        return "\(name) p.\(ref.pageIndex + 1)"
    }

    private func labelDocument(_ id: UUID) -> PDFDocument? {
        if let cached = labelDocuments.object(forKey: id as NSUUID) { return cached }
        guard let document = openDocument(bookID: id) else { return nil }
        labelDocuments.setObject(document, forKey: id as NSUUID)
        return document
    }

    func thumbnail(for book: Book) async -> UIImage? {
        let key = book.id as NSUUID
        if let cached = thumbnails.object(forKey: key) { return cached }
        let url = fileURL(for: book)
        let data = await Task.detached(priority: .utility) { () -> Data? in
            guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
            return page.thumbnail(of: CGSize(width: 132, height: 176), for: .cropBox).pngData()
        }.value
        guard let data, let image = UIImage(data: data) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    func storageSummary() -> (books: Int64, index: Int64) {
        let pdfBytes = books.reduce(Int64(0)) { $0 + $1.fileSize }
        var indexBytes: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: AppPaths.indexFile.path + suffix)
            indexBytes += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return (books: pdfBytes, index: indexBytes)
    }

    // MARK: - Importing

    /// - Parameter manual: when importing a manufacturer's manual, the details entered for it.
    /// Shown at the top of the Library after an import, so the outcome is always visible.
    struct ImportResult: Identifiable, Equatable {
        let id = UUID()
        let fileName: String
        let succeeded: Bool
        let message: String
    }

    /// - Parameter manual: when importing a manufacturer's manual, the details entered for it.
    func importPDFs(from urls: [URL], manual: ManualInfo? = nil) async {
        guard !urls.isEmpty else {
            logImport("The file picker returned no files")
            return
        }
        importResults = []
        importsInFlight += urls.count
        logImport("Importing \(urls.count) file(s)")

        for url in urls {
            let name = url.lastPathComponent
            if DocumentsFolder.contains(url) {
                // Already in On My iPhone › CodeShelf: the folder scan adds it without a second copy.
                importsInFlight -= 1
                logImport("\(name): already in the CodeShelf folder — scanning instead of copying")
                await scanDocumentsFolder()
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            logImport("\(name): starting (security-scoped access: \(scoped ? "yes" : "no"))")
            let (result, steps) = await Task.detached(priority: .userInitiated) { () -> (Result<Book, Error>, [String]) in
                var collected: [String] = []
                do {
                    let book = try LibraryFiles.copyIntoLibrary(url) { collected.append($0) }
                    return (.success(book), collected)
                } catch {
                    return (.failure(error), collected)
                }
            }.value
            for step in steps { logImport("\(name): \(step)") }
            if scoped { url.stopAccessingSecurityScopedResource() }
            if url.path.contains("/Inbox/") {
                try? FileManager.default.removeItem(at: url)
            }
            importsInFlight -= 1

            switch result {
            case .success(let book):
                if let existing = books.first(where: { $0.fileSize > 0 && $0.fileSize == book.fileSize && $0.pageCount == book.pageCount }) {
                    try? FileManager.default.removeItem(at: fileURL(for: book))
                    let message = "Already in your library as “\(existing.displayName)”."
                    importResults.append(ImportResult(fileName: name, succeeded: false, message: message))
                    logImport("\(name): skipped — \(message)")
                } else {
                    var added = book
                    manual?.apply(to: &added)
                    adoptIntoDocuments(&added)
                    books.append(added)
                    enqueueIndexing(added.id)
                    let message = "Added as “\(added.displayName)” (\(added.pageCount) pages) under \(added.category.label). Indexing it for search now."
                    importResults.append(ImportResult(fileName: name, succeeded: true, message: message))
                    logImport("\(name): added (\(added.pageCount) pages, \(added.category.label))")
                }
            case .failure(let error):
                importResults.append(ImportResult(fileName: name, succeeded: false, message: error.localizedDescription))
                logImport("\(name): FAILED — \(error.localizedDescription)")
            }
        }
        saveNow()
    }

    /// The file picker itself reported an error.
    func reportPickerFailure(_ error: Error) {
        importResults = [ImportResult(fileName: "File picker", succeeded: false, message: error.localizedDescription)]
        logImport("File picker error: \(error.localizedDescription)")
    }

    func dismissImportResults() {
        importResults = []
    }

    func logImport(_ line: String) {
        let stamp = Date().formatted(date: .abbreviated, time: .standard)
        importLog.append("\(stamp)  \(line)")
        if importLog.count > 300 { importLog.removeFirst(importLog.count - 300) }
        try? importLog.joined(separator: "\n").write(to: AppPaths.importLogFile, atomically: true, encoding: .utf8)
    }

    func clearImportLog() {
        importLog = []
        try? FileManager.default.removeItem(at: AppPaths.importLogFile)
    }

    // MARK: - Pages saved from the web

    /// Normalized form of a web address for matching ("…/chapter_10/#x" == "…/chapter_10").
    static func sourceKey(_ address: String) -> String {
        var key = address
        if let hash = key.firstIndex(of: "#") { key = String(key[..<hash]) }
        while key.hasSuffix("/") { key.removeLast() }
        return key.lowercased()
    }

    func book(sourceURL url: URL?) -> Book? {
        guard let url else { return nil }
        let key = LibraryStore.sourceKey(url.absoluteString)
        return books.first { !$0.sourceURL.isEmpty && LibraryStore.sourceKey($0.sourceURL) == key }
    }

    /// Adds a PDF made from a web page (or downloaded from one), or replaces an earlier copy
    /// while keeping its bookmarks and cross-references.
    func addWebBook(
        pdfData: Data,
        title: String,
        shortName: String,
        category: CodeCategory,
        jurisdiction: String,
        sourceURL: String,
        replacing existingID: UUID?,
        manual: ManualInfo? = nil,
        sourceVersion: String = ""
    ) async -> Bool {
        let written = await Task.detached(priority: .userInitiated) { () -> Result<LibraryFiles.WrittenFile, Error> in
            do {
                return .success(try LibraryFiles.writePDF(pdfData))
            } catch {
                return .failure(error)
            }
        }.value

        let file: LibraryFiles.WrittenFile
        switch written {
        case .success(let value):
            file = value
        case .failure(let error):
            alertMessage = "Couldn't save the page: \(error.localizedDescription)"
            return false
        }

        let retrieved = (sourceURL.isEmpty ? "Added " : "Retrieved ") + Date().formatted(date: .abbreviated, time: .omitted)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existingID, let i = books.firstIndex(where: { $0.id == existingID }) {
            let oldFile = fileURL(for: books[i])
            books[i].inDocuments = false
            books[i].fileName = file.fileName
            books[i].fileSize = file.fileSize
            books[i].pageCount = file.pageCount
            books[i].indexedPages = 0
            books[i].ocrPages = 0
            books[i].textPages = -1
            books[i].lastPage = min(books[i].lastPage, max(0, file.pageCount - 1))
            books[i].edition = retrieved
            books[i].sourceURL = sourceURL
            books[i].sourceVersion = sourceVersion
            if !cleanTitle.isEmpty { books[i].title = cleanTitle }
            books[i].shortName = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
            books[i].jurisdiction = jurisdiction.trimmingCharacters(in: .whitespacesAndNewlines)
            books[i].category = category
            if let manual {
                books[i].modelNumbers = manual.models.trimmingCharacters(in: .whitespaces)
                books[i].equipmentType = manual.equipmentType
            }
            try? FileManager.default.removeItem(at: oldFile)
            var replaced = books[i]
            adoptIntoDocuments(&replaced)
            books[i] = replaced
            labelDocuments.removeObject(forKey: existingID as NSUUID)
            thumbnails.removeObject(forKey: existingID as NSUUID)
            if activeIndexID == existingID {
                reindexAfterCancel.insert(existingID)
                indexTask?.cancel()
            } else {
                enqueueIndexing(existingID)
            }
        } else {
            var book = Book(title: cleanTitle.isEmpty ? "Saved Page" : cleanTitle, fileName: file.fileName)
            book.id = file.id
            book.shortName = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
            book.category = category
            book.jurisdiction = jurisdiction.trimmingCharacters(in: .whitespacesAndNewlines)
            book.edition = retrieved
            book.sourceURL = sourceURL
            book.sourceVersion = sourceVersion
            book.pageCount = file.pageCount
            book.fileSize = file.fileSize
            if let manual {
                book.modelNumbers = manual.models.trimmingCharacters(in: .whitespaces)
                book.equipmentType = manual.equipmentType
            }
            adoptIntoDocuments(&book)
            books.append(book)
            enqueueIndexing(book.id)
        }
        saveNow()
        return true
    }

    var bulletinBookIDs: Set<UUID> {
        Set(books.filter { $0.category == .bulletin }.map(\.id))
    }

    /// Code names in the library ("OESC", "OBC", "NBC"…) used to rank new bulletins.
    var libraryTerms: [String] {
        var terms: [String] = []
        for book in books where book.category != .bulletin {
            let first = book.shortName.split(separator: " ").first.map(String.init) ?? ""
            let candidate = first.uppercased()
            guard candidate.count >= 2 && candidate.count <= 8 && candidate.contains(where: { $0.isLetter }) else { continue }
            // "B149.1" also matches bulletins that just say "B149".
            var variants = [candidate]
            if let dot = candidate.firstIndex(of: "."), candidate.distance(from: candidate.startIndex, to: dot) >= 3 {
                variants.append(String(candidate[..<dot]))
            }
            for variant in variants where !terms.contains(variant) {
                terms.append(variant)
            }
        }
        return terms
    }

    // MARK: - Editing books

    func updateInfo(_ edited: Book) {
        guard let i = books.firstIndex(where: { $0.id == edited.id }) else { return }
        let title = edited.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { books[i].title = title }
        books[i].shortName = edited.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        books[i].category = edited.category
        books[i].jurisdiction = edited.jurisdiction.trimmingCharacters(in: .whitespacesAndNewlines)
        books[i].edition = edited.edition.trimmingCharacters(in: .whitespacesAndNewlines)
        books[i].notes = edited.notes
        books[i].modelNumbers = edited.modelNumbers.trimmingCharacters(in: .whitespacesAndNewlines)
        books[i].equipmentType = edited.equipmentType
        scheduleSave()
    }

    func setLastPage(bookID: UUID, page: Int) {
        guard let i = books.firstIndex(where: { $0.id == bookID }), books[i].lastPage != page else { return }
        books[i].lastPage = page
        scheduleSave()
    }

    /// Deletes the book and its PDF (also from Files › On My iPhone › CodeShelf).
    func delete(_ book: Book) {
        removeFromLibrary(book, deleteFile: true)
    }

    private func removeFromLibrary(_ book: Book, deleteFile: Bool) {
        let id = book.id
        if activeIndexID == id { indexTask?.cancel() }
        queue.removeAll { $0 == id }
        reindexAfterCancel.remove(id)
        books.removeAll { $0.id == id }
        bookmarks.removeAll { $0.bookID == id }
        crossRefs = crossRefs.compactMap { reference in
            var updated = reference
            updated.refs.removeAll { $0.bookID == id }
            return updated.refs.isEmpty ? nil : updated
        }
        indexing[id] = nil
        labelDocuments.removeObject(forKey: id as NSUUID)
        thumbnails.removeObject(forKey: id as NSUUID)
        if deleteFile {
            try? FileManager.default.removeItem(at: fileURL(for: book))
        }
        saveNow()
        let index = self.index
        Task { await index.deleteBook(id) }
    }

    // MARK: - Files app folder (On My iPhone › CodeShelf)

    /// Moves a PDF the app just added from private staging into its category folder in Documents.
    private func adoptIntoDocuments(_ book: inout Book) {
        guard !book.inDocuments else { return }
        let source = AppPaths.books.appendingPathComponent(book.fileName)
        let target = DocumentsFolder.destination(for: book.title, category: book.category)
        do {
            try FileManager.default.moveItem(at: source, to: target.url)
            book.fileName = target.path
            book.inDocuments = true
        } catch {
            logImport("Couldn't move “\(book.title)” into the Files folder: \(error.localizedDescription)")
        }
    }

    /// One-time move of PDFs stored privately by earlier versions, so Files shows the whole library.
    private func moveExistingFilesIntoDocuments() {
        var moved = 0
        for i in books.indices where !books[i].inDocuments {
            guard FileManager.default.fileExists(atPath: AppPaths.books.appendingPathComponent(books[i].fileName).path) else { continue }
            var book = books[i]
            adoptIntoDocuments(&book)
            if book.inDocuments {
                books[i] = book
                moved += 1
            }
        }
        if moved > 0 {
            logImport("Moved \(moved) PDF(s) into Files › On My iPhone › CodeShelf")
            saveNow()
        }
    }

    private static let rejectedKey = "rejectedDocumentsFiles"

    /// Files in the folder that couldn't be imported (path -> size|modified), so they aren't retried every scan.
    private var rejectedFiles: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: LibraryStore.rejectedKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: LibraryStore.rejectedKey) }
    }

    private func documentsChanged() {
        scanDebounce?.cancel()
        scanDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self else { return }
            self.watcher?.start()
            await self.scanDocumentsFolder()
        }
    }

    /// Picks up PDFs added, moved, replaced or deleted in Files › On My iPhone › CodeShelf.
    func scanDocumentsFolder() async {
        if isScanning {
            rescanRequested = true
            return
        }
        isScanning = true
        defer { isScanning = false }
        repeat {
            rescanRequested = false
            let unstable = await performDocumentsScan()
            if unstable {
                // Something is still being copied in; look again shortly.
                try? await Task.sleep(for: .milliseconds(1500))
                rescanRequested = true
            }
        } while rescanRequested
    }

    /// - Returns: true if a file was still changing size and needs another look.
    private func performDocumentsScan() async -> Bool {
        let entries = await Task.detached(priority: .utility) { DocumentsFolder.listPDFs() }.value
        let present = Set(entries.map(\.path))
        var rejected = rejectedFiles.filter { present.contains($0.key) }
        var unstable = false
        var changed = false

        // Books whose PDF has disappeared from its place (deleted, moved or renamed in Files).
        var missing = books.filter { book in
            book.inDocuments && !present.contains(book.fileName)
                && !FileManager.default.fileExists(atPath: fileURL(for: book).path)
        }

        // PDFs replaced in place (same name, different file): re-read them.
        var replacedIDs: [UUID] = []
        for entry in entries {
            guard let book = books.first(where: { $0.inDocuments && $0.fileName == entry.path }),
                  book.fileSize > 0, entry.size != book.fileSize
            else { continue }
            if pendingSizes[entry.path] != entry.size {
                pendingSizes[entry.path] = entry.size
                unstable = true
                continue
            }
            pendingSizes[entry.path] = nil
            replacedIDs.append(book.id)
        }
        for id in replacedIDs {
            guard let i = books.firstIndex(where: { $0.id == id }) else { continue }
            let url = fileURL(for: books[i])
            let pages = await Task.detached(priority: .utility) { PDFDocument(url: url)?.pageCount ?? 0 }.value
            guard let j = books.firstIndex(where: { $0.id == id }), pages > 0 else { continue }
            books[j].pageCount = pages
            books[j].fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? books[j].fileSize
            books[j].lastPage = min(books[j].lastPage, pages - 1)
            labelDocuments.removeObject(forKey: id as NSUUID)
            thumbnails.removeObject(forKey: id as NSUUID)
            logImport("\(books[j].fileName): file was replaced in Files — re-indexing")
            reindex(bookID: id)
            changed = true
        }

        // New PDFs.
        let known = Set(books.filter(\.inDocuments).map(\.fileName))
        for entry in entries where !known.contains(entry.path) {
            let signature = "\(entry.size)|\(Int(entry.modified.timeIntervalSince1970))"
            if rejected[entry.path] == signature { continue }

            // Moved or renamed in Files: same size as a book whose file disappeared. Keeps bookmarks and links.
            if let m = missing.firstIndex(where: { $0.fileSize == entry.size }),
               let i = books.firstIndex(where: { $0.id == missing[m].id }) {
                let oldTitle = DocumentsFolder.title(fromPath: books[i].fileName)
                books[i].fileName = entry.path
                if books[i].title == oldTitle {
                    books[i].title = DocumentsFolder.title(fromPath: entry.path)
                }
                labelDocuments.removeObject(forKey: books[i].id as NSUUID)
                missing.remove(at: m)
                logImport("\(entry.path): matched to “\(books[i].displayName)” (moved or renamed in Files)")
                changed = true
                continue
            }

            // Wait until the file stops growing — Files may still be copying it in.
            if pendingSizes[entry.path] != entry.size {
                pendingSizes[entry.path] = entry.size
                unstable = true
                continue
            }
            pendingSizes[entry.path] = nil

            logImport("\(entry.path): new PDF in the CodeShelf folder")
            let url = DocumentsFolder.root.appendingPathComponent(entry.path)
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Book, Error> in
                do {
                    return .success(try LibraryFiles.inspectInPlace(url))
                } catch {
                    return .failure(error)
                }
            }.value

            switch result {
            case .success(var book):
                book.fileName = entry.path
                book.inDocuments = true
                book.fileSize = entry.size
                if let hint = DocumentsFolder.categoryHint(forPath: entry.path) {
                    book.category = hint
                    if hint == .manufacturer { book.shortName = "" }
                }
                if books.contains(where: { $0.inDocuments && $0.fileName == entry.path }) { continue }
                if let existing = books.first(where: { $0.fileSize > 0 && $0.fileSize == book.fileSize && $0.pageCount == book.pageCount }) {
                    rejected[entry.path] = signature
                    let message = "Same file as “\(existing.displayName)”, which is already in your library. You can delete this copy in Files."
                    importResults.append(ImportResult(fileName: entry.path, succeeded: false, message: message))
                    logImport("\(entry.path): skipped — duplicate of “\(existing.displayName)”")
                    continue
                }
                books.append(book)
                enqueueIndexing(book.id)
                importResults.append(ImportResult(
                    fileName: entry.path,
                    succeeded: true,
                    message: "Added from the Files folder as “\(book.displayName)” (\(book.pageCount) pages) under \(book.category.label). Indexing it for search now."
                ))
                logImport("\(entry.path): added (\(book.pageCount) pages, \(book.category.label))")
                changed = true
            case .failure(let error):
                rejected[entry.path] = signature
                importResults.append(ImportResult(fileName: entry.path, succeeded: false, message: error.localizedDescription))
                logImport("\(entry.path): FAILED — \(error.localizedDescription)")
            }
        }

        // PDFs deleted in Files leave the library too (only once nothing is mid-copy, so renames aren't mistaken for deletes).
        if !unstable {
            for book in missing {
                guard let current = self.book(id: book.id), current.inDocuments,
                      !FileManager.default.fileExists(atPath: fileURL(for: current).path)
                else { continue }
                removeFromLibrary(current, deleteFile: false)
                importResults.append(ImportResult(
                    fileName: current.fileName,
                    succeeded: true,
                    message: "Removed “\(current.displayName)” from the library — its PDF was deleted in Files."
                ))
                logImport("\(current.fileName): deleted in Files — removed from the library")
                changed = true
            }
        }

        rejectedFiles = rejected
        if changed { saveNow() }
        return unstable
    }

    // MARK: - Indexing queue

    var hasPendingIndexing: Bool {
        books.contains { !$0.isIndexed }
    }

    func enqueueIndexing(_ id: UUID) {
        guard activeIndexID != id, !queue.contains(id) else { return }
        queue.append(id)
        prioritizeQueue()
        startNextIndexJob()
    }

    /// Code books are indexed first, then bulletins, then manufacturer instructions, so a
    /// batch of downloaded manuals never keeps a code book you just added out of Search.
    private func indexPriority(_ id: UUID) -> Int {
        guard let book = book(id: id) else { return SearchTier.allCases.count }
        return SearchTier.of(book.category).rawValue
    }

    private func prioritizeQueue() {
        var arrival: [UUID: Int] = [:]
        for (position, id) in queue.enumerated() where arrival[id] == nil {
            arrival[id] = position
        }
        queue.sort { lhs, rhs in
            let left = (indexPriority(lhs), arrival[lhs] ?? 0)
            let right = (indexPriority(rhs), arrival[rhs] ?? 0)
            return left < right
        }
        // A manual that's part-way through pauses (and resumes later) when a code book is waiting.
        if let active = activeIndexID, let next = queue.first,
           indexPriority(next) < indexPriority(active), !preempted.contains(active) {
            preempted.insert(active)
            indexTask?.cancel()
        }
    }

    /// Code books (not manuals or bulletins) whose pages aren't all searchable yet.
    var codeBooksStillIndexing: [Book] {
        books.filter { SearchTier.of($0.category) == .codes && !$0.isIndexed }
    }

    func reindex(bookID: UUID) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        if activeIndexID == bookID {
            reindexAfterCancel.insert(bookID)
            indexTask?.cancel()
            return
        }
        books[i].indexedPages = 0
        books[i].ocrPages = 0
        books[i].textPages = -1
        saveNow()
        enqueueIndexing(bookID)
    }

    /// Re-reads every page of a book with OCR instead of the PDF's own (scrambled) text.
    func rereadWithOCR(bookID: UUID, enabled: Bool = true) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].forceOCR = enabled
        reindex(bookID: bookID)
    }

    func reindexAll() {
        for book in books {
            reindex(bookID: book.id)
        }
    }

    private func startNextIndexJob() {
        guard indexTask == nil else { return }
        while let next = queue.first {
            queue.removeFirst()
            guard let found = self.book(id: next), !found.isIndexed else { continue }
            begin(found)
            return
        }
        endBackgroundTask()
    }

    private func begin(_ book: Book) {
        let id = book.id
        activeIndexID = id
        indexing[id] = IndexProgress(done: book.indexedPages, total: book.pageCount)
        beginBackgroundTaskIfNeeded()

        let url = fileURL(for: book)
        let start = book.indexedPages
        let startOCR = book.ocrPages
        let ocr = AppSettings.ocrEnabled
        let forceOCR = book.forceOCR
        let index = self.index

        let report: @Sendable (Int, Int) async -> Void = { [weak self] done, ocrPages in
            await self?.indexingProgress(id: id, done: done, ocrPages: ocrPages)
        }

        indexTask = Task.detached(priority: .utility) { [weak self] in
            let outcome = await Indexer.run(
                bookID: id,
                url: url,
                startPage: start,
                startOCRCount: startOCR,
                ocrEnabled: ocr,
                forceOCR: forceOCR,
                index: index,
                progress: report
            )
            await self?.indexingFinished(id: id, outcome: outcome)
        }
    }

    private func indexingProgress(id: UUID, done: Int, ocrPages: Int) {
        // Throttle UI updates; the final state is applied in indexingFinished.
        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdate) > 0.3 else { return }
        lastProgressUpdate = now
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].indexedPages = done
        books[i].ocrPages = ocrPages
        indexing[id] = IndexProgress(done: done, total: books[i].pageCount)
        if now.timeIntervalSince(lastProgressSave) > 5 {
            lastProgressSave = now
            saveNow()
        }
    }

    private func indexingFinished(id: UUID, outcome: Indexer.Outcome) {
        indexTask = nil
        activeIndexID = nil
        indexing[id] = nil

        if let i = books.firstIndex(where: { $0.id == id }) {
            switch outcome {
            case .completed(let ocrPages):
                books[i].indexedPages = books[i].pageCount
                books[i].ocrPages = ocrPages
                let index = self.index
                Task { [weak self] in
                    let textPages = await index.textPageCount(bookID: id)
                    guard let self, let j = self.books.firstIndex(where: { $0.id == id }) else { return }
                    self.books[j].textPages = textPages
                    self.saveNow()
                }
            case .cancelled:
                if preempted.contains(id) && reindexAfterCancel.contains(id) == false {
                    queue.append(id)
                }
            case .failed(let message):
                alertMessage = "Couldn't index “\(books[i].displayName)”: \(message)"
                books[i].indexedPages = books[i].pageCount
            }
            if reindexAfterCancel.remove(id) != nil {
                books[i].indexedPages = 0
                books[i].ocrPages = 0
                books[i].textPages = -1
                queue.insert(id, at: 0)
            }
        } else {
            // Book was deleted mid-index; make sure no stray rows remain.
            let index = self.index
            Task { await index.deleteBook(id) }
        }

        preempted.remove(id)
        prioritizeQueue()
        saveNow()
        startNextIndexJob()
    }

    /// Makes the stored index and library.json agree after a crash or restore.
    private func reconcileIndex() async {
        let counts = await index.pageCountsByBook()
        var changed = false
        for i in books.indices {
            let stored = counts[books[i].id] ?? 0
            if books[i].indexedPages > 0 && stored == 0 {
                books[i].indexedPages = 0
                books[i].ocrPages = 0
                books[i].textPages = -1
                changed = true
            }
        }
        let known = Set(books.map(\.id))
        for id in counts.keys where !known.contains(id) {
            await index.deleteBook(id)
        }
        // Books indexed by older versions: find out whether they hold any searchable text.
        let unknown = books.filter { $0.isIndexed && $0.textPages < 0 }.map(\.id)
        for id in unknown {
            let textPages = await index.textPageCount(bookID: id)
            if let i = books.firstIndex(where: { $0.id == id }) {
                books[i].textPages = textPages
                changed = true
            }
        }
        if changed { saveNow() }
        for book in books where !book.isIndexed {
            enqueueIndexing(book.id)
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Indexing code books") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - Bookmarks

    func bookmark(bookID: UUID, page: Int) -> Bookmark? {
        bookmarks.first { $0.bookID == bookID && $0.pageIndex == page }
    }

    func saveBookmark(_ bookmark: Bookmark) {
        if let i = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[i] = bookmark
        } else {
            bookmarks.append(bookmark)
        }
        scheduleSave()
    }

    func deleteBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: - Cross-references

    func crossRefs(containing ref: PageRef) -> [CrossReference] {
        crossRefs.filter { $0.refs.contains(ref) }
    }

    @discardableResult
    func createCrossRef(title: String, note: String, refs: [PageRef]) -> UUID {
        var seen = Set<PageRef>()
        let unique = refs.filter { seen.insert($0).inserted }
        let reference = CrossReference(title: title, note: note, refs: unique)
        crossRefs.insert(reference, at: 0)
        scheduleSave()
        return reference.id
    }

    func addPages(_ refs: [PageRef], toCrossRef id: UUID) {
        guard let i = crossRefs.firstIndex(where: { $0.id == id }) else { return }
        for ref in refs where !crossRefs[i].refs.contains(ref) {
            crossRefs[i].refs.append(ref)
        }
        scheduleSave()
    }

    func updateCrossRef(id: UUID, title: String?, note: String?) {
        guard let i = crossRefs.firstIndex(where: { $0.id == id }) else { return }
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { crossRefs[i].title = trimmed }
        }
        if let note { crossRefs[i].note = note }
        scheduleSave()
    }

    func removePages(at offsets: IndexSet, fromCrossRef id: UUID) {
        guard let i = crossRefs.firstIndex(where: { $0.id == id }) else { return }
        crossRefs[i].refs.remove(atOffsets: offsets)
        scheduleSave()
    }

    func deleteCrossRef(id: UUID) {
        crossRefs.removeAll { $0.id == id }
        scheduleSave()
    }
}
