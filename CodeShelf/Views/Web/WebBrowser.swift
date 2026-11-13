import SwiftUI
import WebKit

struct BrowserRoute: Hashable {
    enum Purpose: Hashable {
        case municipal
        case bulletin
        /// An Ontario law on e-Laws (the id of an `OntarioLaw`).
        case regulation(String)
    }

    var url: URL
    var purpose: Purpose = .municipal
    /// Library book this page was saved as, so "Save" can update it in place.
    var replacing: UUID? = nil
    /// Followed update source, so visiting it records what's new.
    var sourceID: String? = nil
}

/// Owns a WKWebView and mirrors its navigation state for SwiftUI.
@MainActor
@Observable
final class BrowserModel {
    let webView: WKWebView
    private(set) var title = ""
    private(set) var url: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress: Double = 0

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    private let uiDelegate = BrowserUIDelegate()

    init(start: URL) {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.allowsBackForwardNavigationGestures = true
        view.isFindInteractionEnabled = true
        webView = view
        view.uiDelegate = uiDelegate
        observations = [
            observe(\.title),
            observe(\.url),
            observe(\.canGoBack),
            observe(\.canGoForward),
            observe(\.isLoading),
            observe(\.estimatedProgress),
        ]
        _ = view.load(URLRequest(url: start))
    }

    private func observe<Value>(_ keyPath: KeyPath<WKWebView, Value>) -> NSKeyValueObservation {
        webView.observe(keyPath, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sync()
            }
        }
    }

    private func sync() {
        title = webView.title ?? ""
        url = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        progress = webView.estimatedProgress
    }

    func open(_ url: URL) {
        _ = webView.load(URLRequest(url: url))
    }
}

/// Opens target="_blank" links in the same view instead of silently ignoring them.
@MainActor
final class BrowserUIDelegate: NSObject, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            _ = webView.load(navigationAction.request)
        }
        return nil
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// In-app browser used for municipal codes and bulletin sources, with "Save to Library".
struct WebCodeBrowser: View {
    let route: BrowserRoute
    @State private var model: BrowserModel? = nil

    var body: some View {
        Group {
            if let model {
                BrowserScreen(model: model, route: route)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if model == nil { model = BrowserModel(start: route.url) }
        }
    }
}

private struct BrowserScreen: View {
    @Environment(LibraryStore.self) private var store
    @Environment(UpdatesStore.self) private var updates
    @AppStorage(AppSettings.municipalHomeKey) private var municipalHome = ""
    let model: BrowserModel
    let route: BrowserRoute
    @State private var showSave = false

    var body: some View {
        VStack(spacing: 0) {
            if model.isLoading {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
            }
            WebViewContainer(webView: model.webView)
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    _ = model.webView.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .disabled(!model.canGoBack)

                Button {
                    _ = model.webView.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.forward")
                }
                .disabled(!model.canGoForward)

                Button {
                    _ = model.webView.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }

                Button {
                    model.webView.findInteraction?.presentFindNavigator(showingReplace: false)
                } label: {
                    Label("Find on Page", systemImage: "text.magnifyingglass")
                }

                Spacer()

                if route.purpose == .municipal {
                    Button {
                        toggleHome()
                    } label: {
                        Label("My Code's Home Page", systemImage: isHome ? "star.fill" : "star")
                    }
                }

                Button {
                    showSave = true
                } label: {
                    Label("Save to Library", systemImage: "square.and.arrow.down")
                }
                .disabled(model.url == nil || model.isLoading)
            }
        }
        .sheet(isPresented: $showSave) {
            SaveWebPageSheet(model: model, route: route)
        }
        .onChange(of: model.isLoading) { _, loading in
            if !loading { recordVisitIfFollowed() }
        }
    }

    private var displayTitle: String {
        let cleaned = WebPageCapture.cleanTitle(model.title)
        if !cleaned.isEmpty { return cleaned }
        return model.url?.host ?? "Loading…"
    }

    private var isHome: Bool {
        guard let current = model.url?.absoluteString, !municipalHome.isEmpty else { return false }
        return LibraryStore.sourceKey(current) == LibraryStore.sourceKey(municipalHome)
    }

    private func toggleHome() {
        if isHome {
            municipalHome = ""
        } else if let current = model.url?.absoluteString {
            municipalHome = current
        }
    }

