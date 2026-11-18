import Foundation

// MARK: - Transportation of Dangerous Goods

/// A fuel's dangerous goods identification under Canada's TDG Regulations (UN number, proper
/// shipping name, class) with its Emergency Response Guidebook (ERG 2024) guide number.
struct DangerousGood: Identifiable, Hashable, Sendable {
    let un: String
    let shippingName: String
    let commonName: String
    let dgClass: String
    let packingGroup: String?
    let ergGuide: Int
    let note: String

    var id: String { un + shippingName }

    var classDescription: String {
        switch dgClass {
        case "2.1": return "Class 2.1 – Flammable gas"
        case "3": return "Class 3 – Flammable liquid"
        default: return "Class \(dgClass)"
        }
    }

    var placard: String {
        switch dgClass {
        case "2.1": return "Red placard, flame symbol, class number 2"
        case "3": return "Red placard, flame symbol, class number 3"
        default: return "Class \(dgClass) placard"
        }
    }
}

enum TDGReference {
    static let goods: [DangerousGood] = [
        DangerousGood(un: "UN1075", shippingName: "PETROLEUM GASES, LIQUEFIED or LIQUEFIED PETROLEUM GAS",
                      commonName: "LPG / propane (bulk)", dgClass: "2.1", packingGroup: nil, ergGuide: 115,
                      note: "The number usually shown on bulk propane trucks and large tanks. Covers propane, butane and their mixtures."),
        DangerousGood(un: "UN1978", shippingName: "PROPANE",
                      commonName: "Propane", dgClass: "2.1", packingGroup: nil, ergGuide: 115,
                      note: "Propane cylinders and bulk propane shipped by its own name."),
        DangerousGood(un: "UN1011", shippingName: "BUTANE",
                      commonName: "Butane", dgClass: "2.1", packingGroup: nil, ergGuide: 115,
                      note: "Butane cylinders and cartridges."),
        DangerousGood(un: "UN1969", shippingName: "ISOBUTANE",
                      commonName: "Isobutane", dgClass: "2.1", packingGroup: nil, ergGuide: 115,
                      note: "Isobutane and isobutane mixtures."),
        DangerousGood(un: "UN1965", shippingName: "HYDROCARBON GAS MIXTURE, LIQUEFIED, N.O.S.",
                      commonName: "Liquefied fuel gas mixture", dgClass: "2.1", packingGroup: nil, ergGuide: 115,
                      note: "Liquefied hydrocarbon gas mixtures not listed by name, e.g. propane/butane camping cartridges."),
        DangerousGood(un: "UN1971", shippingName: "NATURAL GAS, COMPRESSED (with high methane content) or METHANE, COMPRESSED",
                      commonName: "Natural gas – CNG", dgClass: "2.1", packingGroup: nil, ergGuide: 115,
                      note: "Compressed natural gas cylinders and tube trailers."),
        DangerousGood(un: "UN1972", shippingName: "NATURAL GAS, REFRIGERATED LIQUID (with high methane content) or METHANE, REFRIGERATED LIQUID",
                      commonName: "Natural gas – LNG", dgClass: "2.1", packingGroup: nil, ergGuide: 115,
                      note: "Liquefied natural gas, cryogenic."),
        DangerousGood(un: "UN1203", shippingName: "GASOLINE (also MOTOR SPIRIT or PETROL)",
                      commonName: "Gasoline", dgClass: "3", packingGroup: "II", ergGuide: 128,
                      note: "Regular and premium gasoline, including blends up to 10% ethanol."),
        DangerousGood(un: "UN1202", shippingName: "DIESEL FUEL or GAS OIL or HEATING OIL, LIGHT",
                      commonName: "Diesel, dyed diesel, furnace oil", dgClass: "3", packingGroup: "III", ergGuide: 128,
                      note: "Clear and coloured (dyed) diesel, and light heating oil (No. 2 furnace oil)."),
        DangerousGood(un: "UN1223", shippingName: "KEROSENE",
                      commonName: "Kerosene (No. 1 fuel oil)", dgClass: "3", packingGroup: "III", ergGuide: 128,
                      note: "Kerosene and stove oil."),
        DangerousGood(un: "UN1863", shippingName: "FUEL, AVIATION, TURBINE ENGINE",
                      commonName: "Jet fuel", dgClass: "3", packingGroup: "I, II or III", ergGuide: 128,
                      note: "Jet A / Jet A-1; the packing group depends on the flash and boiling points."),
        DangerousGood(un: "UN1170", shippingName: "ETHANOL or ETHYL ALCOHOL",
                      commonName: "Ethanol", dgClass: "3", packingGroup: "II or III", ergGuide: 127,
                      note: "Fuel ethanol and ethanol solutions."),
        DangerousGood(un: "UN3475", shippingName: "ETHANOL AND GASOLINE MIXTURE (with more than 10% ethanol)",
                      commonName: "Ethanol blends (E15–E85)", dgClass: "3", packingGroup: "II", ergGuide: 127,
                      note: "Gasoline blends with more than 10% ethanol, e.g. E85."),
        DangerousGood(un: "UN1001", shippingName: "ACETYLENE, DISSOLVED",
                      commonName: "Acetylene", dgClass: "2.1", packingGroup: nil, ergGuide: 116,
                      note: "Welding and brazing cylinders."),
        DangerousGood(un: "UN2363", shippingName: "ETHYL MERCAPTAN",
                      commonName: "Odorant (ethyl mercaptan)", dgClass: "3", packingGroup: "I", ergGuide: 130,
                      note: "The odorant added to propane."),
    ]
}

