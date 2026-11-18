import Foundation

/// Gas piping capacity by the method of CSA B149.1-20 Annex A.
///
/// Clause A.3.5 gives the formulas used to generate capacity Tables A.1 to A.14:
///
///   Low pressure (under 1.5 psig / 10.3 kPa):  Q = K2 · D^2.623 · [ΔH / (Cr · L · F)]^0.541 · (b · z)
///   High pressure (1.5 psig and up):           Q = K1 · D^2.623 · [(P1² − P2²) · Y / (Cr · L · F)]^0.541 · (b · z)
///
/// Imperial: K2 = 2313, K1 = 2237, D in inches, ΔH in in. w.c., P in psia, L in ft, b in Btu/ft³.
/// Metric:   K2 = 0.1509, K1 = 0.3576, D in cm, ΔH in Pa, P in kPa absolute, L in m, b · z converts to kW.
/// Natural gas (Annex A): Cr = 0.6094, b = 1000 Btu/ft³. Propane (Annex B, clause B.3.5, same formulas):
/// Cr ≈ 1.260 and b = 2520 Btu/ft³. Y = 1. F = 1.2 (a fittings allowance) for Tables A.1–A.4, A.8–A.11,
/// B.1, B.2, B.6 and B.7; F = 1 for the 5, 10 and 20 psi tables, where fittings are added as equivalent
/// lengths (Tables A.16 / B.11). Steel tables use Schedule 40 inside diameters; tubing tables use Type K copper.
///
/// As in clauses A.3.5 / B.3.5, the run is rounded up to the next length the tables list, and capacities
/// are rounded to whole MBH (kW). Checked against the printed tables A.1–A.14 and B.1–B.10 (imperial and
/// metric): about 97% of values agree within ±1 and the rest within 0.16%.
enum FuelGas: String, CaseIterable, Identifiable, Codable, Sendable {
    case natural
    case propane

    var id: String { rawValue }

    var label: String {
        switch self {
        case .natural: return "Natural Gas"
        case .propane: return "Propane"
        }
    }

    /// Cr: factor for viscosity, density and temperature. B149.1 states 0.6094 for natural gas and 1.260 for
    /// propane (rounded from Cr = K3 · S · T · (Z/S)^0.152); the propane tables were generated with the
    /// unrounded value, which these reproduce (imperial and metric differ slightly, as in the tables).
    func cr(_ units: UnitSystem) -> Double {
        switch self {
        case .natural: return 0.6094
        case .propane: return units == .imperial ? 1.26044 : 1.2608
        }
    }

    /// Calorific value used to turn volume into energy (B149.1 A.2.2 / B.2.2).
    var btuPerCubicFoot: Double {
        switch self {
        case .natural: return 1000
        case .propane: return 2520
        }
    }

    /// b · z in the metric formula: kW per m³/h of gas.
    var kWPerCubicMetrePerHour: Double {
        switch self {
        case .natural: return 10.354
        case .propane: return 26.097
        }
    }
}

enum UnitSystem: String, CaseIterable, Identifiable, Sendable {
    case imperial
    case metric

    var id: String { rawValue }

    var label: String {
        switch self {
        case .imperial: return "ft · Btu/h"
        case .metric: return "m · kW"
        }
    }

    var lengthUnit: String { self == .imperial ? "ft" : "m" }
    var capacityUnit: String { self == .imperial ? "MBH" : "kW" }

    /// The lengths the B149.1 capacity tables list (column "Length of pipe").
    var tableLengths: [Double] {
        switch self {
        case .imperial:
            return [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 125, 150, 175, 200, 250, 300, 350, 400, 450, 500,
                    600, 700, 800, 900, 1000, 1200, 1400, 1600, 1800, 2000]
        case .metric:
            return [3, 6, 9, 12, 15, 18, 21, 24, 27, 30, 35, 40, 45, 50, 60, 70, 80, 90, 100, 125, 150, 175, 200,
                    250, 300, 350, 400, 500, 600]
        }
    }
}

