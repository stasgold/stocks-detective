import Foundation
import SwiftData
import DetectiveKit

/// Portfolio edits used by the screens, kept out of the views so they can be unit tested.
@MainActor
enum HoldingsEditor {
    /// "12.5" or "12,5" → 12.5; empty, zero or negative → nil.
    static func parseAmount(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Adds a holding, or updates it if the ticker is already in the portfolio.
    @discardableResult
    static func upsert(symbol: String, name: String, shares: Double, costBasis: Double?, sector: Sector,
                       existing: [Holding], in context: ModelContext) -> Holding {
        let key = symbol.uppercased()
        if let h = existing.first(where: { $0.symbol == key }) {
            h.shares = shares
            h.costBasis = costBasis
            h.sector = sector
            return h
        }
        let h = Holding(symbol: key, name: name, shares: shares, costBasis: costBasis, sector: sector)
        context.insert(h)
        return h
    }

    /// Applies pasted import rows. With `replace`, holdings not in the paste are removed.
    static func importRows(_ rows: [PortfolioImporter.Row], replace: Bool, existing: [Holding],
                           in context: ModelContext, model: AppModel) {
        let keep = Set(rows.map(\.symbol))
        // Read everything we need before deleting anything: touching a deleted SwiftData object crashes.
        let bySymbol = Dictionary(existing.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
        for row in rows {
            if let h = bySymbol[row.symbol] {
                h.shares = row.shares
            } else {
                // Name is filled in from market data on the first refresh.
                context.insert(Holding(symbol: row.symbol, name: row.symbol, shares: row.shares, costBasis: nil, sector: .guess(for: row.symbol)))
            }
        }
        if replace {
            for (symbol, h) in bySymbol where !keep.contains(symbol) {
                model.remove(symbol)
                context.delete(h)
            }
        }
        try? context.save()
        if model.demoMode { model.demoMode = false } // real holdings need live data
    }

    /// Loads the demo portfolio into an empty store and switches to demo data.
    static func seedDemo(in context: ModelContext, model: AppModel) {
        let count = (try? context.fetchCount(FetchDescriptor<Holding>())) ?? 0
        guard count == 0 else { return }
        model.demoMode = true
        for (s, n, sh, cb) in DemoPortfolio.holdings {
            context.insert(Holding(symbol: s, name: n, shares: sh, costBasis: cb, sector: .guess(for: s)))
        }
        try? context.save()
    }

    /// Imported holdings start with just a ticker; use the company name once we have it.
    static func fillInNames(_ holdings: [Holding], cases: [String: CaseFile]) {
        for h in holdings where h.name == h.symbol {
            if let name = cases[h.symbol]?.companyName, !name.isEmpty { h.name = name }
        }
    }

    /// Most surprising moves first: that's where the story is.
    static func sortedBySurprise(_ holdings: [Holding], cases: [String: CaseFile]) -> [Holding] {
        holdings.sorted { a, b in
            abs(cases[a.symbol]?.facts.zScore ?? 0) > abs(cases[b.symbol]?.facts.zScore ?? 0)
        }
    }

    static func delete(_ holdings: [Holding], in context: ModelContext, model: AppModel) {
        for h in holdings {
            model.remove(h.symbol)
            context.delete(h)
        }
        try? context.save()
    }

    static func deleteAll(in context: ModelContext, model: AppModel) {
        delete((try? context.fetch(FetchDescriptor<Holding>())) ?? [], in: context, model: model)
        model.clearCaches()
    }
}
