import SwiftUI
import SwiftData
import DetectiveKit

struct AddHoldingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var existing: [Holding]

    @State private var query = ""
    @State private var results: [SymbolMatch] = []
    @State private var selected: SymbolMatch?
    @State private var shares = ""
    @State private var cost = ""
    @State private var sector: Sector = .broadMarket

    var body: some View {
        NavigationStack {
            Form {
                if let selected {
                    Section("Stock") {
                        LabeledContent(selected.symbol, value: selected.name)
                        Button("Change") { self.selected = nil }
                    }
                    Section("Position") {
                        TextField("Shares", text: $shares).keyboardType(.decimalPad)
                        TextField("Average cost per share (optional)", text: $cost).keyboardType(.decimalPad)
                    }
                    Section {
                        Picker("Compare against", selection: $sector) {
                            ForEach(Sector.allCases) { s in
                                Text("\(s.displayName) (\(s.etf))").tag(s)
                            }
                        }
                    } footer: {
                        Text("The detective compares each move with this sector ETF to tell market moves apart from company news.")
                    }
                } else {
                    Section {
                        TextField("Search ticker or company", text: $query)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                    Section {
                        ForEach(results) { r in
                            Button {
                                select(r)
                            } label: {
                                HStack {
                                    Text(r.symbol).font(.headline)
                                    Text(r.name).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Text(r.exchange).font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .tint(.primary)
                        }
                        if !query.isEmpty {
                            Button("Use “\(query.uppercased())”") {
                                select(SymbolMatch(symbol: query.uppercased(), name: query.uppercased()))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add holding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(selected == nil || parsed(shares) == nil)
                }
            }
            .task(id: query) {
                guard query.count >= 1 else { results = []; return }
                try? await Task.sleep(for: .milliseconds(300)) // debounce typing
                guard !Task.isCancelled else { return }
                results = (try? await model.provider.search(query)) ?? []
            }
        }
    }

    private func select(_ match: SymbolMatch) {
        selected = match
        sector = .guess(for: match.symbol)
    }

    private func parsed(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 0 ? $0 : nil }
    }

    private func save() {
        guard let selected, let n = parsed(shares) else { return }
        if let h = existing.first(where: { $0.symbol == selected.symbol.uppercased() }) {
            h.shares = n
            h.costBasis = parsed(cost)
            h.sector = sector
        } else {
            context.insert(Holding(symbol: selected.symbol, name: selected.name, shares: n, costBasis: parsed(cost), sector: sector))
        }
        dismiss()
    }
}
