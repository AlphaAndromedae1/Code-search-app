import Foundation
import SwiftUI

/// Weekly retail fuel prices in Ontario (cents per litre, taxes included).
///
/// - Gasoline, diesel and auto propane: Ontario Ministry of Energy fuel price survey (open data CSV, updated every Monday).
/// - Furnace oil: Natural Resources Canada weekly retail prices (RSS feeds by city).
/// - Dyed (coloured) diesel: estimated from clear diesel, since no public survey publishes it.
struct FuelPriceSnapshot: Codable, Sendable {
    struct Series: Codable, Sendable {
        /// Most recent survey date, e.g. "2026-11-16".
        var date: String
        var previousDate: String
        /// Value for each market column (0 when that market wasn't surveyed).
        var values: [Double]
        var previous: [Double]
    }

    struct CityReading: Codable, Sendable, Identifiable {
        var city: String
        var locationID: Int
        var dollarsPerLitre: Double
        var date: Date

        var id: Int { locationID }
        var centsPerLitre: Double { dollarsPerLitre * 100 }
    }

    /// Market names from the CSV header ("Ottawa", "Toronto West/Ouest", … "Ontario Average/Moyenne provinciale").
    var markets: [String]
    /// Keyed by the CSV's English fuel name.
    var series: [String: Series]
    var furnaceOil: [CityReading]
    var fetched: Date
}

struct FuelPriceRow: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String
    let cents: Double?
    let change: Double?
    let date: String
    let source: String
    let note: String?
    let isEstimate: Bool
}

@MainActor
@Observable
final class FuelPriceStore {
    static let shared = FuelPriceStore()

    static let marketKey = "fuelPriceMarket"
    static let dyedDiscountKey = "dyedDieselDiscount"
    /// Ontario's clear diesel fuel tax (9.0¢/L) plus 13% HST on it; coloured fuel doesn't pay it.
    static let defaultDyedDiscount = 10.2
    static let averageMarket = "Ontario Average/Moyenne provinciale"

