import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SymbolMatch: Codable, Hashable, Sendable, Identifiable {
    public var id: String { symbol }
    public let symbol: String
    public let name: String
    public let exchange: String

    public init(symbol: String, name: String, exchange: String = "") {
        self.symbol = symbol
        self.name = name
        self.exchange = exchange
    }
}

public protocol MarketDataProvider: Sendable {
    func priceSeries(for symbol: String) async throws -> (series: PriceSeries, name: String?)
    func news(for symbol: String) async throws -> [NewsArticle]
    func marketNews() async throws -> [NewsArticle]
    func search(_ query: String) async throws -> [SymbolMatch]
}

public enum MarketDataError: Error, LocalizedError {
    case badResponse(String)
    case noData(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let s): "Market data request failed for \(s)."
        case .noData(let s): "No price data for \(s). Check the ticker."
        }
    }
}

/// Free, keyless data: Yahoo Finance chart API for prices, Yahoo + Google News RSS for headlines.
public struct YahooMarketData: MarketDataProvider {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MarketDataError.badResponse(url.host ?? "")
        }
        return data
    }

    public func priceSeries(for symbol: String) async throws -> (series: PriceSeries, name: String?) {
        let s = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(s)?range=6mo&interval=1d")!
        let data = try await get(url)
        return try YahooChartParser.parse(data, symbol: symbol)
    }

    public func news(for symbol: String) async throws -> [NewsArticle] {
        let q = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol
        let feeds: [(url: URL?, defaultSource: String)] = [
            (URL(string: "https://feeds.finance.yahoo.com/rss/2.0/headline?s=\(q)&region=US&lang=en-US"), "Yahoo Finance"),
            (URL(string: "https://news.google.com/rss/search?q=\(q)+stock&hl=en-US&gl=US&ceid=US:en"), "Google News"),
        ]
        // Independent tasks, each awaited before returning.
        let session = self
        let jobs = feeds.compactMap { f in f.url.map { url in (f.defaultSource, Task { try? await session.get(url) }) } }
        var articles: [NewsArticle] = []
        for (defaultSource, job) in jobs {
            guard let data = await job.value else { continue }
            articles += RSSParser.parse(data).map { a in
                a.source.isEmpty ? NewsArticle(title: a.title, summary: a.summary, source: defaultSource, link: a.link, published: a.published) : a
            }
        }
        return articles.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
    }

    public func marketNews() async throws -> [NewsArticle] {
        let url = URL(string: "https://news.google.com/rss/search?q=stock+market+today&hl=en-US&gl=US&ceid=US:en")!
        return RSSParser.parse(try await get(url))
    }

    public func search(_ query: String) async throws -> [SymbolMatch] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/search?q=\(q)&quotesCount=8&newsCount=0")!
        return try YahooSearchParser.parse(try await get(url))
    }
}

enum YahooChartParser {
    struct Root: Decodable { let chart: Chart }
    struct Chart: Decodable { let result: [Result]? }
    struct Result: Decodable {
        let meta: Meta
        let timestamp: [TimeInterval]?
        let indicators: Indicators
    }
    struct Meta: Decodable {
        let currency: String?
        let symbol: String
        let regularMarketPrice: Double?
        let regularMarketTime: TimeInterval?
        let longName: String?
        let shortName: String?
    }
    struct Indicators: Decodable { let quote: [Quote] }
    struct Quote: Decodable {
        let close: [Double?]?
        let volume: [Double?]?
    }

    static func parse(_ data: Data, symbol: String) throws -> (series: PriceSeries, name: String?) {
        let root = try JSONDecoder().decode(Root.self, from: data)
        guard let r = root.chart.result?.first, let ts = r.timestamp, let q = r.indicators.quote.first,
              let closes = q.close else { throw MarketDataError.noData(symbol) }
        let vols = q.volume ?? []
        var points: [PricePoint] = []
        for (i, t) in ts.enumerated() where i < closes.count {
            guard let c = closes[i] else { continue }
            let v = i < vols.count ? (vols[i] ?? 0) : 0
            points.append(PricePoint(date: Date(timeIntervalSince1970: t), close: c, volume: v))
        }
        guard points.count >= 2 else { throw MarketDataError.noData(symbol) }
        let last = r.meta.regularMarketPrice ?? points[points.count - 1].close
        // If the latest bar is today's session, yesterday's close is the bar before it.
        var prev = points[points.count - 1].close
        if let mt = r.meta.regularMarketTime {
            let cal = Calendar(identifier: .gregorian)
            if cal.isDate(points[points.count - 1].date, inSameDayAs: Date(timeIntervalSince1970: mt)) {
                prev = points[points.count - 2].close
            }
        }
        let series = PriceSeries(symbol: r.meta.symbol, currency: r.meta.currency ?? "USD",
                                 points: points, lastPrice: last, previousClose: prev)
        return (series, r.meta.longName ?? r.meta.shortName)
    }
}

enum YahooSearchParser {
    struct Root: Decodable { let quotes: [Q]? }
    struct Q: Decodable {
        let symbol: String
        let shortname: String?
        let longname: String?
        let exchDisp: String?
        let quoteType: String?
    }

    static func parse(_ data: Data) throws -> [SymbolMatch] {
        let root = try JSONDecoder().decode(Root.self, from: data)
        return (root.quotes ?? [])
            .filter { ["EQUITY", "ETF"].contains($0.quoteType ?? "EQUITY") }
            .map { SymbolMatch(symbol: $0.symbol, name: $0.longname ?? $0.shortname ?? $0.symbol, exchange: $0.exchDisp ?? "") }
    }
}
