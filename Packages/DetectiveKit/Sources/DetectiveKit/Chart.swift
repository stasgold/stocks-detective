import Foundation

/// Time ranges offered on the price chart, matching Yahoo Finance.
public enum ChartRange: String, CaseIterable, Codable, Sendable, Identifiable {
    case day = "1D", fiveDays = "5D", month = "1M", sixMonths = "6M", ytd = "YTD", year = "1Y", fiveYears = "5Y", all = "All"

    public var id: String { rawValue }

    var yahooRange: String {
        switch self {
        case .day: "1d"
        case .fiveDays: "5d"
        case .month: "1mo"
        case .sixMonths: "6mo"
        case .ytd: "ytd"
        case .year: "1y"
        case .fiveYears: "5y"
        case .all: "max"
        }
    }

    var yahooInterval: String {
        switch self {
        case .day: "5m"
        case .fiveDays: "15m"
        case .month, .sixMonths, .ytd, .year: "1d"
        case .fiveYears: "1wk"
        case .all: "1mo"
        }
    }

    /// Bars are minutes apart (show times, not just dates).
    public var isIntraday: Bool { self == .day || self == .fiveDays }

    /// "past month" etc., for the change badge.
    public var periodLabel: String {
        switch self {
        case .day: "today"
        case .fiveDays: "past 5 days"
        case .month: "past month"
        case .sixMonths: "past 6 months"
        case .ytd: "year to date"
        case .year: "past year"
        case .fiveYears: "past 5 years"
        case .all: "all time"
        }
    }
}

public struct ChartBar: Codable, Hashable, Sendable {
    public let date: Date
    public let open: Double?
    public let high: Double?
    public let low: Double?
    public let close: Double
    public let volume: Double

    public init(date: Date, open: Double?, high: Double?, low: Double?, close: Double, volume: Double) {
        self.date = date
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }
}

public struct ChartData: Codable, Hashable, Sendable {
    public let symbol: String
    public let range: ChartRange
    public let currency: String
    public let bars: [ChartBar]
    /// Previous session's close (drawn as a dashed line on 1D).
    public let previousClose: Double?

    public init(symbol: String, range: ChartRange, currency: String, bars: [ChartBar], previousClose: Double?) {
        self.symbol = symbol
        self.range = range
        self.currency = currency
        self.bars = bars
        self.previousClose = previousClose
    }

    /// Price the period change is measured from: previous close for 1D, first bar otherwise.
    public var baseline: Double? {
        if range == .day, let previousClose { return previousClose }
        return bars.first?.close
    }

    public var change: Double? {
        guard let base = baseline, base > 0, let last = bars.last?.close else { return nil }
        return last - base
    }

    public var changePercent: Double? {
        guard let base = baseline, base > 0, let change else { return nil }
        return change / base * 100
    }

    public var priceDomain: ClosedRange<Double> {
        var lo = bars.map { $0.low ?? $0.close }.min() ?? 0
        var hi = bars.map { $0.high ?? $0.close }.max() ?? 1
        if range == .day, let p = previousClose { lo = min(lo, p); hi = max(hi, p) }
        if hi <= lo { hi = lo + 1 }
        let pad = (hi - lo) * 0.06
        return (lo - pad)...(hi + pad)
    }
}

extension YahooChartParser {
    struct ChartRoot: Decodable { let chart: ChartBody }
    struct ChartBody: Decodable { let result: [ChartResult]? }
    struct ChartResult: Decodable {
        let meta: ChartMeta
        let timestamp: [TimeInterval]?
        let indicators: ChartIndicators
    }
    struct ChartMeta: Decodable {
        let currency: String?
        let symbol: String
        let chartPreviousClose: Double?
        let previousClose: Double?
    }
    struct ChartIndicators: Decodable { let quote: [OHLCV] }
    struct OHLCV: Decodable {
        let open: [Double?]?
        let high: [Double?]?
        let low: [Double?]?
        let close: [Double?]?
        let volume: [Double?]?
    }

