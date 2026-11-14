import Foundation

/// The app's Documents folder, which the Files app shows as On My iPhone › CodeShelf.
/// Every PDF in the library lives here, so it can be added, organized or removed in Files.
enum DocumentsFolder {
    static let root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    static let standardFolders = ["Code Books", "Manufacturer Instructions", "Bulletins", "By-laws"]

    /// Where the app files a PDF it adds itself (imports, downloads, saved web pages).
    static func folderName(for category: CodeCategory) -> String {
        switch category {
        case .manufacturer: return "Manufacturer Instructions"
        case .bulletin: return "Bulletins"
        case .municipal: return "By-laws"
        default: return "Code Books"
        }
    }

    /// Creates the standard folders so they appear in Files right away.
    static func prepare() {
        for name in standardFolders {
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    struct Entry: Sendable, Hashable {
        /// Relative to Documents, e.g. "Code Books/CSA B149.1-25.pdf".
        let path: String
        let size: Int64
        let modified: Date
    }

    /// Every PDF under Documents (hidden items and the system Inbox skipped).
    static func listPDFs() -> [Entry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var entries: [Entry] = []
        for case let url as URL in enumerator {
            let relative = relativePath(of: url)
            if relative == "Inbox" || relative.hasPrefix("Inbox/") {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "pdf",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            entries.append(Entry(
                path: relative,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            ))
        }
        return entries
    }

    static func relativePath(of url: URL) -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard full.hasPrefix(base) else { return url.lastPathComponent }
        return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func contains(_ url: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        return url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(base + "/")
    }

    /// A free file name for a PDF the app adds, in its category's folder.
    static func destination(for title: String, category: CodeCategory) -> (url: URL, path: String) {
        let folder = folderName(for: category)
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = safeFileName(title)
        var name = base + ".pdf"
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(base) \(counter).pdf"
            counter += 1
        }
        return (directory.appendingPathComponent(name), folder + "/" + name)
    }

    static func safeFileName(_ title: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        let cleaned = title.components(separatedBy: unsafe).joined(separator: "-")
        let trimmed = String(cleaned.prefix(100)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? "Code Book" : trimmed
    }

    /// The title a PDF gets from its file name ("Code Books/CSA_B149.1.pdf" -> "CSA B149.1").
    static func title(fromPath path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// A category implied by the folder a PDF was put in, if any.
    static func categoryHint(forPath path: String) -> CodeCategory? {
        guard path.contains("/") else { return nil }
        let top = path.split(separator: "/").first.map { $0.lowercased() } ?? ""
        if top.contains("manufacturer") || top.contains("manual") || top.contains("instruction") { return .manufacturer }
        if top.contains("bulletin") || top.contains("advisor") { return .bulletin }
        if top.contains("by-law") || top.contains("bylaw") { return .municipal }
        return nil
    }
}

/// Watches Documents and its top-level folders for files added, removed or renamed in Files.
@MainActor
final class DocumentsWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// (Re)starts watching; call again after folders are added so they're watched too.
    func start() {
        stop()
        var folders = [DocumentsFolder.root]
        if let items = try? FileManager.default.contentsOfDirectory(
            at: DocumentsFolder.root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            folders += items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        for folder in folders {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .link],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onChange()
                }
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        for source in sources { source.cancel() }
        sources.removeAll()
    }
}
