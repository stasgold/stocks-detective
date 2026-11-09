import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import DetectiveKit

// MARK: - Builders

func makeSeries(_ symbol: String, closes: [Double], last: Double? = nil, volumes: [Double]? = nil, prev: Double? = nil) -> PriceSeries {
    let now = Date()
    let points = closes.enumerated().map { i, c in
        PricePoint(date: now.addingTimeInterval(Double(i - closes.count) * 86400), close: c, volume: volumes?[i] ?? 1000)
    }
    return PriceSeries(symbol: symbol, points: points, lastPrice: last ?? closes.last!, previousClose: prev ?? closes.last!)
}

func makeFacts(day: Double = 0, week: Double = 0, month: Double = 0, bench: Double = 0, market: Double = 0,
               beta: Double = 1, expected: Double = 0, excess: Double? = nil, typical: Double = 1, z: Double? = nil,
               volume: Double = 1, fromHigh: Double = 0, character: MoveCharacter = .noise) -> MovementFacts {
    MovementFacts(symbol: "TEST", benchmark: "XLK", dayChange: day, weekChange: week, monthChange: month,
                  benchmarkDayChange: bench, marketDayChange: market, beta: beta, expectedMove: expected,
                  excessMove: excess ?? (day - expected), typicalDailyMove: typical, zScore: z ?? (day / typical),
                  volumeRatio: volume, distanceFrom52wHigh: fromHigh, character: character)
}

func scored(_ title: String, sentiment: Double = 0, relevance: Double = 0.8, catalysts: [String] = [], hoursAgo: Double? = 2) -> ScoredArticle {
    ScoredArticle(article: NewsArticle(title: title, source: "Wire", link: "https://x/\(title.hashValue)",
                                       published: hoursAgo.map { Date().addingTimeInterval(-$0 * 3600) }),
                  sentiment: sentiment, relevance: relevance, catalysts: catalysts)
}

func makeCase(_ facts: MovementFacts, news: [ScoredArticle] = [], marketNews: [ScoredArticle] = [], name: String? = "Test Corp") -> CaseFile {
    CaseFile(symbol: facts.symbol, companyName: name, sector: .technology, facts: facts, news: news,
             marketNews: marketNews, series: makeSeries(facts.symbol, closes: [100, 101]))
}

// MARK: - Fake network

/// Serves canned responses for URLSession so network code is tested without the internet.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Route { let match: String; let status: Int; let body: Data }
    nonisolated(unsafe) private static var routes: [Route] = []
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(_ newRoutes: [Route] = []) {
        lock.lock(); defer { lock.unlock() }
        routes = newRoutes
        seen = []
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self.seen.append(request)
        let route = Self.routes.first { url.absoluteString.contains($0.match) }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: route?.status ?? 404, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route?.body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Canned payloads

enum Fixtures {
    static func chartJSON(symbol: String = "AAPL", closes: [Double?], volumes: [Double?]? = nil, sameDay: Bool = true,
                          name: String? = "Apple Inc.", prevClose: Double? = nil) -> Data {
        let now = Date().timeIntervalSince1970
        let ts = closes.indices.map { now - Double(closes.count - 1 - $0) * 86400 }
        let marketTime = sameDay ? now : now + 3 * 86400
        func list(_ xs: [Double?]) -> String { xs.map { $0.map { "\($0)" } ?? "null" }.joined(separator: ",") }
        let vols = volumes ?? closes.map { _ in 1000 }
        let nameField = name.map { ",\"longName\":\"\($0)\"" } ?? ""
        let prev = prevClose.map { ",\"chartPreviousClose\":\($0),\"previousClose\":\($0)" } ?? ""
        let json = """
        {"chart":{"result":[{"meta":{"currency":"USD","symbol":"\(symbol)","regularMarketPrice":\(closes.last!! ),"regularMarketTime":\(marketTime)\(nameField)\(prev)},
        "timestamp":[\(ts.map { "\($0)" }.joined(separator: ","))],
        "indicators":{"quote":[{"open":[\(list(closes))],"high":[\(list(closes.map { $0.map { $0 + 1 } }))],"low":[\(list(closes.map { $0.map { $0 - 1 } }))],"close":[\(list(closes))],"volume":[\(list(vols))]}]}}]}}
        """
        return Data(json.utf8)
    }

    static func rss(_ items: [(title: String, source: String?)]) -> Data {
        let body = items.map { item in
            "<item><title>\(item.title)</title><link>https://n/\(item.title.count)</link><pubDate>Fri, 06 Nov 2026 14:00:00 GMT</pubDate>\(item.source.map { "<source url=\"https://s\">\($0)</source>" } ?? "")<description>d</description></item>"
        }.joined()
        return Data("<rss><channel>\(body)</channel></rss>".utf8)
    }
}

// MARK: - Counting provider (for cache tests)

actor CallCounter {
    private(set) var counts: [String: Int] = [:]
    func hit(_ key: String) { counts[key, default: 0] += 1 }
    func count(_ key: String) -> Int { counts[key] ?? 0 }
}

struct CountingProvider: MarketDataProvider {
    let inner = DemoMarketData()
    let counter = CallCounter()
    var failing: Set<String> = []

    func priceSeries(for symbol: String) async throws -> (series: PriceSeries, name: String?) {
        await counter.hit("series:\(symbol)")
        if failing.contains(symbol) { throw MarketDataError.noData(symbol) }
        return try await inner.priceSeries(for: symbol)
    }
    func news(for symbol: String) async throws -> [NewsArticle] {
        await counter.hit("news:\(symbol)")
        if failing.contains("news") { throw MarketDataError.badResponse("news") }
        return try await inner.news(for: symbol)
    }
    func marketNews() async throws -> [NewsArticle] {
        await counter.hit("marketNews")
        if failing.contains("marketNews") { throw MarketDataError.badResponse("market") }
        return try await inner.marketNews()
    }
    func search(_ query: String) async throws -> [SymbolMatch] { try await inner.search(query) }
    func chart(for symbol: String, range: ChartRange) async throws -> ChartData {
        await counter.hit("chart:\(symbol)")
        if failing.contains("chart") { throw MarketDataError.noData(symbol) }
        return try await inner.chart(for: symbol, range: range)
    }
}
