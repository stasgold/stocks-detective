import Foundation

/// Trailing-twelve-month earnings for one stock (none for ETFs/funds).
public struct Earnings: Codable, Hashable, Sendable {
    /// Diluted EPS over the last 12 months.
    public let ttmEPS: Double
    /// The same figure one year earlier, for growth.
    public let priorEPS: Double?
    public let asOf: Date?
    public let currency: String

    public init(ttmEPS: Double, priorEPS: Double?, asOf: Date? = nil, currency: String = "USD") {
        self.ttmEPS = ttmEPS
        self.priorEPS = priorEPS
        self.asOf = asOf
        self.currency = currency
    }

    /// Traffic-light rating shown in the portfolio list.
    public enum Rating: String, Codable, Sendable { case good, fair, poor }

    /// Year-over-year EPS change in %, when a year-ago figure exists and is non-zero.
    public var growth: Double? {
        guard let priorEPS, priorEPS != 0 else { return nil }
        return (ttmEPS - priorEPS) / abs(priorEPS) * 100
    }

    /// Green: profitable and growing. Yellow: profitable, flat/down or unknown growth. Red: a loss.
    public var epsRating: Rating {
        if ttmEPS <= 0 { return .poor }
        if let g = growth, g > 0 { return .good }
        return .fair
    }

    /// Earnings yield (E/P) in %: the inverse of P/E.
    public func earningsYield(price: Double) -> Double? {
        price > 0 ? ttmEPS / price * 100 : nil
    }

    /// Green ≥ 5% (P/E ≤ 20), yellow 2.5–5% (P/E 20–40), red below 2.5% or a loss.
    public static func yieldRating(_ ep: Double) -> Rating {
        ep >= 5 ? .good : ep >= 2.5 ? .fair : .poor
    }

    /// One line for the AI brief.
    public func promptLine(price: Double) -> String {
        var parts = ["TTM EPS \(String(format: "%.2f", ttmEPS)) \(currency)"]
        if let g = growth { parts.append("\(fmt(g))% vs a year ago") }
        if let ep = earningsYield(price: price) {
            parts.append("earnings yield \(String(format: "%.1f", ep))%" + (ttmEPS > 0 ? " (P/E \(String(format: "%.0f", 100 / ep)))" : " (loss-making)"))
        }
        return "VALUATION: " + parts.joined(separator: ", ")
    }
}

/// Parses Yahoo's fundamentals-timeseries reply (trailing / annual diluted EPS).
enum YahooFundamentalsParser {
    static func parse(_ data: Data) -> Earnings? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = (root["timeseries"] as? [String: Any])?["result"] as? [[String: Any]] else { return nil }

        func series(_ key: String) -> [(date: Date, value: Double, currency: String)] {
            let rows = results.compactMap { $0[key] as? [Any] }.first ?? []
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            return rows.compactMap { row in
                guard let r = row as? [String: Any], let date = (r["asOfDate"] as? String).flatMap(f.date(from:)),
                      let value = (r["reportedValue"] as? [String: Any])?["raw"] as? Double else { return nil }
                return (date, value, r["currencyCode"] as? String ?? "USD")
            }.sorted { $0.date < $1.date }
        }

        // Prefer the rolling 12-month figure; fall back to the last fiscal year.
        for key in ["trailingDilutedEPS", "annualDilutedEPS"] {
            let s = series(key)
            guard let latest = s.last else { continue }
            let yearAgo = latest.date.addingTimeInterval(-300 * 86400)
            let prior = s.last { $0.date <= yearAgo }
            return Earnings(ttmEPS: latest.value, priorEPS: prior?.value, asOf: latest.date, currency: latest.currency)
        }
        return nil
    }
}

extension YahooMarketData {
    public func earnings(for symbol: String) async throws -> Earnings? {
        let s = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        let now = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "https://query1.finance.yahoo.com/ws/fundamentals-timeseries/v1/finance/timeseries/\(s)?type=trailingDilutedEPS,annualDilutedEPS&period1=\(now - 3 * 365 * 86400)&period2=\(now)") else { return nil }
        return YahooFundamentalsParser.parse(try await get(url))
    }
}

extension DemoMarketData {
    public func earnings(for symbol: String) async throws -> Earnings? {
        switch symbol.uppercased() {
        case "AAPL": Earnings(ttmEPS: 7.21, priorEPS: 6.42)    // E/P ≈ 2.8% → yellow, growing → green
        case "NVDA": Earnings(ttmEPS: 4.35, priorEPS: 2.53)
        case "MSFT": Earnings(ttmEPS: 13.10, priorEPS: 11.80)
        case "TSLA": Earnings(ttmEPS: 1.62, priorEPS: 3.10)    // shrinking → yellow
        case "JPM": Earnings(ttmEPS: 19.80, priorEPS: 17.20)   // cheap → green
        default: nil                                           // ETFs / unknown
        }
    }
}

extension MarketDataProvider {
    /// Providers without fundamentals report no earnings.
    public func earnings(for symbol: String) async throws -> Earnings? { nil }
}
