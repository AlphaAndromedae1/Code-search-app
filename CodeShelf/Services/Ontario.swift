import Foundation

/// A web page to open in the in-app browser.
struct WebSource: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let url: URL
}

enum WebLinks {
    static func webSearch(_ query: String) -> URL {
        var components = URLComponents(string: "https://www.google.ca/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }
}

/// Ontario's codes as published on e-Laws, the official source of Ontario statutes and regulations.
struct OntarioLaw: Identifiable, Hashable {
    let id: String
    let name: String
    let citation: String
    let detail: String
    let address: String
    let category: CodeCategory
    /// Short name used when the page is saved to the library.
    let shortName: String

    var url: URL? { URL(string: address) }
}

enum Ontario {
    static let name = "Ontario"
    static let code = "ON"

    static let laws: [OntarioLaw] = [
        OntarioLaw(
            id: "obc-reg",
            name: "Building Code",
            citation: "O. Reg. 163/24",
            detail: "Adopts the 2024 Ontario Building Code; its amending regulations are listed here",
            address: "https://www.ontario.ca/laws/regulation/240163",
            category: .building,
            shortName: "OBC Reg. 163/24"
        ),
        OntarioLaw(
            id: "building-code-act",
            name: "Building Code Act, 1992",
            citation: "S.O. 1992, c. 23",
            detail: "Permits, inspections, orders and the powers of chief building officials",
            address: "https://www.ontario.ca/laws/statute/92b23",
            category: .building,
            shortName: "Building Code Act"
        ),
        OntarioLaw(
            id: "fire-code",
            name: "Fire Code",
            citation: "O. Reg. 213/07",
            detail: "The full Ontario Fire Code text — save it to search it with your other codes",
            address: "https://www.ontario.ca/laws/regulation/070213",
            category: .fire,
            shortName: "OFC"
        ),
        OntarioLaw(
            id: "fppa",
            name: "Fire Protection and Prevention Act, 1997",
            citation: "S.O. 1997, c. 4",
            detail: "Fire marshal and fire department powers, inspections and orders",
            address: "https://www.ontario.ca/laws/statute/97f04",
            category: .fire,
            shortName: "FPPA"
        ),
        OntarioLaw(
            id: "oesc-reg",
            name: "Electrical Safety Code",
            citation: "O. Reg. 164/99",
            detail: "Adopts the OESC (CE Code Part I with Ontario amendments) under the Electricity Act",
            address: "https://www.ontario.ca/laws/regulation/990164",
            category: .electrical,
            shortName: "OESC Reg. 164/99"
        ),
        OntarioLaw(
            id: "gaseous-fuels",
            name: "Gaseous Fuels",
            citation: "O. Reg. 212/01",
            detail: "Natural gas and propane appliances and piping; adopts CSA B149 through TSSA's code adoption document",
            address: "https://www.ontario.ca/laws/regulation/010212",
            category: .gas,
            shortName: "Gaseous Fuels Reg. 212/01"
        ),
        OntarioLaw(
            id: "propane-storage",
            name: "Propane Storage and Handling",
            citation: "O. Reg. 211/01",
            detail: "Storage, handling, transportation and transfer of propane (CSA B149.2)",
            address: "https://www.ontario.ca/laws/regulation/010211",
            category: .gas,
            shortName: "Propane Reg. 211/01"
        ),
    ]

    static func law(id: String) -> OntarioLaw? {
        laws.first { $0.id == id }
    }
}

/// Where to look for an Ontario municipality's by-laws. Each municipality publishes its own,
/// so these are targeted searches.
enum MunicipalSources {
    static func sources(city rawCity: String) -> [WebSource] {
        let city = rawCity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty else { return [] }
        return [
            WebSource(
                id: "search-bylaws",
                name: "\(city) by-laws",
                detail: "Finds your municipality's official by-law page",
                url: WebLinks.webSearch("\(city) Ontario by-laws")
            ),
            WebSource(
                id: "search-building-bylaw",
                name: "Building, zoning & property standards",
                detail: "The by-laws that most often affect construction work",
                url: WebLinks.webSearch("\(city) Ontario building by-law zoning by-law property standards by-law")
            ),
            WebSource(
                id: "search-building-dept",
                name: "Building division",
                detail: "Permits, permit fees, inspections and guides from your municipality",
                url: WebLinks.webSearch("\(city) Ontario building division building permits")
            ),
            WebSource(
                id: "search-other-bylaws",
                name: "Fence, pool, sign & tree by-laws",
                detail: "Other by-laws that commonly apply to residential projects",
                url: WebLinks.webSearch("\(city) Ontario fence by-law pool enclosure by-law sign by-law tree by-law")
            ),
            WebSource(
                id: "search-region-bylaws",
                name: "Region / county by-laws",
                detail: "Upper-tier rules (e.g. sewer use, regional roads) if your municipality is in a region or county",
                url: WebLinks.webSearch("\(city) Ontario region OR county by-laws sewer use")
            ),
        ]
    }
}
