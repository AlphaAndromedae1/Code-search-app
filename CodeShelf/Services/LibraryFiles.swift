import Foundation
import PDFKit

/// File operations that run off the main thread.
enum LibraryFiles {
    enum ImportError: LocalizedError {
        case unreadable
        case empty
        case locked
        case protected(String)
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "This file isn't a readable PDF. If it came from a cloud drive, open it once in the Files app so it's fully downloaded, then try again."
            case .empty:
                return "This PDF has no pages."
            case .locked:
                return "This PDF needs a password to open. Remove the password (for example by printing it to a new PDF in Adobe Reader) and import it again."
            case .protected(let system):
                return "This PDF is locked with \(system) copy protection (DRM). Only the publisher's approved reader (usually Adobe Acrobat Reader with a plug-in) can open it, so no other app — including CodeShelf — can display or search it. Check whether the seller offers an unprotected PDF, an online version, or print."
            case .copyFailed(let reason):
                return "Couldn't copy the file into CodeShelf: \(reason)"
            }
        }
    }

    struct WrittenFile: Sendable {
        let id: UUID
        let fileName: String
        let pageCount: Int
        let fileSize: Int64
    }

    /// Stores PDF data (e.g. a saved web page) in the library folder.
    static func writePDF(_ data: Data) throws -> WrittenFile {
        let id = UUID()
        let fileName = id.uuidString + ".pdf"
        let destination = AppPaths.books.appendingPathComponent(fileName)
        try data.write(to: destination, options: .atomic)
        do {
            let document = try openChecked(destination)
            return WrittenFile(id: id, fileName: fileName, pageCount: document.pageCount, fileSize: Int64(data.count))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Copies a PDF into the app's library folder and builds its initial metadata.
    /// `log` receives a line per step so failures can be diagnosed from Settings.
    static func copyIntoLibrary(_ source: URL, log: (String) -> Void = { _ in }) throws -> Book {
        let id = UUID()
        let fileName = id.uuidString + ".pdf"
        let destination = AppPaths.books.appendingPathComponent(fileName)

        try coordinatedCopy(from: source, to: destination, log: log)
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        log("Copied \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")

        let document: PDFDocument
        do {
            document = try openChecked(destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        log("Opened PDF: \(document.pageCount) pages")

        var book = makeBook(from: document, sourceName: source.deletingPathExtension().lastPathComponent, fileName: fileName, size: size)
        book.id = id
        return book
    }

    /// Checks a PDF that is already in the Files folder and builds its metadata, without copying it.
    static func inspectInPlace(_ url: URL) throws -> Book {
        let document = try openChecked(url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return makeBook(from: document, sourceName: url.deletingPathExtension().lastPathComponent, fileName: "", size: size)
    }

    private static func makeBook(from document: PDFDocument, sourceName: String, fileName: String, size: Int64) -> Book {
        let cleanedName = sourceName
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        var book = Book(title: cleanedName.isEmpty ? "Untitled Code Book" : cleanedName, fileName: fileName)
        book.pageCount = document.pageCount
        book.fileSize = size

        let pdfTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        let guess = MetadataGuesser.guess(from: sourceName + " " + pdfTitle)
        book.category = guess.category
        book.shortName = guess.shortName
        book.edition = guess.edition
        book.jurisdiction = guess.jurisdiction
        return book
    }

    /// Copies through NSFileCoordinator so files in iCloud Drive, OneDrive, Google Drive, etc.
    /// are downloaded before reading.
    private static func coordinatedCopy(from source: URL, to destination: URL, log: (String) -> Void) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
            do {
                try FileManager.default.copyItem(at: readableURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            log("Copy failed: \(error.localizedDescription)")
            // Some providers refuse coordination; try a plain copy before giving up.
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
                log("Plain copy succeeded")
            } catch {
                throw ImportError.copyFailed(error.localizedDescription)
            }
        }
    }

    /// Opens a PDF and explains clearly why it can't be used, if it can't.
    static func openChecked(_ url: URL) throws -> PDFDocument {
        let drm = protectionSystem(of: url)
        if let drm { throw ImportError.protected(drm) }
        guard let document = PDFDocument(url: url) else {
            throw ImportError.unreadable
        }
        if document.isLocked && !document.unlock(withPassword: "") {
            throw ImportError.locked
        }
        guard document.pageCount > 0 else { throw ImportError.empty }
        return document
    }

    /// Recognizes third-party DRM security handlers that no PDF reader except the publisher's can open.
    static func protectionSystem(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let markers: [(bytes: String, name: String)] = [
            ("/FOPN", "FileOpen"),
            ("Adobe.APS", "Adobe LiveCycle Rights Management"),
            ("/VitriumSecurity", "Vitrium"),
            ("/HaihaiSecurity", "HaihaiSoft"),
        ]
        for marker in markers where data.range(of: Data(marker.bytes.utf8)) != nil {
            return marker.name
        }
        return nil
    }
}

/// Best-effort guess of category / short name / edition from a file name like
/// "2024_OBC.pdf", "OESC 2024.pdf", "O. Reg. 213-07 Fire Code.pdf" or "City of Ottawa Building By-law.pdf".
/// Everything can be edited later.
enum MetadataGuesser {
    struct Guess {
        var category: CodeCategory = .other
        var shortName = ""
        var edition = ""
        var jurisdiction = ""
    }

    /// Full names — checked first because they're the most specific.
    private static let phrases: [(text: String, category: CodeCategory, code: String, publisher: String)] = [
        ("ONTARIO ELECTRICAL SAFETY CODE", .electrical, "OESC", "ESA"),
        ("CANADIAN ELECTRICAL CODE", .electrical, "CE Code", "CSA"),
        ("C22.1", .electrical, "CE Code", "CSA"),
        ("ONTARIO BUILDING CODE", .building, "OBC", "Ontario"),
        ("NATIONAL BUILDING CODE", .building, "NBC", "NRC"),
        ("NATIONAL FIRE CODE", .fire, "NFC", "NRC"),
        ("NATIONAL PLUMBING CODE", .plumbing, "NPC", "NRC"),
        ("NATIONAL ENERGY CODE", .energy, "NECB", "NRC"),
        ("ONTARIO FIRE CODE", .fire, "OFC", "Ontario"),
        ("BUILDING CODE ACT", .building, "Building Code Act", "Ontario"),
        ("FIRE PROTECTION AND PREVENTION ACT", .fire, "FPPA", "Ontario"),
        ("GASEOUS FUELS", .gas, "Gaseous Fuels Reg. 212/01", "Ontario"),
        ("LIQUID FUELS HANDLING CODE", .oil, "LFHC", "TSSA"),
        ("OIL-BURNING EQUIPMENT", .oil, "B139", "CSA"),
        ("OIL BURNING EQUIPMENT", .oil, "B139", "CSA"),
        ("NATURAL GAS AND PROPANE", .gas, "B149.1", "CSA"),
        ("PROPANE STORAGE AND HANDLING", .gas, "B149.2", "CSA"),
        ("FIELD APPROVAL OF FUEL", .gas, "B149.3", "CSA"),
        ("PROPANE FUEL SYSTEMS", .gas, "B149.5", "CSA"),
        ("DIGESTER GAS", .gas, "B149.6", "CSA"),
        ("BIOGAS", .gas, "B149.6", "CSA"),
        ("SB-12", .energy, "SB-12", "Ontario"),
        ("SB-10", .energy, "SB-10", "Ontario"),
    ]

    /// Short names as they usually appear in file names.
    private static let acronyms: [(code: String, category: CodeCategory, publisher: String)] = [
        ("OESC", .electrical, "ESA"),
        ("CEC", .electrical, "CSA"),
        ("OBC", .building, "Ontario"),
        ("NBC", .building, "NRC"),
        ("NBCC", .building, "NRC"),
        ("NFC", .fire, "NRC"),
        ("NFCC", .fire, "NRC"),
        ("OFC", .fire, "Ontario"),
        ("NPC", .plumbing, "NRC"),
        ("NPCC", .plumbing, "NRC"),
        ("NECB", .energy, "NRC"),
        ("B149", .gas, "CSA"),
        ("B52", .mechanical, "CSA"),
        ("B139", .oil, "CSA"),
        ("LFHC", .oil, "TSSA"),
        ("B651", .accessibility, "CSA"),
        ("AODA", .accessibility, "Ontario"),
        ("TSSA", .gas, "TSSA"),
        // Standards referenced by Canadian codes
        ("ULC", .standard, "ULC"),
        ("CSA", .standard, "CSA"),
        ("NFPA", .standard, "NFPA"),
        ("ASHRAE", .standard, "ASHRAE"),
        ("ASTM", .standard, "ASTM"),
    ]

    /// Generic words, used only when nothing more specific matched.
    private static let words: [(text: String, category: CodeCategory)] = [
        ("ACCESSIB", .accessibility),
        ("ELECTRICAL", .electrical),
        ("PLUMBING", .plumbing),
        ("MECHANICAL", .mechanical),
        ("HVAC", .mechanical),
        ("PROPANE", .gas),
        ("NATURAL GAS", .gas),
        ("FURNACE OIL", .oil),
        ("HEATING OIL", .oil),
        ("FUEL OIL", .oil),
        ("OIL BURNER", .oil),
        ("OIL TANK", .oil),
        ("LIQUID FUEL", .oil),
        ("GASOLINE", .oil),
        ("DIESEL", .oil),
        ("PETROLEUM", .oil),
        ("FIRE", .fire),
        ("ENERGY", .energy),
        ("RESIDENTIAL", .residential),
        ("HOUSING", .residential),
        ("BUILDING", .building),
    ]

    private static let bulletinHints = [
        "BULLETIN", "MEMORANDUM OF REVISION", "CODENEWS", "CODE NEWS", "INTERPRETATION",
        "ERRATA", "TECHNICAL INFORMATION", "TECHNICAL GUIDELINE", "ADVISORY", "NOTICE OF AMENDMENT",
    ]

    private static let manualHints = [
        "INSTALLATION INSTRUCTIONS", "INSTALLATION MANUAL", "INSTALLATION AND OPERATION", "INSTALLATION, OPERATION",
        "INSTALLATION & OPERATION", "OWNER'S MANUAL", "OWNERS MANUAL", "USER MANUAL", "USER'S MANUAL",
        "SERVICE MANUAL", "OPERATING INSTRUCTIONS", "INSTALLER'S GUIDE", "INSTALLATION GUIDE", "SPEC SHEET",
    ]

    private static let municipalHints = [
        "BY-LAW", "BYLAW", "BY LAW", "MUNICIPAL CODE", "MUNICIPALITY", "CITY OF", "TOWN OF", "TOWNSHIP",
        "REGION OF", "REGIONAL MUNICIPALITY", "COUNTY OF", "VILLAGE OF", "ZONING", "PROPERTY STANDARDS",
    ]

    static func guess(from raw: String) -> Guess {
        var result = Guess()
        let upper = raw.uppercased()
        let tokens = upper
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        if let range = upper.range(of: "(?<![0-9])(19|20)[0-9]{2}(?![0-9])", options: .regularExpression) {
            result.edition = String(upper[range])
        } else if let year = designationYear(in: upper) {
            // CSA/ULC/ASTM designations end in a 2-digit year: "B149.1-25", "C22.1:24", "S524-19".
            result.edition = year
        }

        func hasToken(_ code: String) -> Bool {
            tokens.contains { token in
                token == code || (token.hasPrefix(code) && token.dropFirst(code.count).allSatisfy { $0.isNumber })
            }
        }

        var code = ""
        if let match = regulations.first(where: { citation(upper, matches: $0.number) }) {
            // Ontario regulation citations, e.g. "O. Reg. 213/07" or "O Reg 213-07".
            result.category = match.category
            result.jurisdiction = "Ontario"
            code = match.code
        } else if let match = phrases.first(where: { upper.contains($0.text) }) {
            result.category = match.category
            result.jurisdiction = match.publisher
            code = match.code
        } else if let match = acronyms.first(where: { hasToken($0.code) }) {
            result.category = match.category
            result.jurisdiction = match.publisher
            code = match.code
            // "NFPA 13", "ASHRAE 90.1", "ASTM E119", "CSA Z462", "CAN/ULC-S524": keep the standard's number.
            if ["CSA", "NFPA", "ULC", "ASHRAE", "ASTM"].contains(code), let number = designation(after: code, in: upper) {
                code = "\(code) \(number)"
            }
        } else if let match = words.first(where: { upper.contains($0.text) }) {
            result.category = match.category
        }

        // Name the specific part of the gas code: B149.1 installation, B149.2 propane storage, etc.
        if code == "B149" || result.category == .gas,
           let range = upper.range(of: "B149[ .-]?[1-6](?![0-9])", options: .regularExpression),
           let part = upper[range].last {
            code = "B149.\(part)"
            result.category = .gas
            result.jurisdiction = "CSA"
        }

        // Equipment manuals: "Acme AF100 Installation Instructions", "Owner's Manual", "IOM".
        if manualHints.contains(where: { upper.contains($0) }) || tokens.contains("IOM") {
            result.category = .manufacturer
            result.jurisdiction = ""
            result.shortName = ""
            return result
        }

        if municipalHints.contains(where: { upper.contains($0) }) {
            result.category = .municipal
            result.jurisdiction = ""
            code = ""
        }

        // ESA bulletins are numbered like "26-7-11" (rule section - bulletin - revision).
        let numberPattern = "(?<![0-9-])[0-9]{1,2}-[0-9]{1,3}-[0-9]{1,3}(?![0-9-])"
        let bareName = raw.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
        let nameIsBulletinNumber = bareName.range(of: "^" + numberPattern + "$", options: .regularExpression) != nil
        let mentionsBulletin = bulletinHints.contains(where: { upper.contains($0) }) || tokens.contains("MOR")
        if nameIsBulletinNumber || mentionsBulletin {
            result.category = .bulletin
            if let range = raw.range(of: numberPattern, options: .regularExpression) {
                let number = String(raw[range])
                if code.isEmpty || code == "OESC" {
                    result.jurisdiction = "ESA"
                    code = "Bulletin \(number)"
                } else {
                    code = "\(code) Bulletin \(number)"
                }
            } else {
                code = code.isEmpty ? "" : "\(code) update"
            }
            result.shortName = code
            return result
        }

        if !code.isEmpty {
            result.shortName = result.edition.isEmpty ? code : "\(code) \(result.edition)"
        }
        return result
    }

    /// Ontario regulations that adopt the codes.
    private static let regulations: [(number: String, category: CodeCategory, code: String)] = [
        ("163/24", .building, "OBC"),
        ("332/12", .building, "OBC 2012"),
        ("213/07", .fire, "OFC"),
        ("164/99", .electrical, "OESC"),
        ("212/01", .gas, "Gaseous Fuels Reg. 212/01"),
        ("211/01", .gas, "Propane Reg. 211/01"),
        ("213/01", .oil, "Fuel Oil Reg. 213/01"),
        ("217/01", .oil, "Liquid Fuels Reg. 217/01"),
    ]

    /// True when the text cites "O. Reg. 163/24" (also written "O Reg 163-24" in file names).
    private static func citation(_ upper: String, matches number: String) -> Bool {
        let parts = number.split(separator: "/")
        guard parts.count == 2 else { return false }
        let pattern = "O\\.?\\s*REG\\.?\\s*" + String(parts[0]) + "\\s*[/-]\\s*" + String(parts[1]) + "(?![0-9])"
        return upper.range(of: pattern, options: .regularExpression) != nil
    }

    /// The number that follows a standards body's name, e.g. "90.1" in "ASHRAE 90.1-2019".
    private static func designation(after body: String, in upper: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\b" + body + "[\\s/-]*(?:STANDARD|STD\\.?)?[\\s/-]*([A-Z]{0,2}[0-9]+(?:\\.[0-9]+)*[A-Z]?)") else { return nil }
        let ns = upper as NSString
        guard let match = regex.firstMatch(in: upper, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// "B149.1-25" / "C22.1:24" / "S524-19" -> "2025" / "2024" / "2019".
    private static func designationYear(in upper: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "[A-Z][0-9]+(?:\\.[0-9]+)?[:-]([0-9]{2})(?![0-9])") else { return nil }
        let ns = upper as NSString
        guard let match = regex.firstMatch(in: upper, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1
        else { return nil }
        return "20" + ns.substring(with: match.range(at: 1))
    }
}
