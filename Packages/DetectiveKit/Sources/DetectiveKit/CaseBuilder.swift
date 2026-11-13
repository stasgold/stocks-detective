import Foundation

public struct HoldingInput: Sendable, Hashable {
    public let symbol: String
    public let sector: Sector
    public let shares: Double
    public let costBasis: Double?

    public init(symbol: String, sector: Sector, shares: Double, costBasis: Double? = nil) {
        self.symbol = symbol
        self.sector = sector
        self.shares = shares
        self.costBasis = costBasis
    }
}

/// Gathers evidence for every holding: prices, benchmark, market and company news.
/// Caches benchmark series and market news so a 20-stock portfolio doesn't fetch SPY 20 times.
public actor CaseBuilder {
    let provider: MarketDataProvider
    private var seriesCache: [String: (PriceSeries, String?, Date)] = [:]
    private var marketNewsCache: ([ScoredArticle], Date)?
    private let ttl: TimeInterval = 5 * 60

    public init(provider: MarketDataProvider) {
        self.provider = provider
    }

    func series(_ symbol: String) async throws -> (PriceSeries, String?) {
        if let c = seriesCache[symbol], Date().timeIntervalSince(c.2) < ttl { return (c.0, c.1) }
        let r = try await provider.priceSeries(for: symbol)
        seriesCache[symbol] = (r.series, r.name, Date())
        return (r.series, r.name)
    }

    func marketNews() async -> [ScoredArticle] {
        if let c = marketNewsCache, Date().timeIntervalSince(c.1) < ttl { return c.0 }
        let raw = (try? await provider.marketNews()) ?? []
        let ranked = NewsScorer.rank(raw, symbol: "market", companyName: nil, limit: 6)
        marketNewsCache = (ranked, Date())
        return ranked
    }

    /// Fetches headlines off the actor so XML parsing doesn't block other cases.
    nonisolated func companyNews(_ symbol: String) async -> [NewsArticle] {
        (try? await provider.news(for: symbol)) ?? []
    }

    public func buildCase(for holding: HoldingInput) async throws -> CaseFile {
        let symbol = holding.symbol.uppercased()
        // The stock itself is the only request that may fail. Fetch it first, before anything
        // else is started, so an error never leaves other requests running in the background.
        // (Build 4 crashed when a failed price request exited while news was still loading.)
        let (stock, name) = try await series(symbol)

        // Everything else is optional and can't throw. Holdings are already investigated in
        // parallel by the caller, so plain sequential awaits here are fast enough, and the
        // benchmark/market series are usually served from cache.
        let bench = (try? await series(holding.sector.etf))?.0 ?? stock
        let market = (try? await series("SPY"))?.0 ?? bench
        let rawNews = await companyNews(symbol)
        let marketNews = await marketNews()
        let intraday = try? await provider.chart(for: symbol, range: .day)

        let facts = MovementAnalyzer.analyze(stock: stock, benchmark: bench, market: market)
        let news = NewsScorer.rank(rawNews, symbol: symbol, companyName: name, limit: 10)
        return CaseFile(symbol: symbol, companyName: name, sector: holding.sector, facts: facts,
                        news: news, marketNews: marketNews, series: stock, intraday: intraday)
    }
}

/// Portfolio-level numbers for the briefing screen.
public struct PortfolioSnapshot: Sendable {
    public struct Line: Sendable, Identifiable {
        public var id: String { symbol }
        public let symbol: String
        public let value: Double
        public let dayPnL: Double
        public let dayChange: Double
        public let totalReturn: Double?
        public let character: MoveCharacter
        public let zScore: Double
    }

    public let lines: [Line]

    public init(cases: [CaseFile], holdings: [HoldingInput]) {
        let bySymbol = Dictionary(holdings.map { ($0.symbol.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        lines = cases.compactMap { c in
            guard let h = bySymbol[c.symbol] else { return nil }
            let value = h.shares * c.series.lastPrice
            let pnl = h.shares * (c.series.lastPrice - c.series.previousClose)
            let tr = h.costBasis.flatMap { $0 > 0 ? (c.series.lastPrice / $0 - 1) * 100 : nil }
            return Line(symbol: c.symbol, value: value, dayPnL: pnl, dayChange: c.facts.dayChange,
                        totalReturn: tr, character: c.facts.character, zScore: c.facts.zScore)
        }
    }

    public var totalValue: Double { lines.map(\.value).reduce(0, +) }
    public var dayPnL: Double { lines.map(\.dayPnL).reduce(0, +) }
    public var dayChangePercent: Double {
        let prev = totalValue - dayPnL
        return prev > 0 ? dayPnL / prev * 100 : 0
    }
    /// Holdings that drove most of today's P&L, biggest absolute impact first.
    public var topContributors: [Line] { lines.sorted { abs($0.dayPnL) > abs($1.dayPnL) } }
    /// Moves worth opening a case on.
    public var suspects: [Line] { lines.filter { abs($0.zScore) >= 1.5 && $0.character != .marketDriven } }

    public func promptBrief(cases: [CaseFile], holdings: Int = 6) -> String {
        var out = ["PORTFOLIO today: \(fmt(dayChangePercent))% (\(fmt(dayPnL, 0)) USD), value \(Int(totalValue)) USD"]
        let caseBySymbol = Dictionary(cases.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
        for l in topContributors.prefix(holdings) {
            let headline = caseBySymbol[l.symbol]?.news.first?.article.title ?? "no headline"
            let weight = totalValue > 0 ? l.value / totalValue * 100 : 0
            out.append("- \(l.symbol): \(fmt(l.dayChange))%, P&L \(fmt(l.dayPnL, 0)), weight \(Int(weight))%, \(l.character.englishLabel); top news: \(headline)")
        }
        if let m = cases.first?.facts { out.append("S&P 500 today: \(fmt(m.marketDayChange))%") }
        return out.joined(separator: "\n")
    }
}