enum PressureUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case inchesWC
    case psi
    case kPa

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inchesWC: return "in. w.c."
        case .psi: return "psi"
        case .kPa: return "kPa"
        }
    }

    static let inchesWCPerPSI = 27.68
    static let kPaPerPSI = 6.894757

    func toPSI(_ value: Double) -> Double {
        switch self {
        case .psi: return value
        case .inchesWC: return value / PressureUnit.inchesWCPerPSI
        case .kPa: return value / PressureUnit.kPaPerPSI
        }
    }

    func format(_ value: Double) -> String {
        let text = value.formatted(.number.precision(.fractionLength(0...2)))
        switch self {
        case .psi: return "\(text) psi"
        case .inchesWC: return "\(text)\" w.c."
        case .kPa: return "\(text) kPa"
        }
    }
}

/// A supply pressure and the pressure drop allowed across the piping, as in one B149.1 table.
struct GasSystem: Identifiable, Hashable, Sendable {
    let id: String
    let gas: FuelGas
    /// Imperial: supply pressure and allowed drop.
    let inlet: Double
    let inletUnit: PressureUnit
    let drop: Double
    let dropUnit: PressureUnit
    /// Metric equivalents as the metric tables state them (kPa).
    let inletKPa: Double
    let dropKPa: Double
    /// Fitting allowance factor F: 1.2 where the tables include fittings, 1 where they're added separately.
    let fittingFactor: Double
    /// B149.1 tables for steel pipe and for tubing, e.g. "A.1" and "A.8".
    let steelTable: String?
    let tubingTable: String?
    let note: String
    /// Supply range as printed in the table title, e.g. "7–14\" w.c.".
    var inletText: String? = nil

    var inletPSI: Double { inletUnit.toPSI(inlet) }
    var dropPSI: Double { dropUnit.toPSI(drop) }
    var usesLowPressureEquation: Bool { inletPSI < 1.5 }
    var includesFittings: Bool { fittingFactor > 1 }

    func title(_ units: UnitSystem) -> String {
        switch units {
        case .imperial:
            return "\(inletText ?? inletUnit.format(inlet)) · \(dropUnit.format(drop)) drop"
        case .metric:
            let dropText = dropKPa < 1
                ? "\(Int((dropKPa * 1000).rounded())) Pa"
                : PressureUnit.kPa.format(dropKPa)
            return "\(PressureUnit.kPa.format(inletKPa)) · \(dropText) drop"
        }
    }

    func table(for material: PipeMaterial, units: UnitSystem) -> String? {
        guard material != .copperL, let base = material.usesPipeTables ? steelTable : tubingTable else { return nil }
        return "Table \(base) \(units == .imperial ? "a" : "b"))"
    }

