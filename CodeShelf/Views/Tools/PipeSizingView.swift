import SwiftUI

/// Sizes steel pipe or copper tubing by the method of CSA B149.1 Annex A (longest-length, tables A.1–A.14).
struct PipeSizingView: View {
    @State private var gas: FuelGas = .natural
    @State private var units: UnitSystem = .imperial
    @State private var systemID = GasSystem.presets(for: .natural)[0].id
    @State private var customInlet: Double? = 7
    @State private var customInletUnit: PressureUnit = .inchesWC
    @State private var customDrop: Double? = 0.5
    @State private var customDropUnit: PressureUnit = .inchesWC
    @State private var customFittings = true
    @State private var material: PipeMaterial = .steelSch40
    @State private var length: Double? = 50
    @State private var fittings = FittingCounts()
    @State private var extraLength: Double? = nil
    @State private var loads = [LoadEntry(name: "Furnace", value: 100_000), LoadEntry(name: "Water heater", value: 40_000)]
    @State private var loadUnit: LoadUnit = .btu
    @FocusState private var editing: Bool

    var body: some View {
        Form {
            systemSection
            pipingSection
            if let system, !system.includesFittings {
                fittingsSection
            }
            LoadSection(loads: $loads, unit: $loadUnit, focus: $editing)
            resultSection
            capacitySection
            methodSection
        }
        .navigationTitle("Pipe Sizing")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(KeyboardDoneToolbar(focus: $editing))
        .onChange(of: units) { _, newUnits in
            loadUnit = newUnits == .metric ? .kw : .btu
        }
    }

    // MARK: Inputs