    /// Visiting a followed bulletin page counts as a check: remember what's on it.
    private func recordVisitIfFollowed() {
        guard let sourceID = route.sourceID, let current = model.url else { return }
        let webView = model.webView
        let terms = store.libraryTerms
        Task {
            await updates.recordVisit(sourceID: sourceID, pageURL: current, webView: webView, libraryTerms: terms)
        }
    }
}

/// Name the page and save it into the library as a searchable PDF.
struct SaveWebPageSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.cityKey) private var city = ""
    let model: BrowserModel
    let route: BrowserRoute

    @State private var title = ""
    @State private var shortName = ""
    @State private var jurisdiction = ""
    @State private var category: CodeCategory = .municipal
    @State private var loadWholePage = true
    @State private var replaceExisting = true
    @State private var isWorking = false
    @State private var status: String? = nil
    @State private var savedMessage: String? = nil
    @State private var errorMessage: String? = nil
    @State private var didPrefill = false

    var body: some View {
        NavigationStack {
            Form {
                if let savedMessage {
                    Section {
                        Label(savedMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    TextField("Title", text: $title)
                    TextField("Short name", text: $shortName, prompt: Text("e.g. Toronto Ch. 363 Building"))
                    TextField("Jurisdiction / publisher", text: $jurisdiction)
                    Picker("Category", selection: $category) {
                        ForEach(CodeCategory.allCases) { item in
                            Label(item.label, systemImage: item.symbol).tag(item)
                        }
                    }
                } header: {
                    Text("Save to Library")
                } footer: {
                    Text(model.url?.absoluteString ?? "")
                        .lineLimit(2)
                }

                Section {
                    if !pageIsPDF {
                        Toggle("Load the whole page first", isOn: $loadWholePage)
                    }
                    if let existing = existingBook {
                        Toggle("Replace “\(existing.displayName)” (\(existing.edition))", isOn: $replaceExisting)
                    }
                } footer: {
                    Text(pageIsPDF
                         ? "This PDF will be downloaded and added to your library as-is."
                         : "CodeShelf scrolls through long chapters so everything is loaded, then saves the page's text (without menus and sidebars) as a searchable PDF.")
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack(spacing: 10) {
                            if isWorking { ProgressView() }
                            Text(isWorking ? (status ?? "Saving…") : "Save to Library")
                        }
                    }
                    .disabled(isWorking || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Save Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(savedMessage == nil ? "Cancel" : "Done") { dismiss() }
                        .disabled(isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
            .onAppear(perform: prefill)
        }
    }

    private var pageIsPDF: Bool {
        guard let url = model.url else { return false }
        return WebPageCapture.isPDF(url)
    }

    private var existingBook: Book? {
        if let id = route.replacing, let book = store.book(id: id) { return book }
        return store.book(sourceURL: model.url)
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        if let existing = existingBook {
            title = existing.title
            shortName = existing.shortName
            jurisdiction = existing.jurisdiction
            category = existing.category
            return
        }
        let pageTitle = WebPageCapture.cleanTitle(model.title)
        title = pageTitle.isEmpty ? (model.url?.lastPathComponent ?? "Saved Page") : pageTitle
        switch route.purpose {
        case .municipal:
            category = .municipal
            let place = city.trimmingCharacters(in: .whitespaces)
            jurisdiction = place.isEmpty ? Ontario.name : "\(place), \(Ontario.code)"
        case .regulation(let lawID):
            let law = Ontario.law(id: lawID)
            category = law?.category ?? .other
            shortName = law?.shortName ?? ""
            if let law { title = "\(law.name) (\(law.citation))" }
            jurisdiction = "Ontario (e-Laws)"
        case .bulletin:
            category = .bulletin
            jurisdiction = model.url?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        }
    }

    private func save() async {
        isWorking = true
        errorMessage = nil
        savedMessage = nil
        defer {
            isWorking = false
            status = nil
        }
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let data = try await WebPageCapture.capture(
                webView: model.webView,
                title: finalTitle,
                subtitle: jurisdiction,
                loadWholePage: loadWholePage
            ) { message in
                status = message
            }
            let saved = await store.addWebBook(
                pdfData: data,
                title: finalTitle,
                shortName: shortName,
                category: category,
                jurisdiction: jurisdiction,
                sourceURL: model.url?.absoluteString ?? "",
                replacing: replaceExisting ? existingBook?.id : nil
            )
            if saved {
                savedMessage = "Saved to your library. It's being indexed for search now — you can keep browsing and save more pages."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
