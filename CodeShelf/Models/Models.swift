import Foundation

/// Broad grouping used to organize the library and filter searches.
/// Declared fuel-industry first: this order is used for Library sections and search chips.
enum CodeCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case gas
    case oil
    case manufacturer
    case bulletin
    case building
    case residential
    case mechanical
    case fire
    case electrical
    case plumbing
    case energy
    case accessibility
    case municipal
    case standard
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
        case .oil: return "Fuel Oil & Petroleum"
        case .energy: return "Energy"
        case .accessibility: return "Accessibility"
        case .municipal: return "Municipal By-laws"
        case .standard: return "Standards"
        case .manufacturer: return "Manufacturer Instructions"
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
        case .mechanical: return "CSA B52 refrigeration, HVAC, ventilation"
        case .gas: return "CSA B149.1 Natural Gas and Propane Installation Code, B149.2 Propane Storage and Handling Code, Gaseous Fuels (O. Reg. 212/01), Propane Storage and Handling (O. Reg. 211/01), TSSA code adoption documents"
        case .energy: return "OBC SB-10, SB-12, NECB"
        case .accessibility: return "OBC barrier-free design, AODA standards, CSA B651"
        case .municipal: return "Your municipality's building, zoning, property standards, fence and pool by-laws"
        case .oil: return "CSA B139 Installation Code for Oil-Burning Equipment, Fuel Oil (O. Reg. 213/01), Liquid Fuels (O. Reg. 217/01), TSSA Liquid Fuels Handling Code, gasoline and diesel storage and dispensing"
        case .standard: return "NFPA, ASHRAE, ASTM, ULC and other CSA standards the codes reference"
        case .manufacturer: return "Installation, operation and service manuals for the equipment you install — furnaces, boilers, water heaters, oil burners and tanks, generators, panels"
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
        case .oil: return "drop.fill"
        case .energy: return "leaf"
        case .accessibility: return "figure.roll"
        case .municipal: return "building.columns"
        case .standard: return "doc.text"
        case .manufacturer: return "wrench.and.screwdriver"
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
    /// Manufacturer instructions: model numbers covered (free text, e.g. "AF100, AF120").
    var modelNumbers: String = ""
    /// Manufacturer instructions: kind of equipment, e.g. "Furnace".
    var equipmentType: String = ""
    /// ETag / Last-Modified of the downloaded copy, to spot newer versions online.
    var sourceVersion: String = ""
    /// True when `fileName` is a path inside Documents (On My iPhone › CodeShelf in Files);
    /// false for older copies kept in the app's private storage.
    var inDocuments: Bool = false
    /// Pages with searchable text after indexing; -1 until known. 0 means nothing can be found in it.
    var textPages: Int = -1

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
        case modelNumbers, equipmentType, sourceVersion, inDocuments, textPages
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
        modelNumbers = try c.decodeIfPresent(String.self, forKey: .modelNumbers) ?? ""
        equipmentType = try c.decodeIfPresent(String.self, forKey: .equipmentType) ?? ""
        sourceVersion = try c.decodeIfPresent(String.self, forKey: .sourceVersion) ?? ""
        inDocuments = try c.decodeIfPresent(Bool.self, forKey: .inDocuments) ?? false
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        textPages = try c.decodeIfPresent(Int.self, forKey: .textPages) ?? -1
    }

    /// Indexed, but no page had text to search (a scan that OCR couldn't read, or a locked file).
    var hasNoSearchableText: Bool { isIndexed && pageCount > 0 && textPages == 0 }
}

/// Details entered for a manufacturer's manual.
struct ManualInfo: Hashable, Sendable {
    static let equipmentTypes = [
        "CSST gas piping", "ULC S636 venting", "Propane regulator", "Relief valve", "Propane tank / cylinder",
        "Furnace", "Boiler", "Water heater", "Unit heater", "Fireplace / heater", "Generator",
        "Oil burner", "Oil tank", "Fuel dispenser / tank", "Air conditioner / heat pump",
        "HRV / ERV / ventilation", "Electrical panel / equipment", "Other",
    ]

    var manufacturer: String = ""
    var models: String = ""
    var equipmentType: String = "Furnace"
    /// The document's own title, when known (catalog entries).
    var documentTitle: String = ""

    var isEmpty: Bool {
        manufacturer.trimmingCharacters(in: .whitespaces).isEmpty && models.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// "Acme AF100" for the short name.
    var shortName: String {
        let firstModel = models.split(whereSeparator: { $0 == "," || $0 == ";" }).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return [manufacturer.trimmingCharacters(in: .whitespaces), firstModel].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Acme AF100, AF120 furnace installation instructions"
    var title: String {
        if !documentTitle.isEmpty { return documentTitle }
        let base = [manufacturer.trimmingCharacters(in: .whitespaces), models.trimmingCharacters(in: .whitespaces)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let kind = equipmentType == "Other" ? "" : equipmentType.lowercased() + " "
        return base.isEmpty ? "" : "\(base) \(kind)installation instructions"
    }

    func apply(to book: inout Book) {
        book.category = .manufacturer
        let maker = manufacturer.trimmingCharacters(in: .whitespaces)
        if !maker.isEmpty { book.jurisdiction = maker }
        book.modelNumbers = models.trimmingCharacters(in: .whitespaces)
        book.equipmentType = equipmentType
        if !shortName.isEmpty { book.shortName = shortName }
        if !title.isEmpty { book.title = title }
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
