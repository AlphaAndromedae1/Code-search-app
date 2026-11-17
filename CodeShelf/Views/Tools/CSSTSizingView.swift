import SwiftUI

/// Sizes CSST from the manufacturer's capacity tables (longest-length method, fittings allowance L = 1.3n).
struct CSSTSizingView: View {
    @State private var gas: FuelGas = .natural
    @State private var tableID = CSSTSizing.tables(for: .natural).first?.id ?? ""
    @State private var length: Double? = 40
    @State private var lengthUnit: LengthUnit = .feet
    @State private var extraFittings = 0
    @State private var loads = [LoadEntry(name: "Furnace", value: 80_000), LoadEntry(name: "Range", value: 65_000)]
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
                    tableID = CSSTSizing.tables(for: newGas).first?.id ?? ""
                }

                Picker("Pressure", selection: $tableID) {
                    ForEach(CSSTSizing.tables(for: gas)) { table in
                        Text(table.title).tag(table.id)
                    }
                }
            } header: {
                Text("System")
            } footer: {
                if let table {
                    Text("Gastite / FlashShield Table \(table.table), \(table.unit == "CFH" ? "ft³/h of natural gas (0.60 s.g.)" : "thousands of BTU/h of propane (1.52 s.g.)").")
                }
            }

            Section {
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
                Stepper(value: $extraFittings, in: 0...60) {
                    HStack {
                        Text("Extra fittings / bends")
                        Spacer()
                        Text("\(extraFittings)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Tubing")
            } footer: {
                Text("The tables already allow for four 90° bends and two end fittings. Each extra fitting or bend adds 1.3 ft (L = 1.3n). Use the run from the meter or regulator to the farthest appliance.")
            }

            LoadSection(loads: $loads, unit: $loadUnit, focus: $editing)

            if let table {
                resultSection(table)
            }

            Section {
                Text("CSA B149.1 requires CSST to be sized and installed to the manufacturer's instructions. These tables are Gastite / FlashShield's. TracPipe, WARDFlex and other brands use different EHD sizes, so use their own tables (in the Fuel Equipment Library). Natural gas loads are converted at 1,000 BTU/ft³.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("CSST Sizing")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(KeyboardDoneToolbar(focus: $editing))
    }

    private var table: CSSTTable? {
        CSSTSizing.tables.first { $0.id == tableID }
    }

    private var lengthFeet: Double {
        lengthUnit.toFeet(length ?? 0)
    }

    private var loadBTU: Double {
        LoadSection.total(loads, unit: loadUnit)
    }

    private func capacityText(_ value: Int, table: CSSTTable) -> String {
        table.unit == "CFH" ? "\(value.formatted()) ft³/h" : "\(value.formatted()) MBH"
    }

    @ViewBuilder
    private func resultSection(_ table: CSSTTable) -> some View {
        let result = CSSTSizing.size(table: table, lengthFeet: lengthFeet, extraFittings: extraFittings, loadBTU: loadBTU)
        Section("Result") {
            if lengthFeet <= 0 || loadBTU <= 0 {
                Text("Enter the run length and the appliance loads.")
                    .foregroundStyle(.secondary)
            } else if let result {
                if let pick = result.recommended {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(pick.size) CSST")
                            .font(.largeTitle.weight(.bold))
                        Text("EHD \(pick.ehd) · \(Format.btu(loadBTU)) = \(capacityText(Int(result.load.rounded()), table: table))")
                            .font(.callout)
                        Text("Read at the \(result.columnFeet) ft column (run \(Format.number(lengthFeet)) ft + \(Format.number(CSSTSizing.fittingAllowance(extraFittings: extraFittings), digits: 1)) ft for fittings).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let capacity = result.capacities.first(where: { $0.row.ehd == pick.ehd })?.capacity,
                           result.load > Double(capacity) * 0.95 {
                            Label("Within 5% of this size's capacity. Consider the next size up.", systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        if let caution = table.caution {
                            Label(caution, systemImage: "info.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Label("More than 2\" CSST carries at this length. Use a higher pressure system, steel pipe, or split the load.", systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
            } else {
                Label("Longer than the tables go (1,500 ft).", systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
        }

        if let result {
            Section {
                ForEach(result.capacities) { item in
                    HStack {
                        Text(item.row.size)
                            .fontWeight(item.row.ehd == result.recommended?.ehd ? .bold : .regular)
                        Text("EHD \(item.row.ehd)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(capacityText(item.capacity, table: table))
                            .monospacedDigit()
                        if item.row.ehd == result.recommended?.ehd {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .foregroundStyle(result.load > 0 && Double(item.capacity) < result.load ? Color.secondary : Color.primary)
                }
            } header: {
                Text("Capacity at \(result.columnFeet) ft")
            } footer: {
                Text(CSSTSizing.source)
            }
        }
    }
}
