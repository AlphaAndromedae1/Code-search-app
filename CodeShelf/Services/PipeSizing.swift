import Foundation

/// Gas piping capacity for steel pipe and copper tubing, from the general flow equations
/// published with the fuel gas codes (IFGC 402.4 equations 4-1 and 4-2 / NFPA 54 Annex):
///
///   Low pressure (under 1.5 psi):   D = Q^0.381 / (19.17 · (ΔH / (Cr · L))^0.206)
///   High pressure (1.5 psi and up): D = Q^0.381 / (18.93 · ((P1² − P2²) · Y / (Cr · L))^0.206)
///
/// D = inside diameter (in), Q = ft³/h, ΔH = drop (in. w.c.), P = absolute pressure (psia), L = length (ft).
/// The code's own sizing tables are calculated the same way. In Ontario, size to CSA B149.1
/// (and B149.2 for tanks); use this as a quick check against those tables.
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

    /// Cr: specific-gravity and viscosity factor at standard conditions.
    var cr: Double {
        switch self {
        case .natural: return 0.6094
        case .propane: return 1.2462
        }
    }

    /// Y: compressibility factor for the high-pressure equation.
    var y: Double {
        switch self {
        case .natural: return 0.9992
        case .propane: return 0.9910
        }
    }

    /// Heating value used to turn BTU/h into ft³/h.
    var btuPerCubicFoot: Double {
        switch self {
        case .natural: return 1000
        case .propane: return 2516
        }
    }
}

enum PressureUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case inchesWC
    case psi

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inchesWC: return "in. w.c."
        case .psi: return "psi"
        }
    }

    static let inchesWCPerPSI = 27.68

    func toPSI(_ value: Double) -> Double {
        self == .psi ? value : value / PressureUnit.inchesWCPerPSI
    }

    func format(_ value: Double) -> String {
        let text = value.formatted(.number.precision(.fractionLength(0...2)))
        return self == .psi ? "\(text) psi" : "\(text)\" w.c."
    }
}

/// An operating pressure and the pressure drop allowed across the piping.
struct GasSystem: Identifiable, Hashable, Sendable {
    let id: String
    let gas: FuelGas
    let inlet: Double
    let inletUnit: PressureUnit
    let drop: Double
    let dropUnit: PressureUnit
    let note: String

    var inletPSI: Double { inletUnit.toPSI(inlet) }
    var dropPSI: Double { dropUnit.toPSI(drop) }
    var usesLowPressureEquation: Bool { inletPSI < 1.5 }

    var title: String {
        "\(inletUnit.format(inlet)) · \(dropUnit.format(drop)) drop"
    }

    static let presets: [GasSystem] = [
        GasSystem(id: "ng-7wc-05", gas: .natural, inlet: 7, inletUnit: .inchesWC, drop: 0.5, dropUnit: .inchesWC,
                  note: "Low pressure, after the meter"),
        GasSystem(id: "ng-7wc-1", gas: .natural, inlet: 7, inletUnit: .inchesWC, drop: 1, dropUnit: .inchesWC,
                  note: "Low pressure, larger drop where appliances allow it"),
        GasSystem(id: "ng-2psi", gas: .natural, inlet: 2, inletUnit: .psi, drop: 1, dropUnit: .psi,
                  note: "2 psi system, meter to line regulator"),
        GasSystem(id: "ng-5psi", gas: .natural, inlet: 5, inletUnit: .psi, drop: 3.5, dropUnit: .psi,
                  note: "5 psi system, meter to line regulator"),
        GasSystem(id: "ng-10psi", gas: .natural, inlet: 10, inletUnit: .psi, drop: 1, dropUnit: .psi,
                  note: "10 psi delivery, 1 psi drop"),
        GasSystem(id: "lp-11wc-05", gas: .propane, inlet: 11, inletUnit: .inchesWC, drop: 0.5, dropUnit: .inchesWC,
                  note: "After the second-stage regulator"),
        GasSystem(id: "lp-11wc-1", gas: .propane, inlet: 11, inletUnit: .inchesWC, drop: 1, dropUnit: .inchesWC,
                  note: "After the second stage, larger drop where appliances allow it"),
        GasSystem(id: "lp-2psi", gas: .propane, inlet: 2, inletUnit: .psi, drop: 1, dropUnit: .psi,
                  note: "2 psi system, to the line regulator"),
        GasSystem(id: "lp-10psi", gas: .propane, inlet: 10, inletUnit: .psi, drop: 1, dropUnit: .psi,
                  note: "First stage to second stage (10 psi)"),
    ]

    static func presets(for gas: FuelGas) -> [GasSystem] {
        presets.filter { $0.gas == gas }
    }

    static func custom(gas: FuelGas, inlet: Double, inletUnit: PressureUnit, drop: Double, dropUnit: PressureUnit) -> GasSystem {
        GasSystem(id: "custom", gas: gas, inlet: inlet, inletUnit: inletUnit, drop: drop, dropUnit: dropUnit, note: "Custom")
    }
}