// MARK: - Natural gas ⇄ propane

enum GasConversion {
    /// Number drill sizes used for burner orifices (#20–#80), diameter in inches.
    static let drills: [(name: String, diameter: Double)] = [
        ("#20", 0.1610), ("#21", 0.1590), ("#22", 0.1570), ("#23", 0.1540), ("#24", 0.1520), ("#25", 0.1495),
        ("#26", 0.1470), ("#27", 0.1440), ("#28", 0.1405), ("#29", 0.1360), ("#30", 0.1285), ("#31", 0.1200),
        ("#32", 0.1160), ("#33", 0.1130), ("#34", 0.1110), ("#35", 0.1100), ("#36", 0.1065), ("#37", 0.1040),
        ("#38", 0.1015), ("#39", 0.0995), ("#40", 0.0980), ("#41", 0.0960), ("#42", 0.0935), ("#43", 0.0890),
        ("#44", 0.0860), ("#45", 0.0820), ("#46", 0.0810), ("#47", 0.0785), ("#48", 0.0760), ("#49", 0.0730),
        ("#50", 0.0700), ("#51", 0.0670), ("#52", 0.0635), ("#53", 0.0595), ("#54", 0.0550), ("#55", 0.0520),
        ("#56", 0.0465), ("#57", 0.0430), ("#58", 0.0420), ("#59", 0.0410), ("#60", 0.0400), ("#61", 0.0390),
        ("#62", 0.0380), ("#63", 0.0370), ("#64", 0.0360), ("#65", 0.0350), ("#66", 0.0330), ("#67", 0.0320),
        ("#68", 0.0310), ("#69", 0.0292), ("#70", 0.0280), ("#71", 0.0260), ("#72", 0.0250), ("#73", 0.0240),
        ("#74", 0.0225), ("#75", 0.0210), ("#76", 0.0200), ("#77", 0.0180), ("#78", 0.0160), ("#79", 0.0145),
        ("#80", 0.0135),
    ]

    /// Orifice flow is Q = 1658.5 · A · Cd · √(h / d). For the same input (Btu/h) on both gases, and the same
    /// discharge coefficient, the propane orifice area is
    ///   A_LP / A_NG = (HV_NG / HV_LP) · √[(h_NG / d_NG) / (h_LP / d_LP)]
    /// so the diameter ratio is its square root. Defaults: B149.1 heating values and relative densities,
    /// 3.5" w.c. natural gas and 10" w.c. propane manifold pressure.
    static func diameterRatio(ngManifold: Double = 3.5, lpManifold: Double = 10,
                              ngHeat: Double = 1000, lpHeat: Double = 2520,
                              ngDensity: Double = 0.60, lpDensity: Double = 1.52) -> Double {
        guard ngManifold > 0, lpManifold > 0, ngHeat > 0, lpHeat > 0 else { return 0 }
        let areaRatio = (ngHeat / lpHeat) * sqrt((ngManifold / ngDensity) / (lpManifold / lpDensity))
        return sqrt(areaRatio)
    }

