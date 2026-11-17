import Foundation

/// One manufacturer capacity table (Resources/CSSTSizing.json, from the Gastite / FlashShield
/// sizing tables). Natural gas tables are in ft³/h, propane tables in thousands of BTU/h.
struct CSSTTable: Identifiable, Decodable, Hashable, Sendable {
    struct Row: Decodable, Hashable, Sendable {
        let ehd: Int
        let size: String
        let capacity: [Int]
    }

    let table: String
    let gas: String
    let unit: String
    let inletPsi: Double
    let inletOrLess: Bool
    let drop: Double
    let dropUnit: String
    let rows: [Row]

    var id: String { table }

    var fuel: FuelGas { gas == "propane" ? .propane : .natural }

    /// e.g. "7–14\" w.c. · 0.5\" w.c. drop" or "2 psi · 1 psi drop".
    var title: String {
        let dropText = dropUnit == "psi"
            ? "\(Self.number(drop)) psi drop"
            : "\(Self.number(drop))\" w.c. drop"
        return "\(inletText) · \(dropText)"
    }

    var inletText: String {
        if inletOrLess && inletPsi <= 0.5 {
            return fuel == .propane ? "11\" w.c." : "7\" w.c."
        }
        return "\(Self.number(inletPsi)) psi"
    }

    var isLowPressure: Bool { inletPsi <= 0.5 }

    var caution: String? {
        if inletPsi > 5 {
            return "Gastite's certification covers up to 5 psi operating pressure; contact Gastite before using CSST above 5 psi."
        }
        if inletPsi > 0.5 {
            return "Elevated-pressure capacities can exceed the line regulator's capacity — check the regulator too."
        }
        return nil
    }

    /// Converts a load in BTU/h into this table's unit.
    func tableLoad(btuPerHour: Double) -> Double {
        unit == "CFH" ? btuPerHour / FuelGas.natural.btuPerCubicFoot : btuPerHour / 1000
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

struct CSSTCapacity: Identifiable, Sendable {
    let row: CSSTTable.Row
    let capacity: Int

    var id: Int { row.ehd }
}

struct CSSTResult: Sendable {
    /// The length column used (the next one up from the run).
    let columnFeet: Int
    let effectiveLengthFeet: Double
    /// Capacity of every size at that length, in the table's unit.
    let capacities: [CSSTCapacity]
    let recommended: CSSTTable.Row?
    let load: Double
}

enum CSSTSizing {
    private struct File: Decodable, Sendable {
        let source: String
        let fittingsNote: String
        let lengths: [Int]
        let tables: [CSSTTable]
    }

    private static let file: File? = {
        guard let url = Bundle.main.url(forResource: "CSSTSizing", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }()

    static var source: String { file?.source ?? "" }
    static var fittingsNote: String { file?.fittingsNote ?? "" }
    static var lengths: [Int] { file?.lengths ?? [] }
    static var tables: [CSSTTable] { file?.tables ?? [] }

    static func tables(for gas: FuelGas) -> [CSSTTable] {
        tables.filter { $0.fuel == gas }
    }

    /// Feet added for fittings beyond the four 90° bends and two end fittings built into the tables.
    static func fittingAllowance(extraFittings: Int) -> Double {
        1.3 * Double(max(0, extraFittings))
    }

    /// Longest-length method: use the column at or above the run length, then the smallest size that carries the load.
    static func size(table: CSSTTable, lengthFeet: Double, extraFittings: Int, loadBTU: Double) -> CSSTResult? {
        let effective = lengthFeet + fittingAllowance(extraFittings: extraFittings)
        guard effective > 0, let column = lengths.firstIndex(where: { Double($0) >= effective }) else {
            return nil
        }
        let load = table.tableLoad(btuPerHour: loadBTU)
        let capacities = table.rows.map { CSSTCapacity(row: $0, capacity: $0.capacity[column]) }
        let recommended = load > 0 ? capacities.first { Double($0.capacity) >= load }?.row : nil
        return CSSTResult(
            columnFeet: lengths[column],
            effectiveLengthFeet: effective,
            capacities: capacities,
            recommended: recommended,
            load: load
        )
    }
}
