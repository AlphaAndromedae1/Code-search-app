import Foundation
import SwiftUI

/// A manufacturer's installation document in the built-in fuel equipment catalog.
struct EquipmentDoc: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let types: [String]
    let manufacturer: String
    let title: String
    let models: String
    /// Direct link to the manufacturer's PDF, when one is known.
    let url: String?
    /// Search used when there is no stable direct link.
    let search: String?

    var downloadURL: URL? {
        guard let url else { return nil }
        return URL(string: url)
    }

    var searchURL: URL {
        WebLinks.webSearch(search ?? "\(manufacturer) \(title) PDF")
    }

    var manualInfo: ManualInfo {
        ManualInfo(manufacturer: manufacturer, models: models, equipmentType: types.first ?? "Other", documentTitle: title)
    }
}

private struct FuelCatalogFile: Decodable {
    let equipment: [EquipmentDoc]
}

/// The fuel equipment catalog bundled with the app (Resources/FuelCatalog.json).
enum FuelCatalog {
    static let groups = ["CSST gas piping", "ULC S636 venting", "Propane regulator", "Relief valve", "Propane tank / cylinder"]

    static let equipment: [EquipmentDoc] = {
        guard let url = Bundle.main.url(forResource: "FuelCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(FuelCatalogFile.self, from: data)
        else { return [] }
        return file.equipment
    }()

    static func docs(for type: String) -> [EquipmentDoc] {
        equipment.filter { $0.types.contains(type) }
    }

    static func heading(for type: String) -> String {
        switch type {
        case "CSST gas piping": return "CSST Gas Piping"
        case "ULC S636 venting": return "ULC S636 (\"636\") Venting"
        case "Propane regulator": return "Propane Regulators"
        case "Relief valve": return "Relief Valves"
        case "Propane tank / cylinder": return "Propane Tanks & Cylinders"
        default: return type
        }
    }
}

/// Downloads the catalog's manufacturer instructions into the library and keeps them current.
@MainActor
@Observable
final class EquipmentLibrary {
    enum Status: Equatable {
        case working
        case saved
        case updated
        case upToDate
        case needsBrowser
        case failed(String)
    }

    static let shared = EquipmentLibrary()

    private(set) var status: [String: Status] = [:]
    private(set) var isSyncing = false
    private(set) var lastSync: Date?

    private static let lastSyncKey = "equipmentLastSync"

    init() {
        lastSync = UserDefaults.standard.object(forKey: EquipmentLibrary.lastSyncKey) as? Date
    }

    /// Saved copy of a catalog document, if any.
    func savedBook(for doc: EquipmentDoc, in store: LibraryStore) -> Book? {
        if let url = doc.downloadURL, let book = store.book(sourceURL: url) { return book }
        return store.books.first { book in
            book.category == .manufacturer && book.jurisdiction == doc.manufacturer && book.title == doc.title
        }
    }

    /// Runs automatically at most twice a day when automatic downloads are on.
    func syncIfDue(store: LibraryStore) async -> [String] {
        guard AppSettings.autoDownloadEquipment, !AppSettings.automationDisabled else { return [] }
        if let lastSync, Date().timeIntervalSince(lastSync) < 12 * 3600 { return [] }
        return await sync(store: store)
    }

    /// Downloads missing documents and replaces any that changed online.
    /// - Returns: titles of documents that were added or updated.
    @discardableResult
    func sync(store: LibraryStore, only ids: Set<String>? = nil) async -> [String] {
        guard !isSyncing else { return [] }
        isSyncing = true
        defer { isSyncing = false }

        var changed: [String] = []
        for doc in FuelCatalog.equipment {
            if let ids, !ids.contains(doc.id) { continue }
            let existing = savedBook(for: doc, in: store)
            guard let url = doc.downloadURL else {
                status[doc.id] = existing == nil ? .needsBrowser : .saved
                continue
            }
            status[doc.id] = .working
            if let existing {
                let remote = await EquipmentLibrary.remoteVersion(of: url)
                if let remote, !remote.isEmpty, remote != existing.sourceVersion {
                    if await download(doc, from: url, store: store, replacing: existing.id) {
                        status[doc.id] = .updated
                        changed.append(doc.title)
                    }
                } else {
                    status[doc.id] = .upToDate
                }
            } else if await download(doc, from: url, store: store, replacing: nil) {
                status[doc.id] = .saved
                changed.append(doc.title)
            }
        }

        if ids == nil {
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: EquipmentLibrary.lastSyncKey)
        }
        return changed
    }

    private func download(_ doc: EquipmentDoc, from url: URL, store: LibraryStore, replacing existingID: UUID?) async -> Bool {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        guard let result = try? await URLSession.shared.data(for: request),
              let http = result.1 as? HTTPURLResponse
        else {
            status[doc.id] = .failed("Couldn't reach \(url.host ?? "the manufacturer's site")")
            return false
        }
        guard (200..<300).contains(http.statusCode) else {
            status[doc.id] = .failed("The manufacturer's site answered \(http.statusCode)")
            return false
        }
        let data = result.0
        // Some links lead to a download page instead of the PDF itself; open those in the browser.
        guard data.prefix(1024).range(of: Data("%PDF".utf8)) != nil else {
            status[doc.id] = .needsBrowser
            return false
        }
        let version = EquipmentLibrary.version(from: http, length: Int64(data.count))
        let saved = await store.addWebBook(
            pdfData: data,
            title: doc.title,
            shortName: "",
            category: .manufacturer,
            jurisdiction: doc.manufacturer,
            sourceURL: url.absoluteString,
            replacing: existingID,
            manual: doc.manualInfo,
            sourceVersion: version
        )
        if !saved { status[doc.id] = .failed("Couldn't save the PDF") }
        return saved
    }

    private static func remoteVersion(of url: URL) async -> String? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "HEAD"
        guard let result = try? await URLSession.shared.data(for: request),
              let http = result.1 as? HTTPURLResponse,
              (200..<400).contains(http.statusCode)
        else { return nil }
        return version(from: http, length: http.expectedContentLength)
    }

    private static func version(from http: HTTPURLResponse, length: Int64) -> String {
        if let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty { return etag }
        if let modified = http.value(forHTTPHeaderField: "Last-Modified"), !modified.isEmpty { return modified }
        return length > 0 ? "\(length)" : ""
    }
}