    static let presets: [GasSystem] = [
        GasSystem(id: "ng-a1", gas: .natural, inlet: 7, inletUnit: .inchesWC, drop: 0.5, dropUnit: .inchesWC,
                  inletKPa: 1.75, dropKPa: 0.125, fittingFactor: 1.2, steelTable: "A.1", tubingTable: "A.8",
                  note: "Low pressure, under 7\" w.c.", inletText: "Under 7\" w.c."),
        GasSystem(id: "ng-a2", gas: .natural, inlet: 14, inletUnit: .inchesWC, drop: 1, dropUnit: .inchesWC,
                  inletKPa: 3.5, dropKPa: 0.25, fittingFactor: 1.2, steelTable: "A.2", tubingTable: "A.9",
                  note: "Low pressure, 7 to 14\" w.c.", inletText: "7–14\" w.c."),
        GasSystem(id: "ng-a3", gas: .natural, inlet: 2, inletUnit: .psi, drop: 1, dropUnit: .psi,
                  inletKPa: 14, dropKPa: 7, fittingFactor: 1.2, steelTable: "A.3", tubingTable: "A.10",
                  note: "2 psi system"),
        GasSystem(id: "ng-a4", gas: .natural, inlet: 2, inletUnit: .psi, drop: 1.5, dropUnit: .psi,
                  inletKPa: 14, dropKPa: 10, fittingFactor: 1.2, steelTable: "A.4", tubingTable: "A.11",
                  note: "2 psi system"),
        GasSystem(id: "ng-a5", gas: .natural, inlet: 5, inletUnit: .psi, drop: 2.5, dropUnit: .psi,
                  inletKPa: 34, dropKPa: 17, fittingFactor: 1, steelTable: "A.5", tubingTable: "A.12",
                  note: "5 psi system"),
        GasSystem(id: "ng-a6", gas: .natural, inlet: 10, inletUnit: .psi, drop: 5, dropUnit: .psi,
                  inletKPa: 70, dropKPa: 35, fittingFactor: 1, steelTable: "A.6", tubingTable: "A.13",
                  note: "10 psi system"),
        GasSystem(id: "ng-a7", gas: .natural, inlet: 20, inletUnit: .psi, drop: 10, dropUnit: .psi,
                  inletKPa: 140, dropKPa: 70, fittingFactor: 1, steelTable: "A.7", tubingTable: "A.14",
                  note: "20 psi system"),
        GasSystem(id: "lp-b1", gas: .propane, inlet: 11, inletUnit: .inchesWC, drop: 1, dropUnit: .inchesWC,
                  inletKPa: 2.7, dropKPa: 0.25, fittingFactor: 1.2, steelTable: "B.1", tubingTable: "B.6",
                  note: "After the second-stage regulator (11\" w.c.)"),
        GasSystem(id: "lp-b2", gas: .propane, inlet: 2, inletUnit: .psi, drop: 1, dropUnit: .psi,
                  inletKPa: 14, dropKPa: 7, fittingFactor: 1.2, steelTable: "B.2", tubingTable: "B.7",
                  note: "2 psi system, to the line regulator"),
        GasSystem(id: "lp-b3", gas: .propane, inlet: 5, inletUnit: .psi, drop: 2.5, dropUnit: .psi,
                  inletKPa: 34, dropKPa: 17, fittingFactor: 1, steelTable: "B.3", tubingTable: "B.8",
                  note: "5 psi system"),
        GasSystem(id: "lp-b4", gas: .propane, inlet: 10, inletUnit: .psi, drop: 5, dropUnit: .psi,
                  inletKPa: 70, dropKPa: 35, fittingFactor: 1, steelTable: "B.4", tubingTable: "B.9",
                  note: "10 psi, first stage to second stage"),
        GasSystem(id: "lp-b5", gas: .propane, inlet: 20, inletUnit: .psi, drop: 10, dropUnit: .psi,
                  inletKPa: 140, dropKPa: 70, fittingFactor: 1, steelTable: "B.5", tubingTable: "B.10",
                  note: "20 psi system"),
    ]

    static func presets(for gas: FuelGas) -> [GasSystem] {
        presets.filter { $0.gas == gas }
    }

    static func custom(gas: FuelGas, inlet: Double, inletUnit: PressureUnit, drop: Double, dropUnit: PressureUnit, includeFittings: Bool) -> GasSystem {
        let toKPa = { (value: Double, unit: PressureUnit) in unit.toPSI(value) * PressureUnit.kPaPerPSI }
        return GasSystem(
            id: "custom", gas: gas, inlet: inlet, inletUnit: inletUnit, drop: drop, dropUnit: dropUnit,
            inletKPa: toKPa(inlet, inletUnit), dropKPa: toKPa(drop, dropUnit),
            fittingFactor: includeFittings ? 1.2 : 1, steelTable: nil, tubingTable: nil, note: "Custom"
        )
    }
}

