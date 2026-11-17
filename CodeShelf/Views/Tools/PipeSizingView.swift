import SwiftUI

/// Sizes steel pipe or copper tubing for natural gas or propane by the longest-length method.
struct PipeSizingView: View {
    @State private var gas: FuelGas = .natural
    @State private var systemID = GasSystem.presets(for: .natural)[0].id
    @State private var customInlet: Double? = 7
    @State private var customInletUnit: PressureUnit = .inchesWC
    @State private var customDrop: Double? = 0.5
    @State private var customDropUnit: PressureUnit = .inchesWC
    @State private var material: PipeMaterial = .steelSch40
    @State private var length: Double? = 50
    @State private var lengthUnit: LengthUnit = .feet
    @State private var loads = [LoadEntry(name: "Furnace", value: 100_000), LoadEntry(name: "Water heater", value: 40_000)]
    @State private var loadUnit: LoadUnit = .btu
    @FocusState private var editing: Bool

    var body: some View {
        Form {
            Section {
                Picker("Gas", selection: $gas) {
                    ForEach(FuelGas.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: gas) { _, newGas in
                    systemID = GasSystem.presets(for: newGas)[0].id
                    customInlet = newGas == .natural ? 7 : 11
                }

                Picker("Pressure", selection: $systemID) {
                    ForEach(GasSystem.presets(for: gas)) { preset in
                        Text(preset.title).tag(preset.id)
                    }
                    Text("Custom…").tag("custom")
                }
                if systemID == "custom" {
                    pressureField("Supply pressure", value: $customInlet, unit: $customInletUnit)
                    pressureField("Allowed drop", value: $customDrop, unit: $customDropUnit)
                }
            } header: {
                Text("System")
            } footer: {
                if let system {
                    Text("\(system.note). \(system.usesLowPressureEquation ? "Low-pressure equation" : "High-pressure equation") · \(gas.label) at \(Format.number(gas.btuPerCubicFoot)) BTU/ft³.")
                }
            }

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
                    Picker("", selection: $lengthUnit) {
                        ForEach(LengthUnit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 90)
                }
            } header: {
                Text("Piping")
            } footer: {
                Text("Longest-length method: use the distance from the meter or regulator outlet to the farthest appliance for every section of the system.")
            }

            LoadSection(loads: $loads, unit: $loadUnit, focus: $editing)

            resultSection
            capacitySection

            Section {
                Text("Capacities come from the general gas flow equations the code sizing tables are built on (IFGC 402.4 equations 4-1 and 4-2 / NFPA 54), using actual inside diameters. In Ontario, CSA B149.1 governs. Confirm the size against its pipe and tubing capacity tables and the appliance's minimum inlet pressure. Results usually fall within a few percent of the tables.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Pipe Sizing")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(KeyboardDoneToolbar(focus: $editing))
    }

    // MARK: Inputs

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
            .pickerStyle(.segmented)
            .frame(width: 130)
        }
    }

    private var system: GasSystem? {
        if systemID == "custom" {
            guard let customInlet, let customDrop, customInlet > 0, customDrop > 0 else { return nil }
            return GasSystem.custom(gas: gas, inlet: customInlet, inletUnit: customInletUnit, drop: customDrop, dropUnit: customDropUnit)
        }
        return GasSystem.presets.first { $0.id == systemID }
    }

    private var lengthFeet: Double {
        lengthUnit.toFeet(length ?? 0)
    }

    private var loadBTU: Double {
        LoadSection.total(loads, unit: loadUnit)
    }

    private var capacities: [PipeCapacity] {
        guard let system, lengthFeet > 0 else { return [] }
        return PipeSizing.capacities(material: material, lengthFeet: lengthFeet, system: system)
    }

    // MARK: Results

    @ViewBuilder
    private var resultSection: some View {
        Section("Result") {
            if let system, lengthFeet > 0, loadBTU > 0 {
                if let pick = PipeSizing.recommended(capacities, loadBTU: loadBTU) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pick.size)
                            .font(.largeTitle.weight(.bold))
                        Text("\(material.label) for \(Format.btu(loadBTU)) over \(Format.length(feet: lengthFeet, unit: lengthUnit)).")
                            .font(.callout)
                        Text("Carries up to \(Format.mbh(pick.btuPerHour)) (\(Format.number(pick.cfh)) ft³/h) at \(system.dropUnit.format(system.drop)) drop.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let drop = PipeSizing.actualDrop(insideDiameter: pick.insideDiameter, lengthFeet: lengthFeet, loadBTU: loadBTU, system: system) {
                            Text("Pressure drop at this load: about \(system.dropUnit.format(drop)).")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if loadBTU > pick.btuPerHour * 0.95 {
                            Label("Within 5% of this size's capacity. Check the B149.1 table, or go up a size.", systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Label("Larger than every size listed. Raise the pressure, shorten the run or split the load.", systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
            } else {
                Text("Enter the run length and the appliance loads.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var capacitySection: some View {
        if let system, !capacities.isEmpty {
            let pick = PipeSizing.recommended(capacities, loadBTU: loadBTU)
            Section {
                ForEach(capacities) { item in
                    HStack {
                        Text(item.size)
                            .fontWeight(item.id == pick?.id ? .bold : .regular)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Format.mbh(item.btuPerHour))
                                .monospacedDigit()
                            Text("\(Format.number(item.cfh)) ft³/h")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        if item.id == pick?.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .foregroundStyle(loadBTU > 0 && item.btuPerHour < loadBTU ? Color.secondary : Color.primary)
                }
            } header: {
                Text("Capacity at \(Format.length(feet: lengthFeet, unit: lengthUnit))")
            } footer: {
                Text("\(gas.label), \(system.title). MBH = thousands of BTU/h.")
            }
        }
    }
}