enum PipeMaterial: String, CaseIterable, Identifiable, Codable, Sendable {
    case steelSch40
    case copperL
    case copperK

    var id: String { rawValue }

    var label: String {
        switch self {
        case .steelSch40: return "Steel, Schedule 40"
        case .copperL: return "Copper tubing, Type L"
        case .copperK: return "Copper tubing, Type K"
        }
    }

    var shortLabel: String {
        switch self {
        case .steelSch40: return "Steel"
        case .copperL: return "Copper L"
        case .copperK: return "Copper K"
        }
    }

    /// Nominal size (steel) or outside diameter (copper, as sold for gas) with the inside diameter in inches.
    var sizes: [(name: String, id: Double)] {
        switch self {
        case .steelSch40:
            return [("1/2\"", 0.622), ("3/4\"", 0.824), ("1\"", 1.049), ("1-1/4\"", 1.380), ("1-1/2\"", 1.610),
                    ("2\"", 2.067), ("2-1/2\"", 2.469), ("3\"", 3.068), ("4\"", 4.026)]
        case .copperL:
            return [("3/8\" OD", 0.315), ("1/2\" OD", 0.430), ("5/8\" OD", 0.545), ("3/4\" OD", 0.666),
                    ("7/8\" OD", 0.785), ("1-1/8\" OD", 1.025), ("1-3/8\" OD", 1.265), ("1-5/8\" OD", 1.505)]
        case .copperK:
            return [("3/8\" OD", 0.305), ("1/2\" OD", 0.402), ("5/8\" OD", 0.527), ("3/4\" OD", 0.652),
                    ("7/8\" OD", 0.745), ("1-1/8\" OD", 0.995), ("1-3/8\" OD", 1.245), ("1-5/8\" OD", 1.481)]
        }
    }
}

struct PipeCapacity: Identifiable, Sendable {
    let size: String
    let insideDiameter: Double
    /// ft³/h at the system's allowed drop over the given length.
    let cfh: Double
    let btuPerHour: Double

    var id: String { size }
}

enum PipeSizing {
    static let feetPerMetre = 3.28084
    static let btuPerKW = 3412.14

    /// Flow (ft³/h) through one size of pipe.
    static func capacityCFH(insideDiameter d: Double, lengthFeet l: Double, system: GasSystem) -> Double {
        guard d > 0, l > 0 else { return 0 }
        let gas = system.gas
        let term: Double
        let constant: Double
        if system.usesLowPressureEquation {
            let dropWC = system.dropPSI * PressureUnit.inchesWCPerPSI
            guard dropWC > 0 else { return 0 }
            term = dropWC / (gas.cr * l)
            constant = 19.17
        } else {
            let p1 = system.inletPSI + 14.7
            let p2 = p1 - system.dropPSI
            guard p2 > 0, p1 > p2 else { return 0 }
            term = (p1 * p1 - p2 * p2) * gas.y / (gas.cr * l)
            constant = 18.93
        }
        // Solve D = Q^0.381 / (C · term^0.206) for Q.
        return pow(d * constant * pow(term, 0.206), 1 / 0.381)
    }

    static func capacities(material: PipeMaterial, lengthFeet: Double, system: GasSystem) -> [PipeCapacity] {
        material.sizes.map { size in
            let cfh = capacityCFH(insideDiameter: size.id, lengthFeet: lengthFeet, system: system)
            return PipeCapacity(size: size.name, insideDiameter: size.id, cfh: cfh, btuPerHour: cfh * system.gas.btuPerCubicFoot)
        }
    }

    /// The smallest size that carries the load.
    static func recommended(_ capacities: [PipeCapacity], loadBTU: Double) -> PipeCapacity? {
        guard loadBTU > 0 else { return nil }
        return capacities.first { $0.btuPerHour >= loadBTU }
    }

    /// Pressure lost at the given load (same units as the system's drop), for showing the margin.
    static func actualDrop(insideDiameter d: Double, lengthFeet l: Double, loadBTU: Double, system: GasSystem) -> Double? {
        let q = loadBTU / system.gas.btuPerCubicFoot
        guard d > 0, l > 0, q > 0 else { return nil }
        let gas = system.gas
        // term = (Q^0.381 / (C · D))^(1/0.206)
        if system.usesLowPressureEquation {
            let term = pow(pow(q, 0.381) / (19.17 * d), 1 / 0.206)
            let dropWC = term * gas.cr * l
            return system.dropUnit == .psi ? dropWC / PressureUnit.inchesWCPerPSI : dropWC
        } else {
            let term = pow(pow(q, 0.381) / (18.93 * d), 1 / 0.206)
            let p1 = system.inletPSI + 14.7
            let p2Squared = p1 * p1 - term * gas.cr * l / gas.y
            guard p2Squared > 0 else { return nil }
            let dropPSI = p1 - sqrt(p2Squared)
            return system.dropUnit == .psi ? dropPSI : dropPSI * PressureUnit.inchesWCPerPSI
        }
    }
}
