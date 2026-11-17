import SwiftUI

@main
struct CodeShelfApp: App {
    @State private var store = LibraryStore.shared
    @State private var router = AppRouter()
    @State private var updates = UpdatesStore.shared
    @State private var equipment = EquipmentLibrary.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(router)
                .environment(updates)
                .environment(equipment)
                .onOpenURL { url in
                    // "Open in CodeShelf" / share sheet from Files, Mail, Safari, etc.
                    guard url.isFileURL else { return }
                    router.selectedTab = .library
                    Task { await store.importPDFs(from: [url]) }
                }
                .task { await importLaunchArgumentFiles() }
                .task { await runDebugProbes() }
        }
        // iOS wakes the app a few times a day to check TSSA / CSA / e-Laws for new items.
        .backgroundTask(.appRefresh(BackgroundRefresh.taskID)) {
            await BackgroundRefresh.run()
        }
    }

    /// Debug builds only: `-importOnLaunch "/path/a.pdf|/path/b.pdf"` imports files at launch.
    /// Used by the CI simulator smoke test; does nothing in the release .ipa.
    @MainActor
    private func importLaunchArgumentFiles() async {
        #if DEBUG
        guard let paths = UserDefaults.standard.string(forKey: "importOnLaunch"), !paths.isEmpty else { return }
        let urls = paths.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
        await store.importPDFs(from: urls)
        #endif
    }

    /// Debug builds only, for CI:
    /// - `-searchProbe "words"` writes the ranked Search results to search-probe.json after indexing,
    /// - `-calcProbe YES` writes pipe and CSST sizing results to calc-probe.json,
    /// - `-fuelProbe YES` downloads fuel prices and writes them to fuel-probe.json.
    @MainActor
    private func runDebugProbes() async {
        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "calcProbe") {
            writeProbe("calc-probe.json", calcProbe())
        }
        if defaults.bool(forKey: "fuelProbe") {
            let prices = FuelPriceStore.shared
            await prices.refresh()
            let rows = prices.rows(market: FuelPriceStore.averageMarket, dyedDiscount: FuelPriceStore.defaultDyedDiscount)
            writeProbe("fuel-probe.json", [
                "error": prices.errorMessage ?? "",
                "markets": prices.snapshot?.markets.count ?? 0,
                "furnaceOilCities": prices.currentFurnaceOil.map(\.city),
                "heatingMonthly": (prices.snapshot?.heatingMonthly ?? []).map { "\($0.city) \($0.centsPerLitre)" },
                "furnaceProblem": prices.snapshot?.furnaceProblem ?? "",
                "rows": rows.map { ["name": $0.name, "cents": $0.cents ?? -1, "date": $0.date, "note": $0.note ?? ""] as [String: Any] },
            ])
        }
        guard let probe = defaults.string(forKey: "searchProbe"), !probe.isEmpty else { return }
        let queries = probe.split(separator: "|").map(String.init)
        // `-ocrProbe "<title>"`: after the first round of searches, re-read that book with OCR and search again.
        let ocrTitle = defaults.string(forKey: "ocrProbe") ?? ""
        let expectedBooks = defaults.integer(forKey: "probeBookCount")
        var rounds: [String: Any] = [:]
        var round = 0
        var lastSignature = ""
        for _ in 0..<300 {
            try? await Task.sleep(for: .seconds(2))
            guard !store.books.isEmpty, !store.hasPendingIndexing, store.books.count >= expectedBooks else { continue }
            let signature = store.books.map { "\($0.id)-\($0.indexedPages)-\($0.forceOCR)" }.sorted().joined(separator: ",")
            guard signature != lastSignature else { continue }
            lastSignature = signature
            var answers: [String: Any] = [:]
            for query in queries {
                let model = SearchModel()
                await model.run(query: query, matchAll: false, bookIDs: nil, store: store)
                var results: [[String: Any]] = []
                for tier in model.tiers {
                    for group in tier.groups {
                        if let book = store.book(id: group.bookID) {
                            results.append([
                                "title": book.title, "tier": tier.tier.label, "pages": group.hits.count,
                                "firstPage": group.hits.first?.pageIndex ?? -1, "note": tier.note ?? "",
                                "snippet": group.hits.first?.snippet ?? "",
                            ])
                        }
                    }
                }
                answers[query] = ["results": results, "missedCodeBooks": model.missedCodeBooks]
            }
            rounds["\(round)"] = ["bookCount": store.books.count, "queries": answers]
            writeProbe("search-probe.json", ["bookCount": store.books.count, "queries": answers, "rounds": rounds])
            if round == 0, !ocrTitle.isEmpty, let book = store.books.first(where: { $0.title == ocrTitle }) {
                round = 1
                store.rereadWithOCR(bookID: book.id)
            }
        }
        #endif
    }

    #if DEBUG
    private func calcProbe() -> [String: Any] {
        let lowNG = GasSystem.presets.first { $0.id == "ng-7wc-05" }!
        let propane10 = GasSystem.presets.first { $0.id == "lp-10psi" }!
        let steel10 = PipeSizing.capacities(material: .steelSch40, lengthFeet: 10, system: lowNG).map(\.cfh)
        let steel100 = PipeSizing.capacities(material: .steelSch40, lengthFeet: 100, system: lowNG).map(\.cfh)
        let propaneMBH = PipeSizing.capacities(material: .steelSch40, lengthFeet: 10, system: propane10).map { $0.btuPerHour / 1000 }
        var csst: [String: Any] = ["tables": CSSTSizing.tables.count]
        if let table = CSSTSizing.tables.first(where: { $0.table == "7-1" }),
           let result = CSSTSizing.size(table: table, lengthFeet: 28, extraFittings: 2, loadBTU: 100_000) {
            csst["size"] = result.recommended?.size ?? ""
            csst["column"] = result.columnFeet
        }
        if let table = CSSTSizing.tables.first(where: { $0.table == "7-20" }),
           let result = CSSTSizing.size(table: table, lengthFeet: 100, extraFittings: 0, loadBTU: 400_000) {
            csst["propane10psiSize"] = result.recommended?.size ?? ""
        }
        return ["steelNG10ft": steel10, "steelNG100ft": steel100, "steelLP10psi10ftMBH": propaneMBH, "csst": csst]
    }

    private func writeProbe(_ name: String, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.root, withIntermediateDirectories: true)
        try? data.write(to: AppPaths.root.appendingPathComponent(name), options: .atomic)
    }
    #endif
}
