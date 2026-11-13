import PDFKit
import SwiftUI

/// A request to show a page (and optionally highlight words on it).
/// Each request has a unique id so repeating the same page still triggers a jump.
struct JumpRequest: Equatable {
    let id = UUID()
    var pageIndex: Int
    var terms: [String] = []
}

/// Lets SwiftUI code read the current text selection from the PDF view on demand.
@MainActor
final class PDFViewProxy {
    weak var view: PDFView?

    var selectedText: String {
        view?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    var jump: JumpRequest?
    var proxy: PDFViewProxy?
    var onPageChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .secondarySystemBackground
        view.document = document
        context.coordinator.onPageChange = onPageChange
        context.coordinator.observe(view)
        proxy?.view = view
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onPageChange = onPageChange
        proxy?.view = view
        if view.document !== document {
            view.document = document
            coordinator.lastJumpID = nil
        }
        if let jump, jump.id != coordinator.lastJumpID {
            coordinator.lastJumpID = jump.id
            coordinator.schedule(jump, in: view)
        }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onPageChange: (Int) -> Void = { _ in }
        var lastJumpID: UUID?
        private var pendingJump: Task<Void, Never>?

        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged(_:)),
                name: .PDFViewPageChanged,
                object: view
            )
        }

        func stopObserving() {
            pendingJump?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView else { return }
            report(view)
        }

        private func report(_ view: PDFView) {
            guard let page = view.currentPage, let document = view.document else { return }
            let index = document.index(for: page)
            let callback = onPageChange
            // Defer so we never mutate SwiftUI state during a view update.
            Task { callback(index) }
        }

        /// Waits until the view has been laid out, then jumps.
        func schedule(_ jump: JumpRequest, in view: PDFView) {
            pendingJump?.cancel()
            pendingJump = Task { [weak self, weak view] in
                for _ in 0..<40 {
                    guard let view else { return }
                    if view.window != nil && view.bounds.width > 1 { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                await Task.yield()
                guard !Task.isCancelled, let self, let view else { return }
                self.perform(jump, in: view)
            }
        }

        private func perform(_ jump: JumpRequest, in view: PDFView) {
            guard let document = view.document, document.pageCount > 0 else { return }
            let index = min(max(jump.pageIndex, 0), document.pageCount - 1)
            guard let page = document.page(at: index) else { return }
            let selections = Coordinator.selections(on: page, terms: jump.terms)
            view.highlightedSelections = selections.isEmpty ? nil : selections
            view.go(to: page)
            if let first = selections.first {
                view.go(to: first)
            }
            report(view)
        }

        /// Finds each term on the page so it can be highlighted.
        static func selections(on page: PDFPage, terms: [String]) -> [PDFSelection] {
            guard !terms.isEmpty, let text = page.string, !text.isEmpty else { return [] }
            let nsText = text as NSString
            var result: [PDFSelection] = []

            func find(_ term: String) -> Int {
                var found = 0
                var searchRange = NSRange(location: 0, length: nsText.length)
                while result.count < 120 {
                    let match = nsText.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                    if match.location == NSNotFound || match.length == 0 { break }
                    if let selection = page.selection(for: match) {
                        selection.color = UIColor.systemYellow.withAlphaComponent(0.6)
                        result.append(selection)
                        found += 1
                    }
                    let next = match.location + match.length
                    if next >= nsText.length { break }
                    searchRange = NSRange(location: next, length: nsText.length - next)
                }
                return found
            }

            for term in terms where !term.isEmpty {
                if find(term) == 0 && term.contains(" ") {
                    // Phrase may be broken across lines in the PDF text; highlight its words instead.
                    for word in term.split(separator: " ") where word.count >= 3 {
                        _ = find(String(word))
                    }
                }
            }
            return result
        }
    }
}
