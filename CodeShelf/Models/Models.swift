import Foundation

/// Broad grouping used to organize the library and filter searches.
enum CodeCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case building
    case residential
    case fire
    case electrical
    case plumbing
    case mechanical
    case gas
    case energy
    case accessibility
    case municipal
    case standard
    case bulletin
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .building: return "Building"
        case .residential: return "Residential"
        case .fire: return "Fire"
        case .electrical: return "Electrical"
        case .plumbing: return "Plumbing"
        case .mechanical: return "Mechanical"
        case .gas: return "Gas & Propane"
        case .energy: return "Energy"
        case .accessibility: return "Accessibility"
        case .municipal: return "Municipal By-laws"
        case .standard: return "Standards"
        case .bulletin: return "Bulletins & Updates"
        case .other: return "Other"
        }
    }

    /// What belongs in the category, shown when editing a book.
    var examples: String {
        switch self {
        case .building: return "Ontario Building Code (O. Reg. 163/24), Building Code Act, supplementary standards"
        case .residential: return "OBC Part 9 housing and small buildings, SB-12 guides"
        case .fire: return "Ontario Fire Code (O. Reg. 213/07), Fire Protection and Prevention Act, OFM technical guidelines"
        case .electrical: return "Ontario Electrical Safety Code (O. Reg. 164/99), Canadian Electrical Code (CSA C22.1)"
        case .plumbing: return "OBC Part 7 plumbing, Part 8 sewage systems"
        case .mechanical: return "CSA B52 refrigeration, B139 oil-burning equipment, HVAC"
        case .gas: return "CSA B149.1 Natural Gas and Propane Installation Code, B149.2 Propane Storage and Handling Code, Gaseous Fuels (O. Reg. 212/01), Propane Storage and Handling (O. Reg. 211/01), TSSA code adoption documents"
        case .energy: return "OBC SB-10, SB-12, NECB"
        case .accessibility: return "OBC barrier-free design, AODA standards, CSA B651"
        case .municipal: return "Your municipality's building, zoning, property standards, fence and pool by-laws"
        case .standard: return "NFPA, ASHRAE, ASTM, ULC and other CSA standards the codes reference"
        case .bulletin: return "ESA bulletins, CodeNews, TSSA advisories, OFM communiqués, CSA Memorandums of Revision"
        case .other: return "Anything else"
        }
    }

    var symbol: String {
        switch self {
        case .building: return "building.2"
        case .residential: return "house"
        case .fire: return "flame"
        case .electrical: return "bolt"
        case .plumbing: return "drop"
        case .mechanical: return "wind"
        case .gas: return "fuelpump"
        case .energy: return "leaf"
        case .accessibility: return "figure.roll"
        case .municipal: return "building.columns"
        case .standard: return "doc.text"
        case .bulletin: return "megaphone"
        case .other: return "book.closed"
        }
    }
}

/// A code book PDF stored in the app's library.
struct Book: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var shortName: String = ""
    var category: CodeCategory = .other
    var jurisdiction: String = ""
    var edition: String = ""
    var fileName: String
    var fileSize: Int64 = 0
    var pageCount: Int = 0
    var indexedPages: Int = 0
    var ocrPages: Int = 0
    var dateAdded: Date = Date()
    var lastPage: Int = 0
    var notes: String = ""
    /// Web address a page was saved from (municipal codes, bulletins). Empty for imported files.
    var sourceURL: String = ""

    init(title: String, fileName: String) {
        self.title = title
        self.fileName = fileName
    }

    var displayName: String {
        let short = shortName.trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? title : short
    }

    var subtitle: String {
        [jurisdiction, edition]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var isIndexed: Bool { indexedPages >= pageCount }

    enum CodingKeys: String, CodingKey {
        case id, title, shortName, category, jurisdiction, edition, fileName, fileSize
        case pageCount, indexedPages, ocrPages, dateAdded, lastPage, notes, sourceURL
    }

    // Tolerant decoding so future versions can add fields without wiping the library.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        shortName = try c.decodeIfPresent(String.self, forKey: .shortName) ?? ""
        category = (try? c.decodeIfPresent(CodeCategory.self, forKey: .category)) ?? .other
        jurisdiction = try c.decodeIfPresent(String.self, forKey: .jurisdiction) ?? ""
        edition = try c.decodeIfPresent(String.self, forKey: .edition) ?? ""
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        indexedPages = try c.decodeIfPresent(Int.self, forKey: .indexedPages) ?? 0
        ocrPages = try c.decodeIfPresent(Int.self, forKey: .ocrPages) ?? 0
        dateAdded = try c.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
        lastPage = try c.decodeIfPresent(Int.self, forKey: .lastPage) ?? 0
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
    }
}

/// A specific page in a specific book.
struct PageRef: Codable, Hashable, Sendable {
    var bookID: UUID
    var pageIndex: Int
}

struct Bookmark: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var bookID: UUID
    var pageIndex: Int
    var title: String
    var note: String = ""
    var created: Date = Date()
}

/// A named group of related pages across books, e.g. a model-code section
/// and the local amendment that modifies it.
struct CrossReference: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var note: String = ""
    var refs: [PageRef] = []
    var created: Date = Date()
}

/// Everything persisted to library.json.
struct LibraryData: Codable {
    var books: [Book]
    var bookmarks: [Bookmark]
    var crossRefs: [CrossReference]

    init(books: [Book] = [], bookmarks: [Bookmark] = [], crossRefs: [CrossReference] = []) {
        self.books = books
        self.bookmarks = bookmarks
        self.crossRefs = crossRefs
    }

    enum CodingKeys: String, CodingKey {
        case books, bookmarks, crossRefs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        books = try c.decodeIfPresent([Book].self, forKey: .books) ?? []
        bookmarks = (try? c.decodeIfPresent([Bookmark].self, forKey: .bookmarks)) ?? []
        crossRefs = (try? c.decodeIfPresent([CrossReference].self, forKey: .crossRefs)) ?? []
    }
}