enum PipeMaterial: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Black iron (Schedule 40 steel) pipe.
    case steelSch40
    /// Plastic (PE) pipe: B149.1 Tables A.1–A.7 and B.1–B.5 cover "Schedule 40 pipe and plastic pipe" alike.
    case plastic
    case copperK
    case copperL

    var id: String { rawValue }

    var label: String {
        switch self {
        case .steelSch40: return "Black iron (Schedule 40)"
        case .plastic: return "Plastic (PE)"
        case .copperK: return "Copper tubing, Type K"
        case .copperL: return "Copper tubing, Type L"
        }
    }

    var isTubing: Bool { self == .copperK || self == .copperL }
    /// Sized from the pipe tables (A.1–A.7, B.1–B.5), which apply to Schedule 40 and plastic pipe.
    var usesPipeTables: Bool { self == .steelSch40 || self == .plastic }

    /// Nominal pipe size (steel) or tubing outside diameter, with the inside diameter in inches.
    var sizes: [(name: String, id: Double)] {
        switch self {
        case .steelSch40, .plastic:
            return [("1/2\"", 0.622), ("3/4\"", 0.824), ("1\"", 1.049), ("1-1/4\"", 1.380), ("1-1/2\"", 1.610),
                    ("2\"", 2.067), ("2-1/2\"", 2.469), ("3\"", 3.068), ("4\"", 4.026)]
        case .copperK:
            return [("3/8\" OD", 0.305), ("1/2\" OD", 0.402), ("5/8\" OD", 0.527), ("3/4\" OD", 0.652),
                    ("7/8\" OD", 0.745), ("1-1/8\" OD", 0.995), ("1-3/8\" OD", 1.245)]
        case .copperL:
            return [("3/8\" OD", 0.315), ("1/2\" OD", 0.430), ("5/8\" OD", 0.545), ("3/4\" OD", 0.666),
                    ("7/8\" OD", 0.785), ("1-1/8\" OD", 1.025), ("1-3/8\" OD", 1.265)]
        }
    }
}

/// Fittings counted for the systems whose tables don't include an allowance (F = 1).
/// Equivalent length = n × inside diameter (B149.1 Table A.16, from Crocker): 90° elbow n = 30,
/// 45° elbow 14, tee (flow through the branch) 60, plug valve 30. Copper or brass valves count 45% longer (A.4).
struct FittingCounts: Equatable, Sendable {
    var elbows90 = 0
    var elbows45 = 0
    var tees = 0
    var plugValves = 0

    var isEmpty: Bool { elbows90 + elbows45 + tees + plugValves == 0 }

    func equivalentLength(insideDiameterInches d: Double, tubing: Bool, units: UnitSystem) -> Double {
        let valveFactor = tubing ? 1.45 : 1
        let n = 30 * Double(elbows90) + 14 * Double(elbows45) + 60 * Double(tees) + 30 * valveFactor * Double(plugValves)
        return units == .imperial ? n * d / 12 : n * d * 0.0254
    }
}

struct PipeCapacity: Identifiable, Sendable {
    let size: String
    let insideDiameter: Double
    /// Length the capacity was read at: the next table length up from the run (+ fittings).
    let rowLength: Double
    /// Run plus fittings, before rounding up to a table length.
    let effectiveLength: Double
    /// Beyond the longest table length, so calculated at the actual length.
    let beyondTable: Bool
    /// MBH (imperial) or kW (metric), rounded like the tables.
    let capacity: Int

    var id: String { size }
}

enum PipeSizing {
    static let feetPerMetre = 3.28084
    static let btuPerKW = 3412.14

    /// Unrounded capacity in MBH (imperial) or kW (metric) for one inside diameter and length.
    static func capacity(insideDiameterInches d: Double, length: Double, system: GasSystem, units: UnitSystem) -> Double {
        guard d > 0, length > 0 else { return 0 }
        let gas = system.gas
        let F = system.fittingFactor
        switch units {
        case .imperial:
            let flow: Double // ft³/h
            if system.usesLowPressureEquation {
                let dropWC = system.dropPSI * PressureUnit.inchesWCPerPSI
                flow = 2313 * pow(d, 2.623) * pow(dropWC / (gas.cr(units) * length * F), 0.541)
            } else {
                let p1 = system.inletPSI + 14.696
                let p2 = p1 - system.dropPSI
                guard p2 > 0 else { return 0 }
                flow = 2237 * pow(d, 2.623) * pow((p1 * p1 - p2 * p2) / (gas.cr(units) * length * F), 0.541)
            }
            return flow * gas.btuPerCubicFoot / 1000
        case .metric:
            let cm = d * 2.54
            let flow: Double // m³/h
            if system.usesLowPressureEquation {
                let dropPa = system.dropKPa * 1000
                flow = 0.1509 * pow(cm, 2.623) * pow(dropPa / (gas.cr(units) * length * F), 0.541)
            } else {
                let p1 = system.inletKPa + 101.325
                let p2 = p1 - system.dropKPa
                guard p2 > 0 else { return 0 }
                flow = 0.3576 * pow(cm, 2.623) * pow((p1 * p1 - p2 * p2) / (gas.cr(units) * length * F), 0.541)
            }
            return flow * gas.kWPerCubicMetrePerHour
        }
    }

