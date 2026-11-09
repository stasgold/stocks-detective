import Foundation
import SwiftData
import XCTest
import DetectiveKit
@testable import StocksDetective

/// Demo data with chosen symbols failing, to exercise error paths.
struct FlakyProvider: MarketDataProvider {
    let inner = DemoMarketData()
    var failing: Set<String> = []
    /// Seconds to wait before answering, to test what happens while a refresh is running.
    var delay: Double = 0

    func priceSeries(for symbol: String) async throws -> (series: PriceSeries, name: String?) {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if failing.contains(symbol.uppercased()) { throw MarketDataError.noData(symbol) }
        return try await inner.priceSeries(for: symbol)
    }
    func news(for symbol: String) async throws -> [NewsArticle] { try await inner.news(for: symbol) }
    func marketNews() async throws -> [NewsArticle] { try await inner.marketNews() }
    func search(_ query: String) async throws -> [SymbolMatch] { try await inner.search(query) }
    func chart(for symbol: String, range: ChartRange) async throws -> ChartData { try await inner.chart(for: symbol, range: range) }
}

@MainActor
func makeContainer() throws -> ModelContainer {
    try ModelContainer(for: Holding.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

@MainActor
func makeModel(failing: Set<String> = [], demo: Bool = true, delay: Double = 0) -> AppModel {
    UserDefaults.standard.set(demo, forKey: AppModel.demoKey)
    return AppModel(makeProvider: { _ in FlakyProvider(failing: failing, delay: delay) })
}

let demoInputs = ["AAPL", "NVDA", "MSFT", "TSLA", "JPM"].map { HoldingInput(symbol: $0, sector: .guess(for: $0), shares: 10, costBasis: 100) }

@MainActor
func demoCase(_ symbol: String) async throws -> CaseFile {
    try await CaseBuilder(provider: DemoMarketData()).buildCase(for: HoldingInput(symbol: symbol, sector: .guess(for: symbol), shares: 1))
}