    /// The drill closest to a diameter.
    static func nearestDrill(to diameter: Double) -> (name: String, diameter: Double) {
        drills.min { abs($0.diameter - diameter) < abs($1.diameter - diameter) } ?? (name: "—", diameter: diameter)
    }

    // MARK: Energy

    enum EnergyUnit: String, CaseIterable, Identifiable {
        case cubicMetresNG, cubicFeetNG, litresPropane, gallonsPropane, poundsPropane, kilogramsPropane
        case kWh, megajoules, btu, therms

        var id: String { rawValue }

        var label: String {
            switch self {
            case .cubicMetresNG: return "m³ natural gas"
            case .cubicFeetNG: return "ft³ natural gas"
            case .litresPropane: return "L propane (liquid)"
            case .gallonsPropane: return "US gal propane (liquid)"
            case .poundsPropane: return "lb propane"
            case .kilogramsPropane: return "kg propane"
            case .kWh: return "kWh"
            case .megajoules: return "MJ"
            case .btu: return "Btu"
            case .therms: return "therms"
            }
        }
    }

    /// Liquid propane: about 25.3 MJ per litre, 0.507 kg per litre at 15 °C.
    static let propaneMJPerLitre = 25.3
    static let propaneKgPerLitre = 0.507

    /// Megajoules in one unit. `ngMJPerM3` is the natural gas heat value (B149.1's tables use 1,000 Btu/ft³ = 37.3 MJ/m³).
    static func megajoules(per unit: EnergyUnit, ngMJPerM3: Double) -> Double {
        switch unit {
        case .cubicMetresNG: return ngMJPerM3
        case .cubicFeetNG: return ngMJPerM3 / 35.3147
        case .litresPropane: return propaneMJPerLitre
        case .gallonsPropane: return propaneMJPerLitre * 3.785_41
        case .kilogramsPropane: return propaneMJPerLitre / propaneKgPerLitre
        case .poundsPropane: return propaneMJPerLitre / propaneKgPerLitre / 2.204_62
        case .kWh: return 3.6
        case .megajoules: return 1
        case .btu: return 0.001_055_056
        case .therms: return 105.5056
        }
    }

    static func convert(_ amount: Double, from: EnergyUnit, to: EnergyUnit, ngMJPerM3: Double) -> Double {
        amount * megajoules(per: from, ngMJPerM3: ngMJPerM3) / megajoules(per: to, ngMJPerM3: ngMJPerM3)
    }

    struct Property: Identifiable {
        let name: String
        let naturalGas: String
        let propane: String
        var id: String { name }
    }

    static let properties: [Property] = [
        Property(name: "Heating value (gas)", naturalGas: "1,000 Btu/ft³ (37.3 MJ/m³)*", propane: "2,520 Btu/ft³ (93.9 MJ/m³)*"),
        Property(name: "Heating value (liquid)", naturalGas: "—", propane: "≈ 25.3 MJ/L (≈ 91,500 Btu/US gal)"),
        Property(name: "Relative density (air = 1)", naturalGas: "0.60*: lighter than air, rises", propane: "1.52*: heavier than air, collects low"),
        Property(name: "Typical appliance supply pressure", naturalGas: "7\" w.c. (1.74 kPa)", propane: "11\" w.c. (2.74 kPa)"),
        Property(name: "Typical manifold pressure", naturalGas: "3.5\" w.c. (0.87 kPa)", propane: "10\" w.c. (2.49 kPa)"),
        Property(name: "Air for combustion", naturalGas: "≈ 10 ft³ per ft³ of gas", propane: "≈ 24 ft³ per ft³ of gas"),
        Property(name: "Flammable range in air", naturalGas: "≈ 5 – 15 %", propane: "≈ 2.1 – 9.5 %"),
        Property(name: "Boiling point", naturalGas: "−162 °C (as LNG)", propane: "−42 °C"),
        Property(name: "Liquid to gas expansion", naturalGas: "≈ 1 : 600 (LNG)", propane: "≈ 1 : 270"),
        Property(name: "Same input, orifice diameter", naturalGas: "1", propane: "≈ 0.61 × the natural gas orifice"),
    ]
}
