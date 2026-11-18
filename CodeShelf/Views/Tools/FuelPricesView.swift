import SwiftUI

/// This week's retail fuel prices in Ontario, in Canadian cents per litre.
struct FuelPricesView: View {
    @State private var prices = FuelPriceStore.shared
    @AppStorage(FuelPriceStore.marketKey) private var market = FuelPriceStore.averageMarket
    @AppStorage(FuelPriceStore.dyedDiscountKey) private var dyedDiscount = FuelPriceStore.defaultDyedDiscount
    @AppStorage(FuelPriceStore.gasUtilityKey) private var gasUtility = FuelPriceStore.defaultGasUtility

    var body: some View {
        List {
            if prices.snapshot == nil {
                Section {
                    if prices.isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Getting this week's prices…")
                        }
                    } else {
                        ContentUnavailableView(
                            "No Prices Yet",
                            systemImage: "fuelpump",
                            description: Text(prices.errorMessage ?? "Pull down to download this week's prices.")
                        )
                    }
                }
            } else {
                marketSection
                ForEach(prices.rows(market: market, dyedDiscount: dyedDiscount)) { row in
                    PriceRowView(row: row)
                        .id("\(row.id)-\(gasUtility)")
                }
                gasSection
                dyedSection
                furnaceOilSection
            }
            sourcesSection
        }
        .navigationTitle("Fuel Prices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if prices.isLoading {
                    ProgressView()
                } else {
                    Button {
                        Task { await prices.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .refreshable { await prices.refresh() }
        .task { await prices.refreshIfStale() }
    }

    private var marketSection: some View {
        Section {
            Picker("Area", selection: $market) {
                ForEach(orderedMarkets, id: \.self) { name in
                    Text(FuelPriceStore.displayName(ofMarket: name)).tag(name)
                }
            }
            if prices.isLoadingFurnaceOil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Getting furnace oil prices from NRCan…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let message = prices.errorMessage {
                Label(message, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } footer: {
            if let fetched = prices.snapshot?.fetched {
                Text("Fuels in cents per litre, taxes included; natural gas in cents per cubic metre, before HST. Checked \(fetched.formatted(.relative(presentation: .named))).")
            }
        }
    }

    /// Averages first, then the survey markets in the CSV's order.
    private var orderedMarkets: [String] {
        let all = prices.snapshot?.markets ?? [FuelPriceStore.averageMarket]
        let averages = all.filter { $0.contains("Average") }
        return averages + all.filter { !$0.contains("Average") }
    }

    @ViewBuilder
    private var gasSection: some View {
        let rates = prices.snapshot?.naturalGas ?? []
        if !rates.isEmpty {
            Section {
                Picker("Gas utility", selection: $gasUtility) {
                    ForEach(rates) { rate in
                        Text(FuelPriceStore.displayName(ofUtility: rate.utility)).tag(rate.utility)
                    }
                }
                ForEach(rates) { rate in
                    HStack {
                        Text(FuelPriceStore.displayName(ofUtility: rate.utility))
                            .font(.callout)
                        Spacer()
                        Text("\(rate.centsPerCubicMetre.formatted(.number.precision(.fractionLength(2))))¢/m³")
                            .monospacedDigit()
                            .font(.callout)
                    }
                }
            } header: {
                Text("Natural gas supply charges\(prices.snapshot?.naturalGasEffective.map { ", \($0)" } ?? "")")
            } footer: {
                Text("Set by the Ontario Energy Board every quarter, with no markup. Enbridge's EGD zone covers most of the GTA, Ottawa and Niagara. Union South covers southwestern Ontario, Union North East covers places like Sudbury, North Bay and Timmins, and Union North West covers places like Thunder Bay and Kenora. Kitchener Utilities and Utilities Kingston aren't set by the OEB.")
            }
        }
    }

    private var dyedSection: some View {
        Section {
            Stepper(value: $dyedDiscount, in: 0...40, step: 0.1) {
                HStack {
                    Text("Dyed diesel discount")
                    Spacer()
                    Text("\(dyedDiscount.formatted(.number.precision(.fractionLength(1))))¢/L")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if dyedDiscount != FuelPriceStore.defaultDyedDiscount {
                Button("Reset to 10.2¢/L") { dyedDiscount = FuelPriceStore.defaultDyedDiscount }
            }
        } footer: {
            Text("How much less than clear diesel the dyed diesel estimate is. 10.2¢/L is Ontario's 9.0¢/L diesel fuel tax plus HST on it.")
        }
    }

    @ViewBuilder
    private var furnaceOilSection: some View {
        let weekly = prices.currentFurnaceOil
        let monthly = prices.snapshot?.heatingMonthly ?? []
        if !weekly.isEmpty || !monthly.isEmpty {
            Section {
                ForEach(weekly) { reading in
                    cityRow(reading.city, cents: reading.centsPerLitre, date: reading.date.formatted(.dateTime.month(.abbreviated).day()))
                }
                ForEach(monthly) { reading in
                    cityRow(reading.city, cents: reading.centsPerLitre, date: reading.date.formatted(.dateTime.month(.abbreviated).year()))
                }
            } header: {
                Text("Furnace oil by city")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !weekly.isEmpty {
                        Text("Weekly prices from Natural Resources Canada.")
                    }
                    if !monthly.isEmpty {
                        Text("Monthly prices (with month) from Statistics Canada for \(monthly.map(\.city).joined(separator: ", ")).")
                    }
                    if let problem = prices.snapshot?.furnaceProblem {
                        Text("Not loaded: \(problem)")
                    }
                }
            }
        }
    }

    private func cityRow(_ city: String, cents: Double, date: String) -> some View {
        HStack {
            Text(city)
            Spacer()
            Text("\(cents.formatted(.number.precision(.fractionLength(1))))¢")
                .monospacedDigit()
            Text(date)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
    }

    private var sourcesSection: some View {
        Section("Sources") {
            Link(destination: FuelPriceSources.ontarioPage) {
                Label("Ontario motor fuel prices (gasoline, diesel, auto propane)", systemImage: "link")
            }
            Link(destination: FuelPriceSources.nrcanPage) {
                Label("Natural Resources Canada retail prices (furnace oil, weekly)", systemImage: "link")
            }
            Link(destination: FuelPriceSources.statCanPage) {
                Label("Statistics Canada heating fuel prices (monthly)", systemImage: "link")
            }
            Link(destination: FuelPriceSources.oebRates) {
                Label("Ontario Energy Board natural gas rates", systemImage: "link")
            }
        }
        .font(.callout)
    }
}

private struct PriceRowView: View {
    let row: FuelPriceRow

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.name)
                                .font(.headline)
                            if row.isEstimate {
                                Text("ESTIMATE")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.2), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let cents = row.cents {
                            Text("\(cents.formatted(.number.precision(.fractionLength(row.per == "L" ? 1 : 2))))¢")
                                .font(.title2.weight(.bold))
                                .monospacedDigit()
                            Text("$\((cents / 100).formatted(.number.precision(.fractionLength(row.per == "L" ? 3 : 4))))/\(row.per)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text("—")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 6) {
                    if let change = row.change, abs(change) >= 0.05 {
                        Label(
                            "\(change > 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(1))))¢ vs last week",
                            systemImage: change > 0 ? "arrow.up.right" : "arrow.down.right"
                        )
                        .foregroundStyle(change > 0 ? Color.red : Color.green)
                    } else if row.change != nil {
                        Text("No change from last week")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !row.date.isEmpty {
                        Text("\(row.source) · \(row.date)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                if let note = row.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