    /// Capacity of every size, read the way clause A.3.5 reads the tables: at the run length (plus
    /// fittings where the table has no allowance) rounded up to the next listed length.
    static func capacities(material: PipeMaterial, length: Double, units: UnitSystem, system: GasSystem,
                           fittings: FittingCounts = FittingCounts(), extraLength: Double = 0) -> [PipeCapacity] {
        guard length > 0 else { return [] }
        let rows = units.tableLengths
        return material.sizes.map { size in
            var effective = length + max(0, extraLength)
            if !system.includesFittings {
                effective += fittings.equivalentLength(insideDiameterInches: size.id, tubing: material.isTubing, units: units)
            }
            let row = rows.first { $0 >= effective - 0.000_1 }
            let readAt = row ?? effective
            let value = capacity(insideDiameterInches: size.id, length: readAt, system: system, units: units)
            return PipeCapacity(
                size: size.name, insideDiameter: size.id, rowLength: readAt, effectiveLength: effective,
                beyondTable: row == nil, capacity: Int(value.rounded())
            )
        }
    }

    /// The smallest size whose capacity is at least the load (A.3.7: the next larger figure).
    /// - Parameter load: MBH (imperial) or kW (metric).
    static func recommended(_ capacities: [PipeCapacity], load: Double) -> PipeCapacity? {
        guard load > 0 else { return nil }
        return capacities.first { Double($0.capacity) >= load }
    }

    /// Pressure drop at the actual load over the actual run (in the system's drop units), to show the margin.
    static func actualDrop(insideDiameterInches d: Double, length: Double, load: Double, units: UnitSystem, system: GasSystem) -> Double? {
        guard d > 0, length > 0, load > 0 else { return nil }
        let gas = system.gas
        let F = system.fittingFactor
        switch units {
        case .imperial:
            let flow = load * 1000 / gas.btuPerCubicFoot
            if system.usesLowPressureEquation {
                let term = pow(flow / (2313 * pow(d, 2.623)), 1 / 0.541)
                let dropWC = term * gas.cr(units) * length * F
                // In the system's own drop unit (toPSI(1) = psi per unit).
                return (dropWC / PressureUnit.inchesWCPerPSI) / system.dropUnit.toPSI(1)
            }
            let term = pow(flow / (2237 * pow(d, 2.623)), 1 / 0.541)
            let p1 = system.inletPSI + 14.696
            let p2Squared = p1 * p1 - term * gas.cr(units) * length * F
            guard p2Squared > 0 else { return nil }
            let dropPSI = p1 - sqrt(p2Squared)
            return dropPSI / system.dropUnit.toPSI(1)
        case .metric:
            let flow = load / gas.kWPerCubicMetrePerHour
            let cm = d * 2.54
            if system.usesLowPressureEquation {
                let term = pow(flow / (0.1509 * pow(cm, 2.623)), 1 / 0.541)
                return term * gas.cr(units) * length * F / 1000 // kPa
            }
            let term = pow(flow / (0.3576 * pow(cm, 2.623)), 1 / 0.541)
            let p1 = system.inletKPa + 101.325
            let p2Squared = p1 * p1 - term * gas.cr(units) * length * F
            guard p2Squared > 0 else { return nil }
            return p1 - sqrt(p2Squared) // kPa
        }
    }
}
