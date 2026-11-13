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
    var alertMessage: String?

    let index: SearchIndex

    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var activeIndexID: UUID?
    @ObservationIgnored private var reindexAfterCancel: Set<UUID> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var lastProgressUpdate = Date.distantPast
    @ObservationIgnored private var lastProgressSave = Date.distantPast

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

        labelDocuments.countLimit = 6
        thumbnails.countLimit = 300

        Task { await self.reconcileIndex() }
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
        AppPaths.books.appendingPathComponent(book.fileName)
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
    func importPDFs(from urls: [URL], manual: ManualInfo? = nil) async {
        guard !urls.isEmpty else { return }
        importsInFlight += urls.count
        var problems: [String] = []

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Book, Error> in
                do {
                    return .success(try LibraryFiles.copyIntoLibrary(url))
                } catch {
                    return .failure(error)
                }
            }.value
            if scoped { url.stopAccessingSecurityScopedResource() }
            if url.path.contains("/Inbox/") {
                try? FileManager.default.removeItem(at: url)
            }
            importsInFlight -= 1

            switch result {
            case .success(let book):
                if let existing = books.first(where: { $0.fileSize > 0 && $0.fileSize == book.fileSize && $0.pageCount == book.pageCount }) {
                    try? FileManager.default.removeItem(at: fileURL(for: book))
                    problems.append("“\(url.lastPathComponent)” is already in your library as “\(existing.displayName)”.")
                } else {
                    var added = book
                    manual?.apply(to: &added)
                    books.append(added)
                    enqueueIndexing(added.id)
                }
            case .failure(let error):
                problems.append("“\(url.lastPathComponent)”: \(error.localizedDescription)")
            }
        }

        saveNow()
        if !problems.isEmpty {
            alertMessage = problems.joined(separator: "\n\n")
        }
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
        manual: ManualInfo? = nil
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
            books[i].fileName = file.fileName
            books[i].fileSize = file.fileSize
            books[i].pageCount = file.pageCount
            books[i].indexedPages = 0
            books[i].ocrPages = 0
            books[i].lastPage = min(books[i].lastPage, max(0, file.pageCount - 1))
            books[i].edition = retrieved
            books[i].sourceURL = sourceURL
            if !cleanTitle.isEmpty { books[i].title = cleanTitle }
            books[i].shortName = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
            books[i].jurisdiction = jurisdiction.trimmingCharacters(in: .whitespacesAndNewlines)
            books[i].category = category
            if let manual {
                books[i].modelNumbers = manual.models.trimmingCharacters(in: .whitespaces)
                books[i].equipmentType = manual.equipmentType
            }
            try? FileManager.default.removeItem(at: oldFile)
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
            book.pageCount = file.pageCount
            book.fileSize = file.fileSize
            if let manual {
                book.modelNumbers = manual.models.trimmingCharacters(in: .whitespaces)
                book.equipmentType = manual.equipmentType
            }
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

    func delete(_ book: Book) {
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
        try? FileManager.default.removeItem(at: fileURL(for: book))
        saveNow()
        let index = self.index
        Task { await index.deleteBook(id) }
    }

    // MARK: - Indexing queue

    var hasPendingIndexing: Bool {
        books.contains { !$0.isIndexed }
    }

    func enqueueIndexing(_ id: UUID) {
        guard activeIndexID != id, !queue.contains(id) else { return }
        queue.append(id)
        startNextIndexJob()
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
        saveNow()
        enqueueIndexing(bookID)
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
            case .cancelled:
                break
            case .failed(let message):
                alertMessage = "Couldn't index “\(books[i].displayName)”: \(message)"
                books[i].indexedPages = books[i].pageCount
            }
            if reindexAfterCancel.remove(id) != nil {
                books[i].indexedPages = 0
                books[i].ocrPages = 0
                queue.insert(id, at: 0)
            }
        } else {
            // Book was deleted mid-index; make sure no stray rows remain.
            let index = self.index
            Task { await index.deleteBook(id) }
        }

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
                changed = true
            }
        }
        let known = Set(books.map(\.id))
        for id in counts.keys where !known.contains(id) {
            await index.deleteBook(id)
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
