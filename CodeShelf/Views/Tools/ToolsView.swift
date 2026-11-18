import SwiftUI

/// Calculators and references for fuel work, plus side-by-side code book comparison.
struct ToolsView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.toolsPath) {
            List {
                Section("Gas Piping") {
                    NavigationLink(value: ToolRoute.pipeSizing) {
                        ToolRow(
                            title: "Pipe Sizing",
                            subtitle: "CSA B149.1 Annex A method · steel and Type K copper · 7\" w.c. to 20 psi",
                            symbol: "ruler"
                        )
                    }
                    NavigationLink(value: ToolRoute.csstSizing) {
                        ToolRow(
                            title: "CSST Sizing",
                            subtitle: "Manufacturer capacity tables by EHD, with the fittings allowance",
                            symbol: "arrow.triangle.branch"
                        )
                    }
                    NavigationLink(value: ToolRoute.gasConversion) {
                        ToolRow(
                            title: "Natural Gas ⇄ Propane",
                            subtitle: "Properties side by side, energy equivalents, orifice drill conversions",
                            symbol: "arrow.left.arrow.right"
                        )
                    }
                }
                Section("Safety") {
                    NavigationLink(value: ToolRoute.tdg) {
                        ToolRow(
                            title: "TDG – Fuels",
                            subtitle: "UN numbers (UN1075, UN1978…), shipping names, classes and ERG guides",
                            symbol: "exclamationmark.triangle"
                        )
                    }
                }
                Section("Prices") {
                    NavigationLink(value: ToolRoute.fuelPrices) {
                        ToolRow(
                            title: "Fuel Prices",
                            subtitle: "Propane, natural gas, furnace oil, gasoline, diesel and dyed diesel in Ontario (CAD)",
                            symbol: "fuelpump"
                        )
                    }
                }
                Section("Code Books") {
                    NavigationLink(value: ToolRoute.compare) {
                        ToolRow(
                            title: "Compare",
                            subtitle: "Two code books side by side, searched together",
                            symbol: "rectangle.split.2x1"
                        )
                    }
                }
            }
            .navigationTitle("Tools")
            .navigationDestination(for: ToolRoute.self) { route in
                switch route {
                case .pipeSizing: PipeSizingView()
                case .csstSizing: CSSTSizingView()
                case .fuelPrices: FuelPricesView()
                case .gasConversion: GasConversionView()
                case .tdg: TDGView()
                case .compare: CompareView()
                }
            }
        }
    }
}

private struct ToolRow: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Shared pieces for the calculators

enum LoadUnit: String, CaseIterable, Identifiable {
    case btu
    case kw

    var id: String { rawValue }

    var label: String {
        switch self {
        case .btu: return "BTU/h"
        case .kw: return "kW"
        }
    }

    func toBTU(_ value: Double) -> Double {
        self == .btu ? value : value * PipeSizing.btuPerKW
    }
}

enum LengthUnit: String, CaseIterable, Identifiable {
    case feet
    case metres

    var id: String { rawValue }

    var label: String {
        switch self {
        case .feet: return "ft"
        case .metres: return "m"
        }
    }

    func toFeet(_ value: Double) -> Double {
        self == .feet ? value : value * PipeSizing.feetPerMetre
    }
}

struct LoadEntry: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var value: Double?
}

/// Appliance inputs that add up to the load on a run of piping.
struct LoadSection: View {
    @Binding var loads: [LoadEntry]
    @Binding var unit: LoadUnit
    var focus: FocusState<Bool>.Binding

    var body: some View {
        Section {
            Picker("Units", selection: $unit) {
                ForEach(LoadUnit.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            ForEach($loads) { $load in
                HStack {
                    TextField("Appliance", text: $load.name)
                        .focused(focus)
                    TextField(unit.label, value: $load.value, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 130)
                        .focused(focus)
                    Text(unit.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                loads.remove(atOffsets: offsets)
                if loads.isEmpty { loads = [LoadEntry(name: "Appliance 1", value: nil)] }
            }

            Button {
                loads.append(LoadEntry(name: "Appliance \(loads.count + 1)", value: nil))
            } label: {
                Label("Add Appliance", systemImage: "plus.circle")
            }

            HStack {
                Text("Total load")
                    .fontWeight(.semibold)
                Spacer()
                Text(Format.btu(totalBTU))
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
        } header: {
            Text("Load on this run")
        } footer: {
            Text("Add every appliance this section of piping supplies, at its full input rating.")
        }
    }

    var totalBTU: Double {
        loads.compactMap(\.value).reduce(0) { $0 + unit.toBTU($1) }
    }

    static func total(_ loads: [LoadEntry], unit: LoadUnit) -> Double {
        loads.compactMap(\.value).reduce(0) { $0 + unit.toBTU($1) }
    }
}

enum Format {
    static func btu(_ value: Double) -> String {
        guard value > 0 else { return "—" }
        let kw = value / PipeSizing.btuPerKW
        return "\(Int(value.rounded()).formatted()) BTU/h (\(kw.formatted(.number.precision(.fractionLength(1)))) kW)"
    }

    static func mbh(_ value: Double) -> String {
        "\(Int((value / 1000).rounded()).formatted()) MBH"
    }

    static func number(_ value: Double, digits: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)))
    }

    static func length(feet: Double, unit: LengthUnit) -> String {
        switch unit {
        case .feet: return "\(number(feet)) ft"
        case .metres: return "\(number(feet / PipeSizing.feetPerMetre, digits: 1)) m (\(number(feet)) ft)"
        }
    }
}

/// Keyboard "Done" button for the number pads.
struct KeyboardDoneToolbar: ViewModifier {
    var focus: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus.wrappedValue = false }
            }
        }
    }
}
