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
        func preset(_ id: String) -> GasSystem { GasSystem.presets.first { $0.id == id }! }
        func row(_ id: String, _ material: PipeMaterial, _ length: Double, _ units: UnitSystem = .imperial) -> [Int] {
            PipeSizing.capacities(material: material, length: length, units: units, system: preset(id)).map(\.capacity)
        }
        // A worked example: 150 MBH over a 45 ft run at 7" w.c. (Table A.1): read at the 50 ft row.
        let example = PipeSizing.capacities(material: .steelSch40, length: 45, units: .imperial, system: preset("ng-a1"))
        let pick = PipeSizing.recommended(example, load: 150)
        // 5 psi (no fittings allowance): 95 ft plus two 90° elbows pushes 1/2" to the 100 ft row and 4" to 125 ft.
        var elbows = FittingCounts()
        elbows.elbows90 = 2
        let withFittings = PipeSizing.capacities(material: .steelSch40, length: 95, units: .imperial, system: preset("ng-a5"), fittings: elbows)
        let pipe: [String: Any] = [
            "A.1 10ft": row("ng-a1", .steelSch40, 10), "A.3 10ft": row("ng-a3", .steelSch40, 10),
            "A.5 10ft": row("ng-a5", .steelSch40, 10), "A.7 10ft": row("ng-a7", .steelSch40, 10),
            "A.8 10ft": row("ng-a1", .copperK, 10), "A.10 10ft": row("ng-a3", .copperK, 10),
            "A.2b 3m": row("ng-a2", .steelSch40, 3, .metric), "A.3b 3m": row("ng-a3", .steelSch40, 3, .metric),
            "B.1 10ft": row("lp-b1", .steelSch40, 10), "B.2 10ft": row("lp-b2", .steelSch40, 10),
            "B.4 10ft": row("lp-b4", .steelSch40, 10), "B.6 10ft": row("lp-b1", .copperK, 10),
            "B.1b 3m": row("lp-b1", .steelSch40, 3, .metric), "B.4b 3m": row("lp-b4", .steelSch40, 3, .metric),
            "exampleSize": pick?.size ?? "", "exampleRow": pick?.rowLength ?? 0,
            "fittingRows": withFittings.map(\.rowLength),
        ]
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
        return ["pipe": pipe, "csst": csst]
    }

    private func writeProbe(_ name: String, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.root, withIntermediateDirectories: true)
        try? data.write(to: AppPaths.root.appendingPathComponent(name), options: .atomic)
    }
    #endif
}
