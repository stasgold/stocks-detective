import SwiftUI
import SwiftData
import DetectiveKit

/// Paste a holdings table from a broker app, spreadsheet or notes and import it in one go.
struct ImportPortfolioView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var existing: [Holding]

    @State private var text = ProcessInfo.processInfo.environment["IMPORT_TEXT"] ?? ""
    @State private var replaceExisting = false
    @FocusState private var editorFocused: Bool

    private var result: PortfolioImporter.Result { PortfolioImporter.parse(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PasteButton(payloadType: String.self) { strings in
                        if let s = strings.first { text = s }
                    }
                    .buttonBorderShape(.capsule)
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 140)
                        .focused($editorFocused)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("SYM   QTY   PRICE\nVOO   238   675.99\nNVDA  210   186.64")
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("Paste your holdings")
                } footer: {
                    Text("Copy the positions table from your broker, a spreadsheet or notes. Each line needs a ticker followed by the number of shares; other columns are ignored.")
                }

                if !result.rows.isEmpty {
                    Section("\(result.rows.count) holdings found") {
                        ForEach(result.rows) { row in
                            HStack {
                                Text(row.symbol).font(.headline)
                                if existing.contains(where: { $0.symbol == row.symbol }) {
                                    Text("update").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: .capsule)
                                }
                                Spacer()
                                Text("\(row.shares.formatted()) shares").monospacedDigit()
                                if let p = row.price {
                                    Text("@ \(p.formatted(.number.precision(.fractionLength(2))))")
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                    Section {
                        Toggle("Replace my current portfolio", isOn: $replaceExisting)
                    } footer: {
                        Text(replaceExisting
                             ? "Holdings not in the pasted list will be removed."
                             : "Pasted holdings are added; tickers you already have get the new share count.")
                    }
                }

                if !result.skipped.isEmpty {
                    Section("Couldn't read these lines") {
                        ForEach(result.skipped, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                }
            }
            .onAppear { replaceExisting = model.demoMode } // swap out the sample stocks by default
            .navigationTitle("Import portfolio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importRows() }.disabled(result.rows.isEmpty)
                }
            }
        }
    }

    private func importRows() {
        let rows = result.rows
        let keep = Set(rows.map(\.symbol))
        // Read everything we need from existing holdings before deleting any of them:
        // touching a deleted SwiftData object crashes.
        let bySymbol = Dictionary(existing.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })

        for row in rows {
            if let h = bySymbol[row.symbol] {
                h.shares = row.shares
            } else {
                // Name is filled in from market data on the first refresh.
                context.insert(Holding(symbol: row.symbol, name: row.symbol, shares: row.shares, costBasis: nil, sector: .guess(for: row.symbol)))
            }
        }
        if replaceExisting {
            for (symbol, h) in bySymbol where !keep.contains(symbol) {
                model.remove(symbol)
                context.delete(h)
            }
        }
        try? context.save()
        if model.demoMode { model.demoMode = false } // real holdings need live data
        dismiss()
    }
}
