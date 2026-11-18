import Foundation
import PDFKit
import UIKit
import Vision

/// Extracts text from every page of a PDF (falling back to on-device OCR for
/// scanned pages) and writes it into the search index.
enum Indexer {
    enum Outcome: Sendable {
        case completed(ocrPages: Int)
        case cancelled
        case failed(String)
    }

    /// Pages read with OCR at the same time. Text recognition runs on the Neural Engine and GPU,
    /// so a few pages in flight keep it busy while the next pages are rendered.
    private static var ocrWorkers: Int {
        min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    /// Long side of the page image handed to OCR. About 190 dpi for a letter page: plenty for
    /// code-book print, and much faster than rendering larger.
    private static let ocrPixels: CGFloat = 1700

    /// Runs on a background executor. Resumable: pass the number of pages already indexed.
    static func run(
        bookID: UUID,
        url: URL,
        startPage: Int,
        startOCRCount: Int,
        ocrEnabled: Bool,
        forceOCR: Bool = false,
        index: SearchIndex,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async -> Outcome {
        guard var document = openDocument(url) else {
            return .failed("The PDF could not be opened.")
        }
        let count = document.pageCount
        let first = max(0, startPage)

        // Clear anything past the resume point (e.g. a partial batch before the app quit).
        await index.deletePages(bookID: bookID, fromPage: first)

        var ocrCount = first == 0 ? 0 : startOCRCount
        var page = first
        var pagesSinceReopen = 0
        let workers = ocrWorkers

        while page < count {
            if Task.isCancelled { return .cancelled }
            // PDFKit keeps every page it has touched in memory; reopen periodically
            // so 1,000+ page code books don't pile up memory.
            if pagesSinceReopen >= 150, let fresh = openDocument(url) {
                document = fresh
                pagesSinceReopen = 0
            }

            // 1. Read each page's own text, and render the pages that need OCR (one thread: PDFKit isn't thread-safe).
            let chunkEnd = min(page + workers * 2, count)
            var texts: [Int: String] = [:]
            var renders: [PageImage] = []
            for pageIndex in page..<chunkEnd {
                autoreleasepool {
                    guard let pdfPage = document.page(at: pageIndex) else {
                        texts[pageIndex] = ""
                        return
                    }
                    let text = pdfPage.string ?? ""
                    texts[pageIndex] = text
                    if (forceOCR || (ocrEnabled && !hasMeaningfulText(text))), let image = render(pdfPage) {
                        renders.append(PageImage(page: pageIndex, image: image))
                    }
                }
            }
            pagesSinceReopen += chunkEnd - page

            // 2. Recognize the rendered pages in parallel.
            if !renders.isEmpty {
                let recognized = await recognize(renders, workers: workers, languageCorrection: !forceOCR)
                if Task.isCancelled { return .cancelled }
                for (pageIndex, ocrText) in recognized {
                    let own = texts[pageIndex] ?? ""
                    guard ocrText.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { continue }
                    if forceOCR {
                        // Keep the PDF's own words and add what's printed (e.g. clause numbers the text layer scrambles).
                        texts[pageIndex] = own.isEmpty ? ocrText : own + "\n" + ocrText
                        ocrCount += 1
                    } else if ocrText.count > own.count {
                        texts[pageIndex] = ocrText
                        ocrCount += 1
                    }
                }
            }

            // 3. Store the chunk in page order.
            let batch = (page..<chunkEnd).map { PageText(page: $0, text: texts[$0] ?? "") }
            if Task.isCancelled { return .cancelled }
            await index.insert(bookID: bookID, pages: batch)
            page = chunkEnd
            await progress(page, ocrCount)
        }
        await index.optimize()
        return .completed(ocrPages: ocrCount)
    }

    private static func openDocument(_ url: URL) -> PDFDocument? {
        guard let document = PDFDocument(url: url) else { return nil }
        if document.isLocked {
            _ = document.unlock(withPassword: "")
        }
        return document
    }

    /// At least 40 letters or digits: a page with real text, not a scan.
    private static func hasMeaningfulText(_ text: String) -> Bool {
        var meaningful = 0
        for scalar in text.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            meaningful += 1
            if meaningful >= 40 { return true }
        }
        return false
    }

    /// A rendered page image, passed to the recognition tasks.
    private struct PageImage: @unchecked Sendable {
        let page: Int
        let image: CGImage
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = ocrPixels / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox).cgImage
    }

    /// Runs text recognition on up to `workers` pages at a time.
    private static func recognize(_ pages: [PageImage], workers: Int, languageCorrection: Bool) async -> [(Int, String)] {
        await withTaskGroup(of: (Int, String)?.self) { group in
            var results: [(Int, String)] = []
            var waiting = pages.makeIterator()
            for _ in 0..<min(workers, pages.count) {
                guard let item = waiting.next() else { break }
                group.addTask { recognizePage(item, languageCorrection: languageCorrection) }
            }
            while let result = await group.next() {
                if let result { results.append(result) }
                if let item = waiting.next() {
                    group.addTask { recognizePage(item, languageCorrection: languageCorrection) }
                }
            }
            return results
        }
    }

    private static func recognizePage(_ item: PageImage, languageCorrection: Bool) -> (Int, String)? {
        guard !Task.isCancelled, let text = recognizeText(in: item.image, languageCorrection: languageCorrection) else { return nil }
        return (item.page, text)
    }

    /// Apple's on-device text recognition for one page image.
    private static func recognizeText(in image: CGImage, languageCorrection: Bool) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Off when reading clause numbers, so "4.7.4" isn't "corrected" into a word.
        request.usesLanguageCorrection = languageCorrection
        // Code books are English: skip language detection, which costs time on every page.
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