    private var systemSection: some View {
        Section {
            Picker("Gas", selection: $gas) {
                ForEach(FuelGas.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: gas) { _, newGas in
                systemID = GasSystem.presets(for: newGas)[0].id
                customInlet = newGas == .natural ? 7 : 11
            }
            Picker("Units", selection: $units) {
                ForEach(UnitSystem.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Pressure", selection: $systemID) {
                ForEach(GasSystem.presets(for: gas)) { preset in
                    Text(preset.title(units)).tag(preset.id)
                }
                Text("Custom…").tag("custom")
            }
            if systemID == "custom" {
                pressureField("Supply pressure", value: $customInlet, unit: $customInletUnit)
                pressureField("Allowed drop", value: $customDrop, unit: $customDropUnit)
                Toggle("Include fittings allowance (F = 1.2)", isOn: $customFittings)
            }
        } header: {
            Text("System")
        } footer: {
            if let system {
                Text(systemFooter(system))
            }
        }
    }

    private var pipingSection: some View {
        Section {
            Picker("Material", selection: $material) {
                ForEach(PipeMaterial.allCases) { Text($0.label).tag($0) }
            }
            HStack {
                Text("Longest run")
                Spacer()
                TextField("Length", value: $length, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                    .focused($editing)
                Text(units.lengthUnit)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Piping")
        } footer: {
            Text("Measure from the point of delivery (meter or regulator) to the most remote outlet, and use that one length for every section (A.3.4–A.3.5).\(material == .copperL ? " B149.1's tubing tables are for Type K; Type L is calculated the same way with its larger bore." : "")")
        }
    }

    private var fittingsSection: some View {
        Section {
            Stepper("90° elbows: \(fittings.elbows90)", value: $fittings.elbows90, in: 0...99)
            Stepper("45° elbows: \(fittings.elbows45)", value: $fittings.elbows45, in: 0...99)
            Stepper("Tees (through the branch): \(fittings.tees)", value: $fittings.tees, in: 0...99)
            Stepper("Plug valves / gas cocks: \(fittings.plugValves)", value: $fittings.plugValves, in: 0...99)
            HStack {
                Text("Other equivalent length")
                Spacer()
                TextField("0", value: $extraLength, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
                    .focused($editing)
                Text(units.lengthUnit)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Fittings")
        } footer: {
            Text("This table has no fittings allowance (F = 1), so fittings are added as equivalent lengths of pipe (Table A.16: elbow 30 × the inside diameter, 45° 14×, tee 60×, plug valve 30×; copper or brass valves 45% longer).")
        }
    }

    private func pressureField(_ title: String, value: Binding<Double?>, unit: Binding<PressureUnit>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 70)
                .focused($editing)
            Picker("", selection: unit) {
                ForEach(PressureUnit.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: Values

    private var system: GasSystem? {
        if systemID == "custom" {
            guard let customInlet, let customDrop, customInlet > 0, customDrop > 0 else { return nil }
            return GasSystem.custom(gas: gas, inlet: customInlet, inletUnit: customInletUnit, drop: customDrop,
                                    dropUnit: customDropUnit, includeFittings: customFittings)
        }
        return GasSystem.presets.first { $0.id == systemID }
    }

    private var runLength: Double { length ?? 0 }

    /// Load in the tables' unit: MBH (imperial) or kW (metric).
    private var load: Double {
        let btu = LoadSection.total(loads, unit: loadUnit)
        return units == .imperial ? btu / 1000 : btu / PipeSizing.btuPerKW
    }

    private var capacities: [PipeCapacity] {
        guard let system, runLength > 0 else { return [] }
        return PipeSizing.capacities(
            material: material, length: runLength, units: units, system: system,
            fittings: system.includesFittings ? FittingCounts() : fittings,
            extraLength: system.includesFittings ? 0 : (extraLength ?? 0)
        )
    }

    private func capacityText(_ value: Int) -> String {
        "\(value.formatted()) \(units.capacityUnit)"
    }

    private func lengthText(_ value: Double) -> String {
        "\(Format.number(value, digits: 1)) \(units.lengthUnit)"
    }

    private func systemFooter(_ system: GasSystem) -> String {
        var parts: [String] = [system.note + "."]
        if let table = system.table(for: material, units: units) {
            parts.append("Same as CSA B149.1 \(table).")
        } else if system.id == "custom" {
            parts.append("Calculated with the same B149.1 formulas as the tables.")
        }
        parts.append(system.includesFittings
            ? "Includes an allowance for a reasonable number of fittings (pipe length × 1.2)."
            : "No fittings allowance: add the fittings below.")
        return parts.joined(separator: " ")
    }

    // MARK: Results

    @ViewBuilder
    private var resultSection: some View {
        Section("Result") {
            if let system, runLength > 0, load > 0 {
                if let pick = PipeSizing.recommended(capacities, load: load) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pick.size)
                            .font(.largeTitle.weight(.bold))
                        Text("\(material.label) for \(Format.btu(LoadSection.total(loads, unit: loadUnit))).")
                            .font(.callout)
                        Text(rowExplanation(pick, system: system))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let drop = PipeSizing.actualDrop(insideDiameterInches: pick.insideDiameter, length: pick.effectiveLength,
                                                            load: load, units: units, system: system) {
                            Text("Pressure drop at this load over \(lengthText(pick.effectiveLength)): about \(dropText(drop, system: system)).")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Label("Larger than every size listed. Use a higher pressure system or split the load.", systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
            } else {
                Text("Enter the run length and the appliance loads.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rowExplanation(_ pick: PipeCapacity, system: GasSystem) -> String {
        let table = system.table(for: material, units: units).map { "\($0), " } ?? ""
        if pick.beyondTable {
            return "\(table)beyond the longest length the tables list, so calculated at \(lengthText(pick.effectiveLength)): carries \(capacityText(pick.capacity))."
        }
        let fittingsNote = pick.effectiveLength > runLength + 0.05 ? " (\(lengthText(pick.effectiveLength)) with fittings)" : ""
        return "\(table)\(Format.number(pick.rowLength)) \(units.lengthUnit) row\(fittingsNote): carries \(capacityText(pick.capacity)) against a load of \(Format.number(load, digits: 1)) \(units.capacityUnit)."
    }

    private func dropText(_ value: Double, system: GasSystem) -> String {
        switch units {
        case .imperial:
            return system.dropUnit.format(value)
        case .metric:
            return value < 1 ? "\(Int((value * 1000).rounded())) Pa" : PressureUnit.kPa.format(value)
        }
    }

    @ViewBuilder
    private var capacitySection: some View {
        if let system, !capacities.isEmpty {
            let pick = PipeSizing.recommended(capacities, load: load)
            let rowsDiffer = Set(capacities.map(\.rowLength)).count > 1
            Section {
                ForEach(capacities) { item in
                    HStack {
                        Text(item.size)
                            .fontWeight(item.id == pick?.id ? .bold : .regular)
                        if rowsDiffer {
                            Text("\(Format.number(item.rowLength)) \(units.lengthUnit)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(capacityText(item.capacity))
                            .monospacedDigit()
                        if item.id == pick?.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .foregroundStyle(load > 0 && Double(item.capacity) < load ? Color.secondary : Color.primary)
                }
            } header: {
                if rowsDiffer {
                    Text("Capacity (length row per size, with fittings)")
                } else {
                    Text("Capacity at the \(Format.number(capacities[0].rowLength)) \(units.lengthUnit) row")
                }
            } footer: {
                Text("\(gas.label), \(system.title(units)). \(units == .imperial ? "MBH = thousands of Btu/h" : "kW").")
            }
        }
    }

    private var methodSection: some View {
        Section {
            Text("Calculated with the formulas in CSA B149.1-20 clauses A.3.5 and B.3.5, which generate capacity Tables A.1–A.14 (natural gas, 1,000 Btu/ft³, relative density 0.6) and B.1–B.10 (propane, 2,520 Btu/ft³, relative density 1.52). It uses Schedule 40 and Type K copper inside diameters, and the tables' 20% fittings allowance where they include one. Like the tables, it reads the next larger length and picks the first size whose capacity covers the load. Results match the printed tables to within rounding.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
