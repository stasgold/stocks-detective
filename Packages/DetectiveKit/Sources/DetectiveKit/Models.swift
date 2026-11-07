import Foundation

/// One daily bar of price history.
public struct PricePoint: Codable, Hashable, Sendable {
    public let date: Date
    public let close: Double
    public let volume: Double

    public init(date: Date, close: Double, volume: Double) {
        self.date = date
        self.close = close
        self.volume = volume
    }
}

/// Price history plus the latest live price for one symbol.
public struct PriceSeries: Codable, Hashable, Sendable {
    public let symbol: String
    public let currency: String
    public let points: [PricePoint]
    /// Latest trade price (may be intraday, newer than the last daily close).
    public let lastPrice: Double
    /// Previous session's close, used for the "today" move.
    public let previousClose: Double

    public init(symbol: String, currency: String = "USD", points: [PricePoint], lastPrice: Double, previousClose: Double) {
        self.symbol = symbol
        self.currency = currency
        self.points = points
        self.lastPrice = lastPrice
        self.previousClose = previousClose
    }

    public var dayChangePercent: Double {
        guard previousClose > 0 else { return 0 }
        return (lastPrice / previousClose - 1) * 100
    }
}

public struct NewsArticle: Codable, Hashable, Sendable, Identifiable {
    public var id: String { link.isEmpty ? title : link }
    public let title: String
    public let summary: String
    public let source: String
    public let link: String
    public let published: Date?

    public init(title: String, summary: String = "", source: String = "", link: String = "", published: Date? = nil) {
        self.title = title
        self.summary = summary
        self.source = source
        self.link = link
        self.published = published
    }
}

/// Sector benchmarks we compare a stock against.
public enum Sector: String, CaseIterable, Codable, Sendable, Identifiable {
    case technology, communication, consumerDiscretionary, consumerStaples, energy,
         financials, healthCare, industrials, materials, realEstate, utilities, broadMarket

    public var id: String { rawValue }

    public var etf: String {
        switch self {
        case .technology: "XLK"
        case .communication: "XLC"
        case .consumerDiscretionary: "XLY"
        case .consumerStaples: "XLP"
        case .energy: "XLE"
        case .financials: "XLF"
        case .healthCare: "XLV"
        case .industrials: "XLI"
        case .materials: "XLB"
        case .realEstate: "XLRE"
        case .utilities: "XLU"
        case .broadMarket: "SPY"
        }
    }

    public var displayName: String {
        switch self {
        case .technology: "Technology"
        case .communication: "Communication"
        case .consumerDiscretionary: "Consumer Discretionary"
        case .consumerStaples: "Consumer Staples"
        case .energy: "Energy"
        case .financials: "Financials"
        case .healthCare: "Health Care"
        case .industrials: "Industrials"
        case .materials: "Materials"
        case .realEstate: "Real Estate"
        case .utilities: "Utilities"
        case .broadMarket: "Broad Market / Other"
        }
    }

    /// A small built-in guess so most popular tickers get a sensible benchmark without asking.
    public static func guess(for symbol: String) -> Sector {
        let s = symbol.uppercased()
        let map: [Sector: Set<String>] = [
            .technology: ["AAPL", "MSFT", "NVDA", "AMD", "INTC", "AVGO", "ORCL", "CRM", "ADBE", "QCOM", "TSM", "ASML", "MU", "PLTR", "SNOW", "NOW", "SHOP", "ARM"],
            .communication: ["GOOGL", "GOOG", "META", "NFLX", "DIS", "T", "VZ", "TMUS", "SPOT", "RDDT"],
            .consumerDiscretionary: ["AMZN", "TSLA", "HD", "NKE", "MCD", "SBUX", "LOW", "BKNG", "ABNB", "UBER", "RIVN"],
            .consumerStaples: ["WMT", "COST", "PG", "KO", "PEP", "PM", "TGT"],
            .energy: ["XOM", "CVX", "COP", "OXY", "SLB"],
            .financials: ["JPM", "BAC", "GS", "MS", "WFC", "V", "MA", "BRK-B", "PYPL", "COIN", "HOOD", "SQ", "XYZ"],
            .healthCare: ["UNH", "JNJ", "LLY", "PFE", "MRK", "ABBV", "NVO", "MRNA", "TMO"],
            .industrials: ["BA", "CAT", "GE", "HON", "UPS", "LMT", "RTX", "DE"],
            .materials: ["LIN", "FCX", "NEM", "DOW"],
            .realEstate: ["PLD", "AMT", "O", "SPG"],
            .utilities: ["NEE", "DUK", "SO"],
        ]
        return map.first(where: { $0.value.contains(s) })?.key ?? .broadMarket
    }
}
