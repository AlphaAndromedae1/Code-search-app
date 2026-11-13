import Foundation
import SwiftUI
import WebKit

/// An official page that lists bulletins, amendments or code news.
struct UpdateSource: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var detail: String
    var url: String
    /// Listing pages can be checked automatically; web searches are only opened by hand.
    var checkable: Bool = true
    var isCustom: Bool = false
    var lastChecked: Date? = nil
    /// Normalized links already seen on the page.
    var seen: [String] = []
}

/// A link that appeared on a followed page since the previous check.
struct UpdateItem: Identifiable, Codable, Hashable, Sendable {
    var url: String
    var title: String
    var sourceID: String
    var found: Date
    /// Why it may matter, e.g. ["OESC", "Rule 26-700", "Code update"].
    var tags: [String]

    var id: String { url }
}

struct PageLink: Decodable, Hashable, Sendable {
    let title: String
    let url: String
}

/// A built-in source and what in the library makes it relevant.
struct SourceSuggestion: Identifiable {
    let source: UpdateSource
    /// Words that appear in matching book names ("OESC", "ONTARIO BUILDING").
    let keywords: [String]
    let categories: [CodeCategory]

    var id: String { source.id }
}

private struct UpdatesData: Codable {
    var followed: [UpdateSource]
    var items: [UpdateItem]
    var lastCheck: Date?

    init(followed: [UpdateSource] = [], items: [UpdateItem] = [], lastCheck: Date? = nil) {
        self.followed = followed
        self.items = items
        self.lastCheck = lastCheck
    }

    enum CodingKeys: String, CodingKey {
        case followed, items, lastCheck
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        followed = (try? c.decodeIfPresent([UpdateSource].self, forKey: .followed)) ?? []
        items = (try? c.decodeIfPresent([UpdateItem].self, forKey: .items)) ?? []
        lastCheck = try? c.decodeIfPresent(Date.self, forKey: .lastCheck)
    }
}

/// Tracks the bulletin/news pages the user follows and flags new items.
/// Pages are only fetched when the user taps "Check Now" or opens them.
@MainActor
@Observable
final class UpdatesStore {
    private(set) var followed: [UpdateSource] = []
    private(set) var items: [UpdateItem] = []
    private(set) var lastCheck: Date?
    private(set) var isChecking = false
    private(set) var progressText = ""
    private(set) var lastProblems: [String] = []

    init() {
        if let data = try? Data(contentsOf: AppPaths.updatesFile),
           let decoded = try? JSONDecoder().decode(UpdatesData.self, from: data) {
            followed = decoded.followed
            items = decoded.items
            lastCheck = decoded.lastCheck
        }
    }

