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

    /// Runs on a background executor. Resumable: pass the number of pages already indexed.
    static func run(
        bookID: UUID,
        url: URL,
        startPage: Int,
        startOCRCount: Int,
        ocrEnabled: Bool,
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

        var batch: [PageText] = []
        var ocrCount = first == 0 ? 0 : startOCRCount
        var page = first
        while page < count {
            if Task.isCancelled { return .cancelled }
            // PDFKit keeps every page it has touched in memory; reopen periodically
            // so 1,000+ page code books don't pile up memory.
            if page > first && (page - first) % 150 == 0, let fresh = openDocument(url) {
                document = fresh
            }
            let extracted = extractText(document: document, pageIndex: page, ocrEnabled: ocrEnabled)
            if extracted.usedOCR { ocrCount += 1 }
            batch.append(PageText(page: page, text: extracted.text))
            page += 1

            let batchLimit = extracted.usedOCR ? 2 : 12
            if batch.count >= batchLimit || page == count {
                if Task.isCancelled { return .cancelled }
                await index.insert(bookID: bookID, pages: batch)
                batch.removeAll(keepingCapacity: true)
                await progress(page, ocrCount)
            }
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

    private static func extractText(document: PDFDocument, pageIndex: Int, ocrEnabled: Bool) -> (text: String, usedOCR: Bool) {
        autoreleasepool { () -> (text: String, usedOCR: Bool) in
            guard let page = document.page(at: pageIndex) else { return (text: "", usedOCR: false) }
            let text = page.string ?? ""

            var meaningful = 0
            for scalar in text.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
                meaningful += 1
                if meaningful >= 40 { break }
            }
            if meaningful >= 40 || !ocrEnabled {
                return (text: text, usedOCR: false)
            }
            if let recognized = recognizeText(on: page), recognized.count > text.count {
                return (text: recognized, usedOCR: true)
            }
            return (text: text, usedOCR: false)
        }
    }

    /// Renders the page to an image and runs Apple's on-device text recognition.
    private static func recognizeText(on page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = 2200 / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let cgImage = image.cgImage else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
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
