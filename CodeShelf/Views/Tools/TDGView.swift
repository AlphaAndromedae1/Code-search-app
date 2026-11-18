import SwiftUI

/// Dangerous goods identification for fuels: UN number, shipping name, class and ERG guide.
struct TDGView: View {
    @State private var query = ""

    var body: some View {
        List {
            Section {
                ForEach(filtered) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.un)
                                .font(.title3.weight(.bold).monospacedDigit())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.black)
                            Text(item.commonName)
                                .font(.headline)
                        }
                        Text(item.shippingName)
                            .font(.subheadline.weight(.semibold))
                        Text([item.classDescription, item.packingGroup.map { "Packing group \($0)" }, "ERG guide \(item.ergGuide)"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.placard)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.note)
                            .font(.caption)
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("Proper shipping names, UN numbers and classes as listed in Schedule 1 of the Transportation of Dangerous Goods Regulations. Guide numbers from the Emergency Response Guidebook (ERG 2024). Check the current regulations for packaging, documents, exemptions and placarding.")
            }

            Section("Emergencies") {
                Label("CANUTEC (24 h): 1-888-CANUTEC (226-8832)", systemImage: "phone")
                Label("CANUTEC: 613-996-6666, or *666 on a mobile phone", systemImage: "phone")
                Label("Fire, injury or immediate danger: call 911", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle("TDG – Fuels")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "UN number or fuel")
    }

    private var filtered: [DangerousGood] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return TDGReference.goods }
        let digits = text.filter(\.isNumber)
        return TDGReference.goods.filter { item in
            (!digits.isEmpty && item.un.contains(digits))
                || item.commonName.lowercased().contains(text)
                || item.shippingName.lowercased().contains(text)
        }
    }
}
