import SwiftUI

/// Natural gas ⇄ propane: properties side by side, energy equivalents, and orifice drill conversions.
struct GasConversionView: View {
    @State private var amount: Double? = 1
    @State private var unit: GasConversion.EnergyUnit = .litresPropane
    @State private var ngHeat: Double? = 37.3
    @State private var toPropane = true
    @State private var ngManifold: Double? = 3.5
    @State private var lpManifold: Double? = 10
    @FocusState private var editing: Bool

    var body: some View {
        Form {
            propertiesSection
            energySection
            orificeSection
        }
        .navigationTitle("Natural Gas ⇄ Propane")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(KeyboardDoneToolbar(focus: $editing))
    }

    // MARK: Properties

    private var propertiesSection: some View {
        Section {
            HStack {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                Text("Natural gas").font(.caption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                Text("Propane").font(.caption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(GasConversion.properties) { property in
                HStack(alignment: .top) {
                    Text(property.name).font(.caption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(property.naturalGas).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    Text(property.propane).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } header: {
            Text("Properties")
        } footer: {
            Text("* Values CSA B149.1 Annexes A and B use for their capacity tables. Pressures are typical: always set the ones on the appliance rating plate.")
        }
    }

    // MARK: Energy

    private var energySection: some View {
        Section {
            HStack {
                TextField("Amount", value: $amount, format: .number)
                    .keyboardType(.decimalPad)
                    .focused($editing)
                Picker("", selection: $unit) {
                    ForEach(GasConversion.EnergyUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
            }
            ForEach(GasConversion.EnergyUnit.allCases.filter { $0 != unit }) { other in
                HStack {
                    Text(other.label)
                    Spacer()
                    Text(formatted(GasConversion.convert(amount ?? 0, from: unit, to: other, ngMJPerM3: ngHeat ?? 37.3)))
                        .monospacedDigit()
                }
            }
            HStack {
                Text("Natural gas heat value")
                Spacer()
                TextField("37.3", value: $ngHeat, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 70)
                    .focused($editing)
                Text("MJ/m³").foregroundStyle(.secondary)
            }
        } header: {
            Text("Same energy in other units")
        } footer: {
            Text("37.3 MJ/m³ is the 1,000 Btu/ft³ B149.1's tables use; your gas bill shows the heat value actually delivered. Propane: 25.3 MJ per litre of liquid, 0.507 kg/L.")
        }
    }

    private func formatted(_ value: Double) -> String {
        let digits = value >= 1000 ? 0 : value >= 10 ? 2 : 4
        return value.formatted(.number.precision(.fractionLength(0...digits)))
    }

    // MARK: Orifices

    private var ratio: Double {
        GasConversion.diameterRatio(ngManifold: ngManifold ?? 3.5, lpManifold: lpManifold ?? 10)
    }

    private var orificeSection: some View {
        Section {
            Picker("Direction", selection: $toPropane) {
                Text("Natural gas → propane").tag(true)
                Text("Propane → natural gas").tag(false)
            }
            .pickerStyle(.segmented)
            pressureRow("Natural gas manifold", value: $ngManifold)
            pressureRow("Propane manifold", value: $lpManifold)
            HStack {
                Text(toPropane ? "Natural gas drill" : "Propane drill").font(.caption.weight(.semibold))
                Spacer()
                Text(toPropane ? "Propane drill (same input)" : "Natural gas drill (same input)").font(.caption.weight(.semibold))
            }
            ForEach(rows, id: \.from) { row in
                HStack {
                    Text("\(row.from)  (\(inches(row.fromDiameter)))")
                        .monospacedDigit()
                    Spacer()
                    Text("\(row.to)  (\(inches(row.toDiameter)))")
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
                .font(.callout)
            }
        } header: {
            Text("Orifice drill sizes")
        } footer: {
            Text("For the same Btu/h, a propane orifice is about \(ratio.formatted(.number.precision(.fractionLength(2)))) × the natural gas diameter (from Q = 1658.5 · A · Cd · √(h/d), B149.1 heating values and densities, at these manifold pressures). Nearest number drill shown. A conversion must use the appliance manufacturer's certified conversion kit and instructions; use this to check sizes, not to drill orifices.")
        }
    }

    private func pressureRow(_ title: String, value: Binding<Double?>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 60)
                .focused($editing)
            Text("in. w.c.").foregroundStyle(.secondary)
        }
    }

    private struct DrillRow {
        let from: String
        let fromDiameter: Double
        let to: String
        let toDiameter: Double
    }

    private var rows: [DrillRow] {
        let factor = toPropane ? ratio : (ratio > 0 ? 1 / ratio : 0)
        let source = GasConversion.drills.filter { drill in
            // Sizes whose converted orifice is still a number drill.
            let converted = drill.diameter * factor
            return converted >= 0.0135 && converted <= 0.161
        }
        return source.map { drill in
            let match = GasConversion.nearestDrill(to: drill.diameter * factor)
            return DrillRow(from: drill.name, fromDiameter: drill.diameter, to: match.name, toDiameter: match.diameter)
        }
    }

    private func inches(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(4))) + "\""
    }
}
