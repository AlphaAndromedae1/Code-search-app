import BackgroundTasks
import Foundation
import UserNotifications

/// Local notifications for new bulletins and updated instructions (no server involved).
enum Notifier {
    static func requestPermissionIfNeeded() async {
        guard AppSettings.notificationsEnabled, !AppSettings.automationDisabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func post(title: String, body: String) async {
        guard AppSettings.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// iOS Background App Refresh: iOS decides the exact timing (usually a few times a day).
enum BackgroundRefresh {
    static let taskID = "com.personal.codeshelf.updates"

    static func schedule() {
        guard AppSettings.autoCheckEnabled, !AppSettings.automationDisabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        schedule()
        guard AppSettings.autoCheckEnabled, !AppSettings.automationDisabled else { return }
        let updates = await UpdatesStore.shared
        let terms = await LibraryStore.shared.libraryTerms
        await updates.backgroundRefresh(libraryTerms: terms)
    }
}

/// Fetches a page's HTML and lists its links, without a web view, so it also works in the background.
enum HTMLLinkFetcher {
    /// Downloads several pages at once, `concurrent` at a time. Keyed by the caller's id.
    static func links(for pages: [(id: String, url: URL)], concurrent: Int) async -> [String: [PageLink]] {
        await withTaskGroup(of: (String, [PageLink]).self) { group in
            var results: [String: [PageLink]] = [:]
            var waiting = pages.makeIterator()
            for _ in 0..<min(concurrent, pages.count) {
                guard let page = waiting.next() else { break }
                group.addTask { (page.id, await links(at: page.url)) }
            }
            while let result = await group.next() {
                results[result.0] = result.1
                if let page = waiting.next() {
                    group.addTask { (page.id, await links(at: page.url)) }
                }
            }
            return results
        }
    }

    static func links(at url: URL) async -> [PageLink] {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        guard let result = try? await URLSession.shared.data(for: request),
              let http = result.1 as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return [] }
        let html = String(decoding: result.0, as: UTF8.self)
        return parse(html, base: http.url ?? url)
    }

    /// Links in the page body (menus, headers and footers removed) with a meaningful title.
    static func parse(_ html: String, base: URL) -> [PageLink] {
        var body = html
        for tag in ["script", "style", "nav", "header", "footer"] {
            body = replacing(pattern: "<\(tag)\\b[\\s\\S]*?</\(tag)>", in: body, with: " ")
        }
        guard let anchor = try? NSRegularExpression(
            pattern: "<a\\s[^>]*?href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) else { return [] }

        let ns = body as NSString
        var seen = Set<String>()
        var links: [PageLink] = []
        for match in anchor.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges > 2 else { continue }
            let href = decodeEntities(ns.substring(with: match.range(at: 1)))
            let text = decodeEntities(replacing(pattern: "<[^>]+>", in: ns.substring(with: match.range(at: 2)), with: " "))
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard let resolved = URL(string: href, relativeTo: base)?.absoluteURL,
                  let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { continue }
            var address = resolved.absoluteString
            if let hash = address.firstIndex(of: "#") { address = String(address[..<hash]) }
            let isCitation = text.range(of: "^(O\\. ?Reg\\. ?)?[0-9]{1,4}/[0-9]{2}$", options: [.regularExpression, .caseInsensitive]) != nil
            guard text.count >= 12 || isCitation, !seen.contains(address) else { continue }
            seen.insert(address)
            links.append(PageLink(title: String(text.prefix(220)), url: address))
            if links.count >= 500 { break }
        }
        return links
    }

    private static func replacing(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: replacement)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let named = ["&amp;": "&", "&nbsp;": " ", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">",
                     "&ndash;": "–", "&mdash;": "—", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”"]
        for (entity, value) in named {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        guard let numeric = try? NSRegularExpression(pattern: "&#([0-9]{2,6});") else { return result }
        let ns = result as NSString
        var output = ""
        var cursor = 0
        for match in numeric.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let digits = ns.substring(with: match.range(at: 1))
            if let code = UInt32(digits), let scalar = Unicode.Scalar(code) {
                output.append(Character(scalar))
            }
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }
}