    static func parseChart(_ data: Data, symbol: String, range: ChartRange) throws -> ChartData {
        let root = try JSONDecoder().decode(ChartRoot.self, from: data)
        guard let r = root.chart.result?.first, let ts = r.timestamp, let q = r.indicators.quote.first,
              let closes = q.close else { throw MarketDataError.noData(symbol) }
        func at(_ a: [Double?]?, _ i: Int) -> Double? {
            guard let a, i < a.count else { return nil }
            return a[i]
        }
        var bars: [ChartBar] = []
        for (i, t) in ts.enumerated() where i < closes.count {
            guard let c = closes[i] else { continue }
            bars.append(ChartBar(date: Date(timeIntervalSince1970: t), open: at(q.open, i), high: at(q.high, i),
                                 low: at(q.low, i), close: c, volume: at(q.volume, i) ?? 0))
        }
        guard !bars.isEmpty else { throw MarketDataError.noData(symbol) }
        let prev = range == .day ? (r.meta.previousClose ?? r.meta.chartPreviousClose) : r.meta.chartPreviousClose
        return ChartData(symbol: r.meta.symbol, range: range, currency: r.meta.currency ?? "USD", bars: bars, previousClose: prev)
    }
}

extension YahooMarketData {
    public func chart(for symbol: String, range: ChartRange) async throws -> ChartData {
        let s = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(s)?range=\(range.yahooRange)&interval=\(range.yahooInterval)&includePrePost=false") else {
            throw MarketDataError.noData(symbol)
        }
        return try YahooChartParser.parseChart(try await get(url), symbol: symbol, range: range)
    }
}

extension DemoMarketData {
    public func chart(for symbol: String, range: ChartRange) async throws -> ChartData {
        let daily = try await priceSeries(for: symbol).series
        let cal = Calendar(identifier: .gregorian)
        var rng = SeededRandom(state: UInt64(abs((symbol + range.rawValue).hashValue_stable)) | 1)

        // Random walk that ends exactly at `end`.
        func walk(count: Int, end: Double, vol: Double, step: TimeInterval, until: Date) -> [ChartBar] {
            var prices = [end]
            for _ in 1..<count { prices.append(prices.last! / (1 + rng.normal() * vol)) }
            prices.reverse()
            return prices.enumerated().map { i, p in
                let wiggle = abs(rng.normal()) * vol * p * 0.5
                return ChartBar(date: until.addingTimeInterval(-Double(count - 1 - i) * step), open: p * (1 + rng.normal() * vol * 0.3),
                                high: p + wiggle, low: p - wiggle, close: p, volume: 1_000_000 * (0.5 + rng.next()))
            }
        }
        func fromDaily(_ n: Int) -> [ChartBar] {
            daily.points.suffix(n).map { ChartBar(date: $0.date, open: nil, high: nil, low: nil, close: $0.close, volume: $0.volume) }
        }

        let bars: [ChartBar]
        switch range {
        case .day:
            bars = walk(count: 78, end: daily.lastPrice, vol: 0.0015, step: 300, until: Date())
            // Anchor the open near yesterday's close so the day's move matches the case.
        case .fiveDays:
            bars = walk(count: 130, end: daily.lastPrice, vol: 0.003, step: 900, until: Date())
        case .month: bars = fromDaily(22)
        case .sixMonths: bars = fromDaily(126)
        case .ytd:
            let start = cal.date(from: cal.dateComponents([.year], from: Date()))!
            let since = daily.points.filter { $0.date >= start }.count
            bars = fromDaily(max(since, 2))
        case .year:
            let older = walk(count: 128, end: daily.points.first?.close ?? daily.lastPrice, vol: 0.015, step: 86400, until: daily.points.first?.date ?? Date())
            bars = Array(older.dropLast()) + fromDaily(125)
        case .fiveYears:
            bars = walk(count: 260, end: daily.lastPrice, vol: 0.035, step: 7 * 86400, until: Date())
        case .all:
            bars = walk(count: 240, end: daily.lastPrice, vol: 0.07, step: 30 * 86400, until: Date())
        }
        return ChartData(symbol: symbol.uppercased(), range: range, currency: "USD", bars: bars,
                         previousClose: range == .day ? daily.previousClose : nil)
    }
}
