import CoreText
import Foundation
import PDFKit
import UIKit
import WebKit

enum CaptureError: LocalizedError {
    case noPage
    case noContent
    case notPDF

    var errorDescription: String? {
        switch self {
        case .noPage:
            return "No page is loaded yet."
        case .noContent:
            return "Couldn't find any code text on this page. Open the chapter or section itself (not the table of contents) and try again."
        case .notPDF:
            return "The file at this link isn't a readable PDF."
        }
    }
}

/// Saves what the user is looking at in the in-app browser, the same way
/// "Print → Save as PDF" would: once, on request, for the page on screen.
@MainActor
enum WebPageCapture {
    /// - Returns: PDF data ready to import.
    static func capture(
        webView: WKWebView,
        title: String,
        subtitle: String,
        loadWholePage: Bool,
        status: (String) -> Void
    ) async throws -> Data {
        guard let url = webView.url else { throw CaptureError.noPage }

        // A PDF opened in the browser (bulletins often are): keep the original file.
        if isPDF(url) {
            status("Downloading PDF…")
            let (data, _) = try await URLSession.shared.data(from: url)
            guard PDFDocument(data: data) != nil else { throw CaptureError.notPDF }
            return data
        }

        if loadWholePage {
            // Long chapters often load more text as you scroll; keep scrolling until it stops growing.
            var lastLength = -1
            var stableRounds = 0
            for round in 1...15 {
                status("Loading the full page… (\(round))")
                let result = try? await webView.evaluateJavaScript(scrollToEndScript)
                let length = (result as? NSNumber)?.intValue ?? 0
                if length == lastLength {
                    stableRounds += 1
                    if stableRounds >= 2 { break }
                } else {
                    stableRounds = 0
                }
                lastLength = length
                try await Task.sleep(for: .milliseconds(900))
            }
            _ = try? await webView.evaluateJavaScript(scrollToTopScript)
        }

        status("Reading the page…")
        let raw = try await webView.evaluateJavaScript(extractScript)
        guard let json = raw as? String,
              let jsonData = json.data(using: .utf8),
              let extracted = try? JSONDecoder().decode(ExtractedPage.self, from: jsonData)
        else { throw CaptureError.noContent }

        let body = cleanText(extracted.text)
        guard body.count >= 200 else { throw CaptureError.noContent }

        status("Creating PDF…")
        let retrieved = Date().formatted(date: .long, time: .shortened)
        let header = "Source: \(url.absoluteString)\nRetrieved \(retrieved). Unofficial copy — confirm against the official code before relying on it."
        let pdfTitle = title
        let pdfSubtitle = subtitle
        return await Task.detached(priority: .userInitiated) {
            TextPDFRenderer.render(title: pdfTitle, subtitle: pdfSubtitle, header: header, body: body)
        }.value
    }

    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    /// The page's title without the site name ("Building By-law 2014-220 | City of Ottawa" → "Building By-law 2014-220").
    static func cleanTitle(_ title: String) -> String {
        let first = title.components(separatedBy: " | ").first ?? title
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ExtractedPage: Decodable {
        let title: String
        let heading: String
        let text: String
    }

    nonisolated static func cleanText(_ text: String) -> String {
        var lines: [String] = []
        var blankRun = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\u{200B}", with: "")
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - JavaScript

    /// Scrolls the window and every scrollable panel to the bottom; returns the page's text length.
    private static let scrollToEndScript = #"""
    (function () {
      var targets = [document.scrollingElement || document.documentElement];
      var all = document.querySelectorAll('*');
      for (var i = 0; i < all.length; i++) {
        var el = all[i];
        if (el.scrollHeight > el.clientHeight + 40 && el.clientHeight > 50) {
          var oy = window.getComputedStyle(el).overflowY;
          if (oy === 'auto' || oy === 'scroll') { targets.push(el); }
        }
      }
      for (var j = 0; j < targets.length; j++) { targets[j].scrollTop = targets[j].scrollHeight; }
      window.scrollTo(0, document.body ? document.body.scrollHeight : 0);
      return document.body ? document.body.innerText.length : 0;
    })();
    """#

    private static let scrollToTopScript = #"""
    (function () {
      var all = document.querySelectorAll('*');
      for (var i = 0; i < all.length; i++) { if (all[i].scrollTop > 0) { all[i].scrollTop = 0; } }
      window.scrollTo(0, 0);
      return 0;
    })();
    """#

    /// Finds the main content: starting at <body>, keep stepping into the child that holds
    /// most of the text, as long as what's left beside it looks like navigation (mostly links).
    private static let extractScript = #"""
    (function () {
      function len(el) { return (el && el.innerText) ? el.innerText.trim().length : 0; }
      function linkLen(el) {
        var total = 0, links = el.querySelectorAll('a');
        for (var i = 0; i < links.length; i++) { total += (links[i].innerText || '').trim().length; }
        return total;
      }
      var docs = [document];
      var frames = document.querySelectorAll('iframe, frame');
      for (var f = 0; f < frames.length; f++) {
        try { if (frames[f].contentDocument && frames[f].contentDocument.body) { docs.push(frames[f].contentDocument); } } catch (e) {}
      }
      var doc = document, best = -1;
      for (var d = 0; d < docs.length; d++) { var l = len(docs[d].body); if (l > best) { best = l; doc = docs[d]; } }
      var node = doc.body;
      if (!node) { return JSON.stringify({ title: document.title || '', heading: '', text: '' }); }
      var skip = /^(NAV|HEADER|FOOTER|SCRIPT|STYLE|NOSCRIPT|ASIDE|FORM|BUTTON|SELECT|svg)$/i;
      // Prefer the page's declared main content when it holds most of the text.
      var bodyScore = len(node) - linkLen(node);
      var semantic = Array.prototype.slice.call(doc.querySelectorAll('main, [role=main]'));
      var articles = doc.querySelectorAll('article');
      if (articles.length === 1) { semantic.push(articles[0]); }
      var bestSemantic = null, bestSemanticScore = 0;
      for (var s = 0; s < semantic.length; s++) {
        var sScore = len(semantic[s]) - linkLen(semantic[s]);
        if (sScore > bestSemanticScore) { bestSemanticScore = sScore; bestSemantic = semantic[s]; }
      }
      if (bestSemantic && bodyScore > 0 && bestSemanticScore >= bodyScore * 0.5) { node = bestSemantic; }

      // Score by text that isn't link text, so tables of contents and menus lose to the code itself.
      for (var depth = 0; depth < 30; depth++) {
        var nodeLinks = linkLen(node);
        var total = len(node) - nodeLinks;
        var top = null, topScore = 0, topLinks = 0;
        for (var c = node.firstElementChild; c; c = c.nextElementSibling) {
          if (skip.test(c.tagName)) { continue; }
          var links = linkLen(c);
          var score = len(c) - links;
          if (score > topScore) { topScore = score; top = c; topLinks = links; }
        }
        if (!top || total <= 0) { break; }
        var restText = len(node) - len(top);
        var restLinks = nodeLinks - topLinks;
        var restIsNavigation = restText <= 0 || (restLinks / restText) > 0.5;
        if (topScore >= total * 0.9 || (topScore >= total * 0.4 && restIsNavigation)) { node = top; } else { break; }
      }
      var h = node.querySelector('h1, h2, h3');
      return JSON.stringify({
        title: doc.title || document.title || '',
        heading: h ? h.innerText.trim() : '',
        text: node.innerText || ''
      });
    })();
    """#
}

/// Lays out plain text as a paginated, searchable US-Letter PDF.
enum TextPDFRenderer {
    static func render(title: String, subtitle: String, header: String, body: String) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 54

        let text = NSMutableAttributedString()
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacing = 4
        text.append(NSAttributedString(string: title + "\n", attributes: [
            .font: UIFont.boldSystemFont(ofSize: 18),
            .foregroundColor: UIColor.black,
            .paragraphStyle: titleStyle,
        ]))
        if !subtitle.isEmpty {
            text.append(NSAttributedString(string: subtitle + "\n", attributes: [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.darkGray,
                .paragraphStyle: titleStyle,
            ]))
        }
        text.append(NSAttributedString(string: header + "\n\n", attributes: [
            .font: UIFont.italicSystemFont(ofSize: 8.5),
            .foregroundColor: UIColor.gray,
        ]))

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = 1.5
        bodyStyle.paragraphSpacing = 3
        let headingStyle = NSMutableParagraphStyle()
        headingStyle.paragraphSpacingBefore = 6
        headingStyle.paragraphSpacing = 3
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10.5),
            .foregroundColor: UIColor.black,
            .paragraphStyle: bodyStyle,
        ]
        let headingAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 11),
            .foregroundColor: UIColor.black,
            .paragraphStyle: headingStyle,
        ]
        for line in body.components(separatedBy: "\n") {
            let attributes = looksLikeHeading(line) ? headingAttributes : bodyAttributes
            text.append(NSAttributedString(string: line + "\n", attributes: attributes))
        }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "CodeShelf",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let footerAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: UIColor.gray,
        ]

        return renderer.pdfData { context in
            var location = 0
            var pageNumber = 0
            let length = text.length
            repeat {
                context.beginPage()
                pageNumber += 1
                let cg = context.cgContext
                cg.saveGState()
                cg.textMatrix = .identity
                cg.translateBy(x: 0, y: pageRect.height)
                cg.scaleBy(x: 1, y: -1)
                let textArea = CGRect(x: margin, y: margin, width: pageRect.width - margin * 2, height: pageRect.height - margin * 2)
                let path = CGPath(rect: textArea, transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
                CTFrameDraw(frame, cg)
                let visible = CTFrameGetVisibleStringRange(frame)
                cg.restoreGState()

                let footer = "\(title) — page \(pageNumber)" as NSString
                footer.draw(at: CGPoint(x: margin, y: pageRect.height - margin + 20), withAttributes: footerAttributes)

                if visible.length <= 0 { break }
                location += visible.length
            } while location < length
        }
    }

    /// Section headings in code text: "Sec. 10-2.", "Section 105.1", "15.04.050 Amendments…", "Article 3".
    static func looksLikeHeading(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 160 else { return false }
        let lower = line.lowercased()
        let prefixes = ["sec. ", "section ", "§", "chapter ", "article ", "title ", "division ", "part ", "subchapter ", "rule "]
        if prefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        return line.range(of: #"^[A-Z]?\d+([.\-]\d+)+\.?\s+[A-Z]"#, options: .regularExpression) != nil
    }
}
