import Foundation

/// What kind of move this is, based on statistics alone (before reading any news).
public enum MoveCharacter: String, Codable, Sendable {
    /// Inside the stock's normal daily range. Probably nothing to investigate.
    case noise
    /// Mostly explained by the sector / market moving the same way.
    case marketDriven
    /// The stock moved on its own: something company-specific happened.
    case stockSpecific
    /// A mix: the market moved, but the stock moved much more (or less).
    case amplified

    public var label: String { L(englishLabel) }

    /// English label, used in prompts for the language model.
    public var englishLabel: String {
        switch self {
        case .noise: "Normal noise"
        case .marketDriven: "Market-driven"
        case .stockSpecific: "Stock-specific"
        case .amplified: "Amplified market move"
        }
    }
}

/// Hard numbers about a move. Everything the detective later explains is grounded in this.
public struct MovementFacts: Codable, Hashable, Sendable {
    public let symbol: String
    public let benchmark: String
    public let dayChange: Double          // %
    public let weekChange: Double         // % over ~5 sessions
    public let monthChange: Double        // % over ~21 sessions
    public let benchmarkDayChange: Double // %
    public let marketDayChange: Double    // % (SPY)
    public let beta: Double               // vs benchmark, 60 sessions
    public let expectedMove: Double       // beta * benchmark move, %
    public let excessMove: Double         // dayChange - expectedMove, %
    public let typicalDailyMove: Double   // stdev of daily returns, %
    public let zScore: Double             // dayChange / typicalDailyMove
    public let volumeRatio: Double        // latest volume / 20-day average
    public let distanceFrom52wHigh: Double // % below the high in the data window (<= 0)
    public let character: MoveCharacter

    public init(symbol: String, benchmark: String, dayChange: Double, weekChange: Double, monthChange: Double,
                benchmarkDayChange: Double, marketDayChange: Double, beta: Double, expectedMove: Double,
                excessMove: Double, typicalDailyMove: Double, zScore: Double, volumeRatio: Double,
                distanceFrom52wHigh: Double, character: MoveCharacter) {
        self.symbol = symbol
        self.benchmark = benchmark
        self.dayChange = dayChange
        self.weekChange = weekChange
        self.monthChange = monthChange
        self.benchmarkDayChange = benchmarkDayChange
        self.marketDayChange = marketDayChange
        self.beta = beta
        self.expectedMove = expectedMove
        self.excessMove = excessMove
        self.typicalDailyMove = typicalDailyMove
        self.zScore = zScore
        self.volumeRatio = volumeRatio
        self.distanceFrom52wHigh = distanceFrom52wHigh
        self.character = character
    }

    /// Share of the move explained by the benchmark, 0...1.
    public var explainedByMarket: Double {
        guard abs(dayChange) > 0.0001 else { return 1 }
        let share = expectedMove / dayChange
        return min(max(share, 0), 1)
    }

    public var isSignificant: Bool { abs(zScore) >= 1.5 || abs(dayChange) >= 3 }
}

public enum MovementAnalyzer {
    /// Daily simple returns in percent.
    public static func returns(_ closes: [Double]) -> [Double] {
        guard closes.count > 1 else { return [] }
        var out: [Double] = []
        out.reserveCapacity(closes.count - 1)
        for i in 1..<closes.count where closes[i - 1] > 0 {
            let ratio: Double = closes[i] / closes[i - 1]
            out.append((ratio - 1) * 100)
        }
        return out
    }

    public static func mean(_ xs: [Double]) -> Double {
        xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }

    public static func stdev(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = mean(xs)
        let v = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
        return v.squareRoot()
    }

    /// OLS slope of stock returns against benchmark returns.
    public static func beta(stock: [Double], benchmark: [Double]) -> Double {
        let n = min(stock.count, benchmark.count)
        guard n > 5 else { return 1 }
        let s = Array(stock.suffix(n)), b = Array(benchmark.suffix(n))
        let ms = mean(s), mb = mean(b)
        var cov = 0.0, varB = 0.0
        for i in 0..<n {
            cov += (s[i] - ms) * (b[i] - mb)
            varB += (b[i] - mb) * (b[i] - mb)
        }
        guard varB > 0 else { return 1 }
        // Keep betas in a sane range so one weird window doesn't dominate.
        return min(max(cov / varB, -1), 4)
    }

    static func change(_ closes: [Double], last: Double, sessions: Int) -> Double {
        guard closes.count > sessions else {
            guard let first = closes.first, first > 0 else { return 0 }
            return (last / first - 1) * 100
        }
        let base = closes[closes.count - 1 - sessions]
        return base > 0 ? (last / base - 1) * 100 : 0
    }

    public static func analyze(stock: PriceSeries, benchmark: PriceSeries, market: PriceSeries) -> MovementFacts {
        let closes = stock.points.map(\.close)
        // History excludes today's move so "typical" isn't inflated by the event we're explaining.
        let history = Array(returns(closes).dropLast().suffix(60))
        let benchHistory = Array(returns(benchmark.points.map(\.close)).dropLast().suffix(60))

        let day = stock.dayChangePercent
        let benchDay = benchmark.dayChangePercent
        let marketDay = market.dayChangePercent
        let b = beta(stock: history, benchmark: benchHistory)
        let expected = b * benchDay
        let excess = day - expected
        let typical = max(stdev(history), 0.25)
        let z = day / typical

        let volumes = stock.points.map(\.volume)
        let avgVol = mean(Array(volumes.dropLast().suffix(20)))
        let volRatio = avgVol > 0 ? (volumes.last ?? 0) / avgVol : 1

        let high = closes.max() ?? stock.lastPrice
        let fromHigh = high > 0 ? min((stock.lastPrice / high - 1) * 100, 0) : 0

        let character = classify(day: day, excess: excess, expected: expected, typical: typical)

        return MovementFacts(
            symbol: stock.symbol,
            benchmark: benchmark.symbol,
            dayChange: day,
            weekChange: change(closes, last: stock.lastPrice, sessions: 5),
            monthChange: change(closes, last: stock.lastPrice, sessions: 21),
            benchmarkDayChange: benchDay,
            marketDayChange: marketDay,
            beta: b,
            expectedMove: expected,
            excessMove: excess,
            typicalDailyMove: typical,
            zScore: z,
            volumeRatio: volRatio,
            distanceFrom52wHigh: fromHigh,
            character: character
        )
    }

    static func classify(day: Double, excess: Double, expected: Double, typical: Double) -> MoveCharacter {
        if abs(day) < typical && abs(excess) < typical { return .noise }
        let excessZ = abs(excess) / typical
        if excessZ < 1 { return .marketDriven }
        // Same direction as the market and the market explains a meaningful part.
        if expected * day > 0 && abs(expected) >= 0.35 * abs(day) { return .amplified }
        return .stockSpecific
    }
}