    private func save() {
        let snapshot = UpdatesData(followed: followed, items: items, lastCheck: lastCheck)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: AppPaths.updatesFile, options: .atomic)
        }
    }

    // MARK: Following

    func isFollowing(_ id: String) -> Bool {
        followed.contains { $0.id == id }
    }

    func follow(_ source: UpdateSource) {
        guard !isFollowing(source.id) else { return }
        followed.append(source)
        save()
    }

    func unfollow(_ id: String) {
        followed.removeAll { $0.id == id }
        items.removeAll { $0.sourceID == id }
        save()
    }

    func addCustomSource(name: String, address: String) -> Bool {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard let url = URL(string: text), url.host != nil else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = UpdateSource(
            id: "custom-" + UUID().uuidString,
            name: trimmedName.isEmpty ? (url.host ?? text) : trimmedName,
            detail: url.host ?? "",
            url: url.absoluteString,
            checkable: true,
            isCustom: true
        )
        follow(source)
        return true
    }

    func source(id: String) -> UpdateSource? {
        followed.first { $0.id == id }
    }

    // MARK: New items

    /// Most relevant first, then newest.
    var sortedItems: [UpdateItem] {
        items.sorted { a, b in
            if a.tags.count != b.tags.count { return a.tags.count > b.tags.count }
            return a.found > b.found
        }
    }

    func dismiss(_ item: UpdateItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func dismissAll() {
        items.removeAll()
        save()
    }

    // MARK: Checking

    /// Opens each followed listing page once and records links that weren't there last time.
    func checkAll(libraryTerms: [String]) async {
        guard !isChecking else { return }
        isChecking = true
        lastProblems = []
        defer {
            isChecking = false
            progressText = ""
        }
        let targets = followed.filter(\.checkable)
        let loader = PageLinkLoader()
        for (offset, source) in targets.enumerated() {
            progressText = "Checking \(source.name) (\(offset + 1) of \(targets.count))…"
            guard let url = URL(string: source.url) else { continue }
            let links = await loader.links(at: url)
            if links.isEmpty {
                lastProblems.append(source.name)
                continue
            }
            apply(links, to: source.id, libraryTerms: libraryTerms)
        }
        lastCheck = Date()
        save()
    }

    /// Called when the user opens a followed page in the browser.
    func recordVisit(sourceID: String, pageURL: URL, webView: WKWebView, libraryTerms: [String]) async {
        guard let source = self.source(id: sourceID), source.checkable,
              LibraryStore.sourceKey(pageURL.absoluteString) == LibraryStore.sourceKey(source.url)
        else { return }
        let links = await PageLinkLoader.extractLinks(from: webView)
        guard !links.isEmpty else { return }
        apply(links, to: sourceID, libraryTerms: libraryTerms)
    }

    private func apply(_ links: [PageLink], to sourceID: String, libraryTerms: [String]) {
        guard let i = followed.firstIndex(where: { $0.id == sourceID }) else { return }
        // The first look at a page just records what's there; later checks report differences.
        let isBaseline = followed[i].lastChecked == nil
        var seen = Set(followed[i].seen)
        let now = Date()
        for link in links {
            let key = LibraryStore.sourceKey(link.url)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            if !isBaseline && !items.contains(where: { $0.id == link.url }) {
                items.append(UpdateItem(
                    url: link.url,
                    title: UpdatesStore.describe(link.title, sourceName: followed[i].name),
                    sourceID: sourceID,
                    found: now,
                    tags: UpdatesStore.tags(for: link.title, libraryTerms: libraryTerms)
                ))
            }
        }
        var seenList = Array(seen)
        if seenList.count > 4000 { seenList = Array(seenList.prefix(4000)) }
        followed[i].seen = seenList
        followed[i].lastChecked = now
        save()
    }

    /// e-Laws lists amending regulations as bare citations ("119/26"); make them readable.
    static func describe(_ title: String, sourceName: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: "^[0-9]{1,4}/[0-9]{2}$", options: .regularExpression) != nil {
            return "O. Reg. \(trimmed) — amends \(sourceName)"
        }
        if trimmed.range(of: "^O\\. ?Reg\\. ?[0-9]{1,4}/[0-9]{2}$", options: [.regularExpression, .caseInsensitive]) != nil {
            return "\(trimmed) — amends \(sourceName)"
        }
        return trimmed
    }

    static func tags(for title: String, libraryTerms: [String]) -> [String] {
        let upper = title.uppercased()
        var tags: [String] = []
        for term in libraryTerms {
            let pattern = "(?<![A-Z0-9])" + NSRegularExpression.escapedPattern(for: term) + "(?![A-Z0-9])"
            if upper.range(of: pattern, options: .regularExpression) != nil {
                tags.append(term)
            }
        }
        for reference in RuleReferences.inline(in: title).prefix(2) {
            tags.append("Rule \(reference)")
        }
        let updateWords = ["BULLETIN", "AMEND", "REVISION", "ERRATA", "INTERPRETATION", "CODENEWS", "NOTICE", "UPDATE", "CHANGES", "ADVISORY", "O. REG."]
        if updateWords.contains(where: { upper.contains($0) }) {
            tags.append("Code update")
        }
        return tags
    }

    // MARK: Suggestions

    /// Built-in Ontario sources that fit the books in the library.
    func suggestions(books: [Book], city: String) -> [SourceSuggestion] {
        let names = books.map { "\($0.title) \($0.shortName) \($0.jurisdiction)".uppercased() }
        let categories = Set(books.map(\.category))
        return UpdatesStore.catalog(city: city).filter { suggestion in
            guard !isFollowing(suggestion.id) else { return false }
            let keywordMatch = suggestion.keywords.contains { keyword in names.contains { $0.contains(keyword) } }
            let categoryMatch = !categories.isDisjoint(with: suggestion.categories)
            return keywordMatch || categoryMatch
        }
    }

    private static func page(_ id: String, _ name: String, _ detail: String, _ address: String, checkable: Bool = true) -> UpdateSource {
        UpdateSource(id: id, name: name, detail: detail, url: address, checkable: checkable)
    }

    private static func search(_ id: String, _ name: String, _ detail: String, query: String) -> UpdateSource {
        UpdateSource(id: id, name: name, detail: detail, url: WebLinks.webSearch(query).absoluteString, checkable: false)
    }

    static func catalog(city: String) -> [SourceSuggestion] {
        let electrical = ["OESC", "ONTARIO ELECTRICAL", "CE CODE", "C22.1", "CANADIAN ELECTRICAL", "CEC"]
        let building = ["OBC", "ONTARIO BUILDING", "BUILDING CODE"]
        let fire = ["OFC", "ONTARIO FIRE", "FIRE CODE", "FPPA"]
        let gas = ["B149", "TSSA", "NATURAL GAS", "PROPANE", "GASEOUS FUELS"]
        let oil = ["B139", "LFHC", "FUEL OIL", "FURNACE OIL", "HEATING OIL", "OIL-BURNING", "OIL BURNING",
                   "LIQUID FUELS", "GASOLINE", "DIESEL", "PETROLEUM"]

        var list: [SourceSuggestion] = [
            // Electrical — ESA, CSA, e-Laws
            SourceSuggestion(
                source: page("esa-oesc", "ESA — Ontario Electrical Safety Code",
                               "Electrical Safety Authority: OESC amendments, bulletins and technical updates",
                               "https://esasafe.com/role/oesc/"),
                keywords: electrical, categories: [.electrical]),
            SourceSuggestion(
                source: page("esa-bulletins", "ESA — Bulletins",
                               "Sample OESC bulletins. The complete set and its updates come with your OESC purchase.",
                               "https://esasafe.com/electrical-products/bulletins/"),
                keywords: electrical, categories: [.electrical]),
            SourceSuggestion(
                source: page("esa-code-technical", "ESA — Code & Technical",
                               "Code and technical information from the Electrical Safety Authority",
                               "https://esasafe.com/code-technical/"),
                keywords: electrical, categories: [.electrical]),
            SourceSuggestion(
                source: page("elaws-oesc", "e-Laws — Electrical Safety Code (O. Reg. 164/99)",
                               "A new amending regulation appears here when Ontario adopts a new OESC edition or amendment",
                               "https://www.ontario.ca/laws/regulation/990164"),
                keywords: electrical, categories: [.electrical]),
            SourceSuggestion(
                source: page("csa-ce-code", "CSA Group — Canadian Electrical Code",
                               "CE Code (C22.1) editions and Memorandums of Revision — the base of the OESC",
                               "https://www.csagroup.org/store/product/CSA_C22.1%3A24/"),
                keywords: electrical, categories: [.electrical]),
            SourceSuggestion(
                source: search("csa-mor-search", "Search: latest CE Code revisions",
                               "Web search for new CSA C22.1 Memorandums of Revision and interpretations",
                               query: "CSA C22.1 Canadian Electrical Code Memorandum of Revision"),
                keywords: electrical, categories: [.electrical]),

            // Building — MMAH, e-Laws, OBOA, rulings
            SourceSuggestion(
                source: page("on-building-code-updates", "Ontario — Building Code updates",
                               "Ministry of Municipal Affairs and Housing: Building Code amendments (also sent as CodeNews)",
                               "https://www.ontario.ca/page/building-code-updates"),
                keywords: building, categories: [.building, .residential, .plumbing, .energy, .accessibility]),
            SourceSuggestion(
                source: page("elaws-obc", "e-Laws — Building Code (O. Reg. 163/24)",
                               "New amending regulations to the 2024 Building Code appear here",
                               "https://www.ontario.ca/laws/regulation/240163"),
                keywords: building, categories: [.building, .residential, .plumbing, .energy]),
            SourceSuggestion(
                source: page("oboa-codenews", "OBOA — CodeNews archive",
                               "Ontario Building Officials Association's archive of Ontario CodeNews issues",
                               "https://www.oboa.on.ca/blog/categories/ontario-codenews"),
                keywords: building, categories: [.building, .residential]),
            SourceSuggestion(
                source: search("bcc-rulings-search", "Search: Building Code Commission rulings",
                               "Web search for recent Building Code Commission and BMEC rulings — how the OBC is being interpreted",
                               query: "Ontario Building Code Commission rulings BMEC authorizations"),
                keywords: building, categories: [.building, .residential]),

            // Fire — e-Laws, Fire Marshal
            SourceSuggestion(
                source: page("elaws-fire-code", "e-Laws — Fire Code (O. Reg. 213/07)",
                               "New amending regulations to the Ontario Fire Code appear here",
                               "https://www.ontario.ca/laws/regulation/070213"),
                keywords: fire, categories: [.fire]),
            SourceSuggestion(
                source: search("ofm-search", "Search: Fire Marshal technical guidelines & communiqués",
                               "Web search for new Office of the Fire Marshal technical guidelines and communiqués",
                               query: "Ontario Office of the Fire Marshal technical guideline communiqué Fire Code"),
                keywords: fire, categories: [.fire]),

            // Gas & propane — TSSA, e-Laws, CSA
            SourceSuggestion(
                source: page("tssa-fuels-news", "TSSA — Fuels news & notices",
                               "Technical Standards and Safety Authority fuels safety news",
                               "https://www.tssa.org/taxonomy/term/126"),
                keywords: gas, categories: [.gas]),
            SourceSuggestion(
                source: search("tssa-fuels-search", "Search: TSSA code adoption documents & advisories",
                               "Web search for TSSA fuels code adoption document amendments and B149 interpretation advisories",
                               query: "TSSA fuels code adoption document amendment B149 advisory"),
                keywords: gas, categories: [.gas]),
            SourceSuggestion(
                source: page("elaws-gaseous-fuels", "e-Laws — Gaseous Fuels (O. Reg. 212/01)",
                               "New amending regulations for natural gas and propane installations appear here",
                               "https://www.ontario.ca/laws/regulation/010212"),
                keywords: gas, categories: [.gas]),
            SourceSuggestion(
                source: page("elaws-propane", "e-Laws — Propane Storage and Handling (O. Reg. 211/01)",
                               "New amending regulations for propane storage and handling appear here",
                               "https://www.ontario.ca/laws/regulation/010211"),
                keywords: gas, categories: [.gas]),
            SourceSuggestion(
                source: search("csa-b149-search", "Search: CSA B149 gas & propane code updates",
                               "Web search for new editions, amendments and interpretations of CSA B149.1 and B149.2",
                               query: "CSA B149.1 B149.2 natural gas propane installation code amendment new edition"),
                keywords: gas, categories: [.gas]),

            // Fuel oil & petroleum — TSSA, e-Laws, CSA, ERO
            SourceSuggestion(
                source: page("tssa-fuel-oil", "TSSA — Fuel oil",
                             "TSSA's fuel oil program: code adoption document amendments and advisories",
                             "https://tssa.org/fuel-oil"),
                keywords: oil, categories: [.oil]),
            SourceSuggestion(
                source: page("elaws-fuel-oil", "e-Laws — Fuel Oil (O. Reg. 213/01)",
                             "New amending regulations for fuel oil equipment and tanks appear here",
                             "https://www.ontario.ca/laws/regulation/010213"),
                keywords: oil, categories: [.oil]),
            SourceSuggestion(
                source: page("elaws-liquid-fuels", "e-Laws — Liquid Fuels (O. Reg. 217/01)",
                             "New amending regulations for gasoline and diesel facilities appear here",
                             "https://www.ontario.ca/laws/regulation/010217"),
                keywords: oil, categories: [.oil]),
            SourceSuggestion(
                source: search("csa-b139-search", "Search: CSA B139 oil-burning equipment code updates",
                               "Web search for new editions and Ontario amendments of CSA B139",
                               query: "CSA B139 installation code oil-burning equipment Ontario amendment code adoption document"),
                keywords: oil, categories: [.oil]),
            SourceSuggestion(
                source: search("tssa-lfhc-search", "Search: Liquid Fuels Handling Code amendments",
                               "Web search for TSSA Liquid Fuels Handling Code amendments, director's orders and advisories",
                               query: "TSSA Liquid Fuels Handling Code amendment code adoption document advisory"),
                keywords: oil, categories: [.oil]),
            SourceSuggestion(
                source: search("ero-fuels-search", "Search: proposed fuels code changes (ERO)",
                               "Proposed TSSA code adoption document changes posted for comment on the Environmental Registry of Ontario",
                               query: "Environmental Registry of Ontario TSSA code adoption document amendment proposal fuel"),
                keywords: gas + oil, categories: [.gas, .oil]),

            // National model codes — only if the library has them
            SourceSuggestion(
                source: search("nrc-codes-search", "Search: National Codes of Canada revisions",
                               "Web search for revisions and errata to the National Building, Fire, Plumbing and Energy Codes",
                               query: "National Building Code of Canada revisions errata NRC"),
                keywords: ["NBC", "NATIONAL BUILDING", "NFC", "NATIONAL FIRE", "NPC", "NATIONAL PLUMBING", "NECB", "NATIONAL ENERGY"],
                categories: []),
        ]

        let place = city.trimmingCharacters(in: .whitespacesAndNewlines)
        if !place.isEmpty {
            list.append(SourceSuggestion(
                source: search("municipal-news-\(place.lowercased())", "Search: \(place) by-law & building news",
                               "Web search for recent by-law amendments and building division notices in \(place)",
                               query: "\(place) Ontario building by-law amendment notice"),
                keywords: [],
                categories: [.municipal, .building, .residential]))
        }
        return list
    }
}

