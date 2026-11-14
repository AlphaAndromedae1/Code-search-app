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

    static var importLogFile: URL { root.appendingPathComponent("import-log.txt") }

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

    static let autoCheckKey = "autoCheckUpdates"
    static let notifyKey = "notifyUpdates"
    static let autoEquipmentKey = "autoDownloadEquipment"

    /// Defaults to on when the user has never changed it.
    static var ocrEnabled: Bool {
        UserDefaults.standard.object(forKey: ocrKey) as? Bool ?? true
    }

    /// Check TSSA / CSA / e-Laws sources automatically (on open and in the background).
    static var autoCheckEnabled: Bool {
        UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true
    }

    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true
    }

    /// Download the fuel equipment catalog's manufacturer instructions automatically.
    static var autoDownloadEquipment: Bool {
        UserDefaults.standard.object(forKey: autoEquipmentKey) as? Bool ?? true
    }

    /// Set by the CI smoke test (`-disableAutomation YES`) so no network work starts.
    static var automationDisabled: Bool {
        UserDefaults.standard.bool(forKey: "disableAutomation")
    }
}
