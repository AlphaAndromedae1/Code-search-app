import Foundation
import Security
import SwiftUI

/// Weekly retail fuel prices in Ontario (cents per litre, taxes included).
///
/// - Gasoline, diesel and auto propane: Ontario Ministry of Energy fuel price survey (open data CSV, updated every Monday).
/// - Furnace oil: Natural Resources Canada weekly retail prices (RSS feeds by city), with Statistics Canada's
///   monthly household heating fuel prices (Toronto, Ottawa, Thunder Bay) as a second source.
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
        /// "NRCan" (weekly) or "Statistics Canada" (monthly).
        var source: String? = nil

        var id: Int { locationID }
        var centsPerLitre: Double { dollarsPerLitre * 100 }
    }

    /// Market names from the CSV header ("Ottawa", "Toronto West/Ouest", … "Ontario Average/Moyenne provinciale").
    var markets: [String]
    /// Keyed by the CSV's English fuel name.
    var series: [String: Series]
    /// Weekly furnace oil prices by city (NRCan).
    var furnaceOil: [CityReading]
    /// Monthly household heating fuel prices by city (Statistics Canada table 18-10-0001-01).
    var heatingMonthly: [CityReading]? = nil
    /// Why furnace oil prices couldn't be downloaded, if they couldn't.
    var furnaceProblem: String? = nil
    /// Natural gas supply charges by utility / rate zone (Ontario Energy Board), ¢/m³.
    var naturalGas: [GasRate]? = nil
    /// "October 1, 2026": when those rates took effect.
    var naturalGasEffective: String? = nil
    var naturalGasProblem: String? = nil
    var fetched: Date

    struct GasRate: Codable, Sendable, Identifiable, Hashable {
        var utility: String
        var centsPerCubicMetre: Double
        var id: String { utility }
    }
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
    /// "L" (cents per litre) or "m³" (cents per cubic metre, natural gas).
    var per: String = "L"
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
    static let gasUtilityKey = "naturalGasUtility"
    static let defaultGasUtility = "Enbridge Gas Inc."

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
        // Saved before furnace oil loaded (or by an older version): try again right away.
        if snapshot.heatingMonthly == nil || (snapshot.furnaceOil.isEmpty && (snapshot.heatingMonthly ?? []).isEmpty)
            || (snapshot.naturalGas ?? []).isEmpty {
            return true
        }
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
        async let weekly = FuelPriceSources.loadFurnaceOil()
        async let monthly = FuelPriceSources.loadStatCanHeatingFuel()
        async let gas = FuelPriceSources.loadOEBNaturalGas()
        let (surveyResult, oil, heating, gasRates) = await (ontario, weekly, monthly, gas)

        guard let survey = surveyResult.value else {
            errorMessage = "Couldn't download Ontario's fuel price survey (\(surveyResult.problem ?? "no data")). Showing the last prices saved."
            return
        }
        var problems: [String] = []
        if oil.readings.isEmpty { problems.append("NRCan: \(oil.problem ?? "no prices listed")") }
        if heating.readings.isEmpty { problems.append("Statistics Canada: \(heating.problem ?? "no prices listed")") }
        let fresh = FuelPriceSnapshot(
            markets: survey.markets,
            series: survey.series,
            furnaceOil: oil.readings.isEmpty ? (snapshot?.furnaceOil ?? []) : oil.readings,
            heatingMonthly: heating.readings.isEmpty ? snapshot?.heatingMonthly : heating.readings,
            furnaceProblem: problems.isEmpty ? nil : problems.joined(separator: "; "),
            naturalGas: gasRates.value?.rates ?? snapshot?.naturalGas,
            naturalGasEffective: gasRates.value?.effective ?? snapshot?.naturalGasEffective,
            naturalGasProblem: gasRates.problem,
            fetched: Date()
        )
        snapshot = fresh
        if oil.readings.isEmpty && heating.readings.isEmpty {
            errorMessage = "Couldn't download furnace oil prices. \(problems.joined(separator: "; "))."
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

    /// The natural gas utility / rate zone picked on the Fuel Prices screen.
    var gasUtility: String {
        UserDefaults.standard.string(forKey: Self.gasUtilityKey) ?? Self.defaultGasUtility
    }

    private func naturalGasRow(utility: String) -> FuelPriceRow {
        let rates = snapshot?.naturalGas ?? []
        let rate = rates.first { $0.utility == utility } ?? rates.first { $0.utility == Self.defaultGasUtility } ?? rates.first
        guard let rate else {
            return FuelPriceRow(
                id: "naturalgas", name: "Natural Gas", detail: "Gas supply charge",
                cents: nil, change: nil, date: "", source: "Ontario Energy Board",
                note: "Natural gas rates couldn't be downloaded\(snapshot?.naturalGasProblem.map { ": \($0)" } ?? "."). Pull down to try again.",
                isEstimate: false, per: "m³"
            )
        }
        return FuelPriceRow(
            id: "naturalgas", name: "Natural Gas", detail: "Gas supply charge, \(Self.displayName(ofUtility: rate.utility))",
            cents: rate.centsPerCubicMetre, change: nil, date: snapshot?.naturalGasEffective ?? "",
            source: "Ontario Energy Board",
            note: "Supply (commodity) charge set by the OEB each quarter. Delivery, transportation (where not included) and the monthly customer charge are billed on top.",
            isEstimate: false, per: "m³"
        )
    }

    static func displayName(ofUtility name: String) -> String {
        switch name {
        case "Enbridge Gas Inc.": return "Enbridge Gas (EGD rate zone)"
        default:
            return name
                .replacingOccurrences(of: "Enbridge Gas Inc. - ", with: "Enbridge Gas, ")
                .replacingOccurrences(of: " Rate Zone", with: " zone")
                .replacingOccurrences(of: "Natural Gas Limited Partnership", with: "Natural Gas")
                .trimmingCharacters(in: CharacterSet(charactersIn: "* "))
        }
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
        rows.append(naturalGasRow(utility: gasUtility))
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
        let weekly = currentFurnaceOil
        let monthly = snapshot?.heatingMonthly ?? []
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let month = DateFormatter()
        month.dateFormat = "MMMM yyyy"
        let isAverage = market.contains("Average")
        let weeklyProblem = weekly.isEmpty ? snapshot?.furnaceProblem : nil

        // 1. This week's price for the area's own city (NRCan).
        if !isAverage, let id = Self.nrcanCity(forMarket: market), let local = weekly.first(where: { $0.locationID == id }) {
            return FuelPriceRow(
                id: "furnace", name: "Furnace Oil", detail: "Heating oil, \(local.city)",
                cents: local.centsPerLitre, change: nil, date: day.string(from: local.date),
                source: "Natural Resources Canada", note: nil, isEstimate: false
            )
        }
        // 2. The area's own city, monthly (Statistics Canada: Toronto, Ottawa, Thunder Bay).
        if !isAverage, let id = FuelPriceSources.statCanCity(forMarket: marketName), let local = monthly.first(where: { $0.locationID == id }) {
            return FuelPriceRow(
                id: "furnace", name: "Furnace Oil", detail: "Household heating oil, \(local.city)",
                cents: local.centsPerLitre, change: nil, date: month.string(from: local.date),
                source: "Statistics Canada (monthly)",
                note: "Monthly average for \(month.string(from: local.date)). NRCan doesn't survey \(local.city) weekly.",
                isEstimate: false
            )
        }
        // 3. This week's average across the Ontario cities NRCan surveys.
        if !weekly.isEmpty {
            let average = weekly.map(\.centsPerLitre).reduce(0, +) / Double(weekly.count)
            let latest = weekly.map(\.date).max() ?? Date()
            let cities = weekly.map(\.city).joined(separator: ", ")
            return FuelPriceRow(
                id: "furnace", name: "Furnace Oil", detail: "Heating oil, average of \(weekly.count) Ontario cities",
                cents: average, change: nil, date: day.string(from: latest),
                source: "Natural Resources Canada",
                note: isAverage
                    ? "Average of the Ontario cities NRCan surveys for furnace oil: \(cities)."
                    : "NRCan doesn't survey furnace oil in \(marketName); this is the average of \(cities).",
                isEstimate: false
            )
        }
        // 4. Statistics Canada's monthly average for Toronto, Ottawa and Thunder Bay.
        if !monthly.isEmpty {
            let average = monthly.map(\.centsPerLitre).reduce(0, +) / Double(monthly.count)
            let latest = monthly.map(\.date).max() ?? Date()
            var note = "Monthly average of \(monthly.map(\.city).joined(separator: ", ")) for \(month.string(from: latest))."
            if let weeklyProblem { note += " Weekly prices didn't load (\(weeklyProblem))." }
            return FuelPriceRow(
                id: "furnace", name: "Furnace Oil", detail: "Household heating oil, Ontario",
                cents: average, change: nil, date: month.string(from: latest),
                source: "Statistics Canada (monthly)", note: note, isEstimate: false
            )
        }
        return FuelPriceRow(
            id: "furnace", name: "Furnace Oil", detail: "Heating oil",
            cents: nil, change: nil, date: "", source: "Natural Resources Canada",
            note: "No furnace oil prices could be downloaded\(snapshot?.furnaceProblem.map { ": \($0)" } ?? "."). Pull down to try again.",
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
    static let statCanPage = URL(string: "https://www150.statcan.gc.ca/t1/tbl1/en/tv.action?pid=1810000101")!
    static let statCanAPI = URL(string: "https://www150.statcan.gc.ca/t1/wds/rest/getDataFromCubePidCoordAndLatestNPeriods")!
    static let oebRates = URL(string: "https://www.oeb.ca/consumer-information-and-protection/natural-gas-rates")!

    /// NRCan city IDs in Ontario that report furnace oil (plus the big cities, in case they resume).
    static let nrcanCities: [(name: String, id: Int)] = [
        ("Kingston", 72), ("North Bay", 24), ("Sault Ste. Marie", 22), ("Sudbury", 21), ("Thunder Bay", 23),
        ("Timmins", 25), ("Windsor", 19), ("Woodstock", 81), ("Toronto", 17), ("Ottawa", 18), ("London", 20),
    ]
    /// NRCan's newer host name for the same service, tried when the usual one fails.
    static let nrcanHosts = ["www2.nrcan.gc.ca", "www2.nrcan-rncan.gc.ca"]

    /// Statistics Canada table 18-10-0001-01 geography members (fuel type 7 = household heating fuel).
    static let statCanCities: [(name: String, id: Int)] = [("Toronto", 9), ("Ottawa", 8), ("Thunder Bay", 10)]

    static func statCanCity(forMarket name: String) -> Int? {
        if name.hasPrefix("Toronto") { return 9 }
        return statCanCities.first { $0.name == name }?.id
    }

    struct Survey: Sendable {
        var markets: [String]
        var series: [String: FuelPriceSnapshot.Series]
    }

    struct Loaded<Value: Sendable>: Sendable {
        var value: Value?
        var problem: String?
    }

    struct Readings: Sendable {
        var readings: [FuelPriceSnapshot.CityReading]
        var problem: String?
    }

    /// Fuel price downloads use the system's normal certificate checks, plus NRCan's root for NRCan only
    /// (see NRCanTrustDelegate: some iPhones don't have the root NRCan's certificate chains to).
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration, delegate: NRCanTrustDelegate(), delegateQueue: nil)
    }()

    /// The same, limited to TLS 1.2, for servers or firewalls that reject the larger TLS 1.3 handshake.
    private static let tls12Session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMaximumSupportedProtocolVersion = .TLSv12
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.httpAdditionalHeaders = ["Accept-Language": "en-CA,en;q=0.9"]
        return URLSession(configuration: configuration, delegate: NRCanTrustDelegate(), delegateQueue: nil)
    }()

    /// Downloads a URL; on failure says why (HTTP status or the system's error, e.g. a certificate problem).
    /// A refused secure connection or a 403 is retried once over TLS 1.2.
    static func fetch(_ request: URLRequest) async -> (data: Data?, problem: String?) {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("text/csv, application/rss+xml, application/json, text/html, */*", forHTTPHeaderField: "Accept")
        }
        let first = await attempt(request, session: session)
        guard first.data == nil, first.retry else { return (first.data, first.problem) }
        let second = await attempt(request, session: tls12Session)
        if second.data != nil { return (second.data, nil) }
        return (nil, "\(first.problem ?? "failed"); over TLS 1.2: \(second.problem ?? "failed")")
    }

    private static func attempt(_ request: URLRequest, session: URLSession) async -> (data: Data?, problem: String?, retry: Bool) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return (nil, "no response", false) }
            guard (200..<300).contains(http.statusCode) else {
                return (nil, "HTTP \(http.statusCode)", http.statusCode == 403 || http.statusCode == 406)
            }
            return (data, nil, false)
        } catch let error as URLError {
            let tlsFailure: Set<URLError.Code> = [
                .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
                .networkConnectionLost,
            ]
            return (nil, "\(error.localizedDescription) (\(error.code.rawValue))", tlsFailure.contains(error.code))
        } catch {
            return (nil, error.localizedDescription, false)
        }
    }

    static func fetch(_ url: URL) async -> (data: Data?, problem: String?) {
        await fetch(URLRequest(url: url))
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

    static func loadOntario() async -> Loaded<Survey> {
        let result = await fetch(ontarioCSV)
        guard let data = result.data else { return Loaded(value: nil, problem: result.problem) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let parsed = parseOntarioCSV(text)
        else { return Loaded(value: nil, problem: "the file's layout changed") }
        return Loaded(value: Survey(markets: parsed.markets, series: parsed.series), problem: nil)
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

    /// One city's latest weekly furnace oil price. Tries both NRCan host names, and last year's
    /// feed early in January when this year's is still empty.
    private static func loadNRCanCity(name: String, id: Int, year: Int) async -> (reading: FuelPriceSnapshot.CityReading?, problem: String?) {
        var problem: String?
        for host in nrcanHosts {
            var hostProblem: String?
            for priceYear in [year, year - 1] {
                guard let url = URL(string: "https://\(host)/eneene/sources/pripri/webfeed_e.cfm?priceYear=\(priceYear)&productID=7&locationID=\(id)") else { continue }
                let result = await fetch(url)
                guard let data = result.data else {
                    hostProblem = result.problem
                    break // this host failed; try the other one
                }
                if let text = String(data: data, encoding: .utf8), let reading = parseNRCanFeed(text) {
                    return (FuelPriceSnapshot.CityReading(city: name, locationID: id, dollarsPerLitre: reading.dollars, date: reading.date, source: "NRCan"), nil)
                }
            }
            // Reached NRCan, and this city just has no recent furnace oil price.
            guard let hostProblem else { return (nil, nil) }
            problem = [problem, "\(host): \(hostProblem)"].compactMap { $0 }.joined(separator: " | ")
        }
        return (nil, problem)
    }

    static func loadFurnaceOil() async -> Readings {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        var readings: [FuelPriceSnapshot.CityReading] = []
        var problems: [String] = []
        // A few at a time, so the government server isn't hit with a burst of requests.
        let batches = stride(from: 0, to: nrcanCities.count, by: 4).map { Array(nrcanCities[$0..<min($0 + 4, nrcanCities.count)]) }
        for batch in batches {
            await withTaskGroup(of: (FuelPriceSnapshot.CityReading?, String?).self) { group in
                for city in batch {
                    group.addTask {
                        let result = await loadNRCanCity(name: city.name, id: city.id, year: year)
                        return (result.reading, result.problem)
                    }
                }
                for await (reading, problem) in group {
                    if let reading { readings.append(reading) }
                    if let problem { problems.append(problem) }
                }
            }
            // Every city in the first batch failed to download: the service is unreachable, stop here.
            if readings.isEmpty && problems.count == batch.count && batch.first?.id == nrcanCities.first?.id {
                break
            }
        }
        return Readings(readings: readings, problem: readings.isEmpty ? problems.first : nil)
    }

    /// Statistics Canada's latest monthly household heating fuel price for Toronto, Ottawa and Thunder Bay.
    static func loadStatCanHeatingFuel() async -> Readings {
        let body = statCanCities.map { #"{"productId":18100001,"coordinate":"\#($0.id).7.0.0.0.0.0.0.0.0","latestN":2}"# }
        var request = URLRequest(url: statCanAPI)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(("[" + body.joined(separator: ",") + "]").utf8)
        let result = await fetch(request)
        guard let data = result.data else {
            // Statistics Canada sometimes puts a "verify your browser" check (Cloudflare) in front of its API.
            let blocked = result.problem?.contains("HTTP 403") == true
            return Readings(readings: [], problem: blocked ? "its site is showing a browser security check to apps (HTTP 403)" : result.problem)
        }
        let readings = parseStatCan(data)
        return Readings(readings: readings, problem: readings.isEmpty ? "unexpected reply" : nil)
    }

    struct GasRates: Sendable {
        var rates: [FuelPriceSnapshot.GasRate]
        var effective: String
    }

    /// The OEB's "Current gas rates for supply (October 1, 2026)" table: utility and gas supply charge (¢/m³).
    static func loadOEBNaturalGas() async -> Loaded<GasRates> {
        let result = await fetch(oebRates)
        guard let data = result.data else { return Loaded(value: nil, problem: result.problem) }
        guard let parsed = parseOEB(String(decoding: data, as: UTF8.self)) else {
            return Loaded(value: nil, problem: "the OEB page's layout changed")
        }
        return Loaded(value: parsed, problem: nil)
    }

    static func parseOEB(_ html: String) -> GasRates? {
        // The heading carries the date: "Current gas rates for supply (October 1, 2026)". The same words
        // without the date also appear earlier, in the page's table of contents.
        guard let heading = html.range(of: "Current gas rates for supply (") ?? html.range(of: "Current gas rates for supply") else { return nil }
        let afterHeading = html[heading.upperBound...]
        var effective = ""
        if html[heading].hasSuffix("("), let close = afterHeading.firstIndex(of: ")") {
            effective = String(afterHeading[..<close]).trimmingCharacters(in: .whitespaces)
        }
        guard let tableStart = afterHeading.range(of: "<table"), let tableEnd = afterHeading.range(of: "</table>", range: tableStart.upperBound..<afterHeading.endIndex) else { return nil }
        let table = String(afterHeading[tableStart.lowerBound..<tableEnd.upperBound])
        var rates: [FuelPriceSnapshot.GasRate] = []
        for row in table.components(separatedBy: "<tr").dropFirst() {
            let cells = row.components(separatedBy: "<td").dropFirst().map(plainText)
            guard cells.count >= 2,
                  let match = cells[1].range(of: #"[0-9]+(\.[0-9]+)?"#, options: .regularExpression),
                  let value = Double(cells[1][match]), value > 0, value < 200
            else { continue }
            let name = cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "* ").union(.whitespacesAndNewlines))
            rates.append(FuelPriceSnapshot.GasRate(utility: name, centsPerCubicMetre: value))
        }
        return rates.isEmpty ? nil : GasRates(rates: rates, effective: effective)
    }

    /// Text of an HTML fragment: tags removed, common entities decoded, spaces collapsed.
    private static func plainText(_ html: String) -> String {
        var text = html
        if let close = text.firstIndex(of: ">") { text = String(text[text.index(after: close)...]) }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&amp;", "&"), ("&#039;", "'"), ("&rsquo;", "’")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func parseStatCan(_ data: Data) -> [FuelPriceSnapshot.CityReading] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withFullDate]
        var readings: [FuelPriceSnapshot.CityReading] = []
        for item in items {
            guard let object = item["object"] as? [String: Any],
                  let coordinate = object["coordinate"] as? String,
                  let id = coordinate.split(separator: ".").first.flatMap({ Int($0) }),
                  let city = statCanCities.first(where: { $0.id == id }),
                  let points = object["vectorDataPoint"] as? [[String: Any]]
            else { continue }
            let latest = points
                .compactMap { point -> (Date, Double)? in
                    guard let period = point["refPer"] as? String, let date = dates.date(from: period),
                          let value = (point["value"] as? NSNumber)?.doubleValue, value > 0 else { return nil }
                    return (date, value)
                }
                .max { $0.0 < $1.0 }
            if let latest {
                readings.append(FuelPriceSnapshot.CityReading(
                    city: city.name, locationID: id, dollarsPerLitre: latest.1 / 100, date: latest.0, source: "Statistics Canada"
                ))
            }
        }
        return readings
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
