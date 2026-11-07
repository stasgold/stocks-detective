import Foundation

/// Offline, deterministic data so the app (and SwiftUI previews) work with no network.
/// Each symbol gets a scripted "story" so every verdict type shows up.
public struct DemoMarketData: MarketDataProvider {
    public init() {}

    struct Story {
        let name: String
        let todayMove: Double
        let volatility: Double
        let volumeSpike: Double
        let headlines: [String]
    }

    static let stories: [String: Story] = [
        "AAPL": Story(name: "Apple Inc.", todayMove: -3.4, volatility: 1.4, volumeSpike: 2.6, headlines: [
            "Apple shares fall after report says iPhone demand in China slows",
            "Analyst cuts Apple price target on weaker services growth outlook",
            "Apple to unveil new Apple Intelligence features next month"]),
        "NVDA": Story(name: "NVIDIA Corporation", todayMove: 12.6, volatility: 2.6, volumeSpike: 1.1, headlines: [
            "Nvidia jumps as hyperscalers raise AI capex guidance",
            "Nvidia supplier TSMC reports record quarterly revenue"]),
        "MSFT": Story(name: "Microsoft Corporation", todayMove: -1.4, volatility: 1.3, volumeSpike: 1.0, headlines: [
            "Microsoft expands Azure AI partnership with OpenAI"]),
        "TSLA": Story(name: "Tesla, Inc.", todayMove: -6.8, volatility: 2.4, volumeSpike: 1.9, headlines: []),
        "JPM": Story(name: "JPMorgan Chase & Co.", todayMove: 3.9, volatility: 1.2, volumeSpike: 1.7, headlines: [
            "JPMorgan beats earnings estimates as trading revenue surges",
            "Banks rally as Treasury yields climb"]),
    ]

    static func story(_ s: String) -> Story {
        stories[s.uppercased()] ?? Story(name: s.uppercased(), todayMove: 0.4, volatility: 1.5, volumeSpike: 1.0, headlines: [])
    }

    /// Small deterministic PRNG so demo charts look the same every launch.
    struct SeededRandom {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func normal() -> Double {
            let u1 = max(next(), 1e-9), u2 = next()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    static func benchmarkToday(_ s: String) -> Double? {
        switch s {
        case "SPY": -0.6
        case "XLK": -0.9
        case "XLF": 0.9
        case "XLY": -0.7
        default: nil
        }
    }

    public func priceSeries(for symbol: String) async throws -> (series: PriceSeries, name: String?) {
        let s = symbol.uppercased()
        let story = Self.story(s)
        let today = Self.benchmarkToday(s) ?? story.todayMove
        let vol = Self.benchmarkToday(s) != nil ? 0.9 : story.volatility
        // One shared market path for every symbol, plus per-symbol noise, so betas look real.
        var marketRng = SeededRandom(state: 42)
        let marketPath = (0..<125).map { _ in marketRng.normal() }
        var rng = SeededRandom(state: UInt64(abs(s.hashValue_stable)) | 1)
        let isBenchmark = Self.benchmarkToday(s) != nil
        var price = 100.0 + Double(abs(s.hashValue_stable) % 300)
        var points: [PricePoint] = []
        let cal = Calendar(identifier: .gregorian)
        let start = cal.date(byAdding: .day, value: -125, to: Date())!
        for i in 0..<124 {
            // Blend a shared "market" path with idiosyncratic noise so beta is meaningful.
            let r = (isBenchmark ? marketPath[i] : 0.75 * marketPath[i] + 0.65 * rng.normal()) * vol / 100
            price *= 1 + r + 0.0004
            points.append(PricePoint(date: cal.date(byAdding: .day, value: i, to: start)!, close: price, volume: 1_000_000 * (0.8 + rng.next() * 0.4)))
        }
        let prev = price
        let last = prev * (1 + today / 100)
        points.append(PricePoint(date: Date(), close: last, volume: 1_000_000 * story.volumeSpike))
        return (PriceSeries(symbol: s, points: points, lastPrice: last, previousClose: prev), story.name)
    }

    public func news(for symbol: String) async throws -> [NewsArticle] {
        Self.story(symbol).headlines.enumerated().map { i, t in
            NewsArticle(title: t, summary: "", source: "Demo Wire", link: "", published: Date().addingTimeInterval(Double(-(i + 1) * 3 * 3600)))
        }
    }

    public func marketNews() async throws -> [NewsArticle] {
        [NewsArticle(title: "Stocks slip as investors weigh hotter-than-expected inflation data", source: "Demo Wire", published: Date().addingTimeInterval(-7200)),
         NewsArticle(title: "Tech sector leads declines; financials gain on higher yields", source: "Demo Wire", published: Date().addingTimeInterval(-10800))]
    }

    public func search(_ query: String) async throws -> [SymbolMatch] {
        let q = query.uppercased()
        return Self.stories.filter { $0.key.hasPrefix(q) || $0.value.name.uppercased().contains(q) }
            .map { SymbolMatch(symbol: $0.key, name: $0.value.name, exchange: "DEMO") }
            .sorted { $0.symbol < $1.symbol }
    }
}

extension String {
    /// Stable across launches (Swift's hashValue is randomly seeded).
    var hashValue_stable: Int {
        var h: UInt64 = 5381
        for b in utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(truncatingIfNeeded: h & 0x7fff_ffff)
    }
}