/// Loads a page in an off-screen web view (so pages built with JavaScript work) and lists its links.
@MainActor
final class PageLinkLoader {
    private let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1400), configuration: WKWebViewConfiguration())

    func links(at url: URL) async -> [PageLink] {
        _ = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        do {
            try await Task.sleep(for: .milliseconds(600))
            var waited = 0
            while webView.isLoading && waited < 120 {
                try await Task.sleep(for: .milliseconds(250))
                waited += 1
            }
            // Give script-built pages a moment to render their lists.
            try await Task.sleep(for: .milliseconds(1500))
        } catch {
            return []
        }
        return await PageLinkLoader.extractLinks(from: webView)
    }

    static func extractLinks(from webView: WKWebView) async -> [PageLink] {
        guard let raw = try? await webView.evaluateJavaScript(linkScript),
              let json = raw as? String,
              let data = json.data(using: .utf8)
        else { return [] }
        return (try? JSONDecoder().decode([PageLink].self, from: data)) ?? []
    }

    /// Links in the page body (not menus/headers/footers) with a meaningful title.
    private static let linkScript = #"""
    (function () {
      var out = [], seen = {};
      var anchors = document.querySelectorAll('a[href]');
      for (var i = 0; i < anchors.length; i++) {
        var a = anchors[i];
        if (a.closest('nav, header, footer, [role=navigation]')) { continue; }
        var text = (a.innerText || a.textContent || '').replace(/\s+/g, ' ').trim();
        var href = (a.href || '').split('#')[0];
        // Short regulation citations ("119/26", "O. Reg. 5/25") are how e-Laws lists amendments.
        var isCitation = /^(O\. ?Reg\. ?)?\d{1,4}\/\d{2}$/i.test(text);
        if (href.indexOf('http') !== 0 || (text.length < 12 && !isCitation) || seen[href]) { continue; }
        seen[href] = true;
        out.push({ title: text.slice(0, 220), url: href });
        if (out.length >= 500) { break; }
      }
      return JSON.stringify(out);
    })();
    """#
}

/// Finds Canadian code rule/article numbers in text: "26-700" (CE Code / OESC rules),
/// "9.10.14.5" (NBC / OBC / fire code articles) and "6.18.2" (CSA B149 clauses).
enum RuleReferences {
    private static let core = #"(?:\d{1,2}-\d{3}|\d+(?:\.\d+){2,})"#

    private static let headingRegex = try? NSRegularExpression(
        pattern: #"^(?:(?:Rules?|Sections?|Sec\.|Articles?|Clauses?|Subsection|§)\s*)?("# + core + #")(?![\d-])"#
    )

    private static let inlineRegex = try? NSRegularExpression(
        pattern: #"(?<![\w.-])("# + core + #")(?![\d-])"#
    )

    /// Numbers that start lines on a page — the sections actually printed on it.
    static func headings(in text: String, limit: Int) -> [String] {
        guard let regex = headingRegex else { return [] }
        var found: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let ns = trimmed as NSString
            guard let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges > 1
            else { continue }
            let reference = ns.substring(with: match.range(at: 1))
            if !found.contains(reference) {
                found.append(reference)
                if found.count >= limit { break }
            }
        }
        return found
    }

    /// Every reference mentioned anywhere in the text.
    static func inline(in text: String) -> [String] {
        guard let regex = inlineRegex else { return [] }
        let ns = text as NSString
        var found: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
            let reference = ns.substring(with: match.range(at: 1))
            if !found.contains(reference) { found.append(reference) }
        }
        return found
    }
}
