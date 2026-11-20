import SwiftUI
import SwiftData
import DetectiveKit

/// Change a holding's share count, average cost or comparison sector, or delete it.
struct EditHoldingView: View {
    let holding: Holding
    /// Called after the holding is deleted (e.g. to leave its case page).
    var onDelete: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var shares: String
    @State private var cost: String
    @State private var sector: Sector
    @State private var confirmDelete = false

    init(holding: Holding, onDelete: @escaping () -> Void = {}) {
        self.holding = holding
        self.onDelete = onDelete
        _shares = State(initialValue: holding.shares.formatted(.number.grouping(.never)))
        _cost = State(initialValue: holding.costBasis.map { $0.formatted(.number.grouping(.never)) } ?? "")
        _sector = State(initialValue: holding.sector)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Stock") {
                    LabeledContent(holding.symbol, value: holding.name)
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
                }
                Section {
                    Button("Delete holding", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle("Edit holding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(HoldingsEditor.parseAmount(shares) == nil)
                }
            }
            .confirmationDialog(Text("Delete \(holding.symbol)?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    HoldingsEditor.delete([holding], in: context, model: model)
                    dismiss()
                    onDelete()
                }
            }
        }
    }

    private func save() {
        guard let n = HoldingsEditor.parseAmount(shares) else { return }
        let sectorChanged = HoldingsEditor.update(holding, shares: n, costBasis: HoldingsEditor.parseAmount(cost),
                                                  sector: sector, in: context, model: model)
        if sectorChanged {
            // New benchmark: re-investigate this holding.
            let input = holding.input
            Task { await model.refresh([input]) }
        }
        dismiss()
    }
}