    private(set) var snapshot: FuelPriceSnapshot?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private static var cacheURL: URL { AppPaths.root.appendingPathComponent("fuel-prices.json") }

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snapshot = try? decoder.decode(FuelPriceSnapshot.self, from: data)
        }
    }

    var isStale: Bool {
        guard let snapshot else { return true }
        return Date().timeIntervalSince(snapshot.fetched) > 6 * 3600
    }

    func refreshIfStale() async {
        if isStale { await refresh() }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        async let ontario = FuelPriceSources.loadOntario()
        async let oil = FuelPriceSources.loadFurnaceOil()
        let (survey, readings) = await (ontario, oil)

        guard let survey else {
            errorMessage = "Couldn't download Ontario's fuel price survey. Showing the last prices saved."
            return
        }
        let fresh = FuelPriceSnapshot(
            markets: survey.markets,
            series: survey.series,
            furnaceOil: readings.isEmpty ? (snapshot?.furnaceOil ?? []) : readings,
            fetched: Date()
        )
        snapshot = fresh
        if readings.isEmpty {
            errorMessage = "Couldn't reach Natural Resources Canada for furnace oil prices."
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(fresh) {
            try? FileManager.default.createDirectory(at: AppPaths.root, withIntermediateDirectories: true)
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    // MARK: - Rows for the screen

    static func displayName(ofMarket market: String) -> String {
        let english = market.split(separator: "/").first.map(String.init) ?? market
        switch english {
        case "Ontario Average": return "Ontario average"
        case "Southern Average": return "Southern Ontario average"
        case "Northern Average": return "Northern Ontario average"
        case "St. Catharine's": return "St. Catharines"
        case "Sault Saint Marie": return "Sault Ste. Marie"
        default: return english
        }
    }

    /// The NRCan city to use for furnace oil in a survey market.
    private static func nrcanCity(forMarket market: String) -> Int? {
        let name = displayName(ofMarket: market)
        if name.hasPrefix("Toronto") { return 17 }
        return FuelPriceSources.nrcanCities.first { $0.name == name }?.id
    }

    func rows(market: String, dyedDiscount: Double) -> [FuelPriceRow] {
        guard let snapshot else { return [] }
        let column = snapshot.markets.firstIndex(of: market) ?? snapshot.markets.firstIndex(of: Self.averageMarket) ?? 0
        let averageColumn = snapshot.markets.firstIndex(of: Self.averageMarket) ?? column
        let marketName = Self.displayName(ofMarket: snapshot.markets.indices.contains(column) ? snapshot.markets[column] : market)

        func surveyRow(id: String, fuel: String, name: String, detail: String) -> FuelPriceRow? {
            guard let series = snapshot.series[fuel] else { return nil }
            var value = series.values[safe: column] ?? 0
            var previous = series.previous[safe: column] ?? 0
            var note: String?
            if value <= 0 {
                value = series.values[safe: averageColumn] ?? 0
                previous = series.previous[safe: averageColumn] ?? 0
                note = "\(marketName) isn't surveyed for this fuel — showing the Ontario average."
            }
            return FuelPriceRow(
                id: id, name: name, detail: detail,
                cents: value > 0 ? value : nil,
                change: value > 0 && previous > 0 ? value - previous : nil,
                date: series.date,
                source: "Ontario fuel price survey",
                note: note,
                isEstimate: false
            )
        }

        var rows: [FuelPriceRow] = []
        if let row = surveyRow(id: "propane", fuel: "Auto Propane", name: "Propane",
                               detail: "Auto propane at the pump. Delivered (tank) propane is priced by supplier contract.") {
            rows.append(row)
        }
        rows.append(furnaceOilRow(market: market, marketName: marketName))
        if let row = surveyRow(id: "regular", fuel: "Regular Unleaded Gasoline", name: "Gasoline — Regular", detail: "Regular unleaded") {
            rows.append(row)
        }
        if let row = surveyRow(id: "premium", fuel: "Premium Gasoline", name: "Gasoline — Premium", detail: "Premium unleaded") {
            rows.append(row)
        }
        if let diesel = surveyRow(id: "diesel", fuel: "Diesel", name: "Diesel", detail: "Clear (road) diesel") {
            rows.append(diesel)
            rows.append(FuelPriceRow(
                id: "dyed", name: "Dyed Diesel", detail: "Coloured diesel for off-road and farm use",
                cents: diesel.cents.map { max(0, $0 - dyedDiscount) },
                change: diesel.change,
                date: diesel.date,
                source: "Estimate from clear diesel",
                note: "No public survey reports dyed diesel. Estimated as clear diesel minus \(dyedDiscount.formatted(.number.precision(.fractionLength(1))))¢/L — Ontario's 9.0¢/L diesel tax plus HST on it, which coloured fuel doesn't pay. Change the amount below to match your supplier.",
                isEstimate: true
            ))
        }
        return rows
    }

    private func furnaceOilRow(market: String, marketName: String) -> FuelPriceRow {
        let readings = currentFurnaceOil
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let id = Self.nrcanCity(forMarket: market), let local = readings.first(where: { $0.locationID == id }) {
            return FuelPriceRow(
                id: "furnace", name: "Furnace Oil", detail: "Heating oil, \(local.city)",
                cents: local.centsPerLitre, change: nil, date: formatter.string(from: local.date),
                source: "Natural Resources Canada", note: nil, isEstimate: false
            )
        }
        guard !readings.isEmpty else {
            return FuelPriceRow(
                id: "furnace", name: "Furnace Oil", detail: "Heating oil",
                cents: nil, change: nil, date: "", source: "Natural Resources Canada",
                note: "No recent furnace oil prices were available.", isEstimate: false
            )
        }
        let average = readings.map(\.centsPerLitre).reduce(0, +) / Double(readings.count)
        let latest = readings.map(\.date).max() ?? Date()
        return FuelPriceRow(
            id: "furnace", name: "Furnace Oil", detail: "Heating oil, average of \(readings.count) Ontario cities",
            cents: average, change: nil, date: formatter.string(from: latest),
            source: "Natural Resources Canada",
            note: "NRCan doesn't survey furnace oil in \(marketName); this is the average of \(readings.map(\.city).joined(separator: ", ")).",
            isEstimate: false
        )
    }

    /// Furnace oil readings no more than three weeks older than the newest one.
    var currentFurnaceOil: [FuelPriceSnapshot.CityReading] {
        guard let readings = snapshot?.furnaceOil, let newest = readings.map(\.date).max() else { return [] }
        return readings
            .filter { newest.timeIntervalSince($0.date) <= 21 * 86400 }
            .sorted { $0.city < $1.city }
    }
}

/// Where the prices come from, and how they're read. Runs off the main thread.
enum FuelPriceSources {
    static let ontarioCSV = URL(string: "https://ontario.ca/v1/files/fuel-prices/fueltypesall.csv")!
    static let ontarioPage = URL(string: "https://www.ontario.ca/page/motor-fuel-prices")!
    static let nrcanPage = URL(string: "https://www2.nrcan.gc.ca/eneene/sources/pripri/prices_bycity_e.cfm?productID=7&locationID=66&frequency=W")!

    /// NRCan city IDs in Ontario. Not every city is surveyed for furnace oil every week.
    static let nrcanCities: [(name: String, id: Int)] = [
        ("Kingston", 72), ("North Bay", 24), ("Sault Ste. Marie", 22), ("Sudbury", 21), ("Thunder Bay", 23),
        ("Timmins", 25), ("Windsor", 19), ("Woodstock", 81), ("Toronto", 17), ("Ottawa", 18), ("London", 20),
        ("Peterborough", 76), ("St. Catharines", 27), ("Hamilton", 26), ("Barrie", 91), ("Kitchener", 94),
    ]

    struct Survey: Sendable {
        var markets: [String]
        var series: [String: FuelPriceSnapshot.Series]
    }

    static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("text/csv, application/rss+xml, */*", forHTTPHeaderField: "Accept")
        guard let result = try? await URLSession.shared.data(for: request),
              let http = result.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return result.0
    }

    /// Parses the CSV: Date, one column per market, …, Fuel Type, Type de carburant.
    static func parseOntarioCSV(_ text: String) -> (markets: [String], series: [String: FuelPriceSnapshot.Series])? {
        var lines = text.split(whereSeparator: \.isNewline).makeIterator()
        guard let headerLine = lines.next() else { return nil }
        let header = headerLine.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard header.first == "Date", let fuelColumn = header.firstIndex(of: "Fuel Type"), fuelColumn > 1 else { return nil }
        let markets = Array(header[1..<fuelColumn])

        var latest: [String: (date: String, values: [Double])] = [:]
        var previous: [String: (date: String, values: [Double])] = [:]
        while let line = lines.next() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > fuelColumn else { continue }
            let date = fields[0].trimmingCharacters(in: .whitespaces)
            let fuel = fields[fuelColumn].trimmingCharacters(in: .whitespaces)
            guard date.count == 10, !fuel.isEmpty else { continue }
            let values = fields[1..<fuelColumn].map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            if let current = latest[fuel] {
                guard date >= current.date else { continue }
                if date > current.date { previous[fuel] = current }
            }
            latest[fuel] = (date, values)
        }
        guard !latest.isEmpty else { return nil }
        var series: [String: FuelPriceSnapshot.Series] = [:]
        for (fuel, current) in latest {
            let before = previous[fuel]
            series[fuel] = FuelPriceSnapshot.Series(
                date: current.date,
                previousDate: before?.date ?? "",
                values: current.values,
                previous: before?.values ?? []
            )
        }
        return (markets, series)
    }

    static func loadOntario() async -> Survey? {
        guard let data = await fetch(ontarioCSV) else { return nil }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let parsed = parseOntarioCSV(text)
        else { return nil }
        return Survey(markets: parsed.markets, series: parsed.series)
    }

    /// First item with a price in an NRCan RSS feed: <description>$2.79</description><pubDate>Tue, 10 Nov 2026</pubDate>.
    static func parseNRCanFeed(_ text: String) -> (dollars: Double, date: Date)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy"
        for item in text.components(separatedBy: "<item>").dropFirst() {
            guard let description = between(item, "<description>", "</description>"),
                  let value = Double(description.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)),
                  value > 0,
                  let dateText = between(item, "<pubDate>", "</pubDate>"),
                  let date = formatter.date(from: dateText.trimmingCharacters(in: .whitespaces))
            else { continue }
            return (value, date)
        }
        return nil
    }

    private static func between(_ text: String, _ start: String, _ end: String) -> String? {
        guard let from = text.range(of: start), let to = text.range(of: end, range: from.upperBound..<text.endIndex) else { return nil }
        return String(text[from.upperBound..<to.lowerBound])
    }

    static func loadFurnaceOil() async -> [FuelPriceSnapshot.CityReading] {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        return await withTaskGroup(of: FuelPriceSnapshot.CityReading?.self) { group in
            for city in nrcanCities {
                group.addTask {
                    // Early in January this year's feed can be empty, so fall back to last year's.
                    for priceYear in [year, year - 1] {
                        guard let url = URL(string: "https://www2.nrcan.gc.ca/eneene/sources/pripri/webfeed_e.cfm?priceYear=\(priceYear)&productID=7&locationID=\(city.id)"),
                              let data = await fetch(url),
                              let text = String(data: data, encoding: .utf8)
                        else { return nil }
                        if let reading = parseNRCanFeed(text) {
                            return FuelPriceSnapshot.CityReading(city: city.name, locationID: city.id, dollarsPerLitre: reading.dollars, date: reading.date)
                        }
                    }
                    return nil
                }
            }
            var readings: [FuelPriceSnapshot.CityReading] = []
            for await reading in group {
                if let reading { readings.append(reading) }
            }
            return readings
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
