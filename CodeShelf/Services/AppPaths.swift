import Foundation

/// File locations inside the app sandbox.
enum AppPaths {
    static let root: URL = makeDirectory(
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodeShelf", isDirectory: true)
    )

    static let books: URL = makeDirectory(root.appendingPathComponent("Books", isDirectory: true))

    static var libraryFile: URL { root.appendingPathComponent("library.json") }

    static var indexFile: URL { root.appendingPathComponent("search-index.sqlite") }

    static var updatesFile: URL { root.appendingPathComponent("updates.json") }

    private static func makeDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum AppSettings {
    static let ocrKey = "ocrEnabled"
    static let recentSearchesKey = "recentSearches"
    static let cityKey = "homeCity"
    /// The municipal code website the user starred in the browser.
    static let municipalHomeKey = "municipalCodeHome"

    /// Defaults to on when the user has never changed it.
    static var ocrEnabled: Bool {
        UserDefaults.standard.object(forKey: ocrKey) as? Bool ?? true
    }
}
