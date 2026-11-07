import XCTest
@testable import DetectiveKit

final class DetectiveKitTests: XCTestCase {
    func makeSeries(_ symbol: String, closes: [Double], last: Double, volumes: [Double]? = nil) -> PriceSeries {
        let now = Date()
        let pts = closes.enumerated().map { i, c in
            PricePoint(date: now.addingTimeInterval(Double(i - closes.count) * 86400), close: c, volume: volumes?[i] ?? 1000)
        }
        return PriceSeries(symbol: symbol, points: pts, lastPrice: last, previousClose: closes.last!)
    }

    func testStatistics() {
        let r = MovementAnalyzer.returns([100, 110, 99])
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0], 10, accuracy: 1e-9)
        XCTAssertEqual(r[1], -10, accuracy: 1e-9)
        XCTAssertEqual(MovementAnalyzer.stdev([2, 4, 4, 4, 5, 5, 7, 9]), 2.138, accuracy: 0.001)
        let b = [1.0, -1, 2, -2, 0.5, -0.5, 1.5]
        XCTAssertEqual(MovementAnalyzer.beta(stock: b.map { $0 * 2 }, benchmark: b), 2, accuracy: 1e-9)
    }

    func testMarketDrivenMove() {
        // Stock tracks benchmark 1:1 with tiny noise; today both drop 3%.
        var bench: [Double] = [100], stock: [Double] = [50]
        for i in 0..<60 {
            let r = (i % 2 == 0 ? 1.0 : -0.9) / 100
            bench.append(bench.last! * (1 + r))
            stock.append(stock.last! * (1 + r + (i % 3 == 0 ? 0.0005 : -0.0005)))
        }
        let b = makeSeries("XLK", closes: bench, last: bench.last! * 0.97)
        let s = makeSeries("AAA", closes: stock, last: stock.last! * 0.97)
        let facts = MovementAnalyzer.analyze(stock: s, benchmark: b, market: b)
        XCTAssertEqual(facts.character, .marketDriven)
        XCTAssertGreaterThan(facts.explainedByMarket, 0.8)
    }

    func testStockSpecificMove() {
        var bench: [Double] = [100], stock: [Double] = [50]
        for i in 0..<60 {
            let r = (i % 2 == 0 ? 0.8 : -0.7) / 100
            bench.append(bench.last! * (1 + r))
            stock.append(stock.last! * (1 + r))
        }
        let b = makeSeries("XLK", closes: bench, last: bench.last! * 1.001)
        let s = makeSeries("AAA", closes: stock, last: stock.last! * 0.92)
        let facts = MovementAnalyzer.analyze(stock: s, benchmark: b, market: b)
        XCTAssertEqual(facts.character, .stockSpecific)
        XCTAssertLessThan(facts.excessMove, -7)
    }

    func testNewsScoring() {
        let a = NewsArticle(title: "Acme misses earnings estimates, cuts guidance", published: Date())
        let s = NewsScorer.score(a, symbol: "ACME", companyName: "Acme Corp")
        XCTAssertLessThan(s.sentiment, 0)
        XCTAssertTrue(s.catalysts.contains("earnings"))
        XCTAssertTrue(s.catalysts.contains("guidance"))
        XCTAssertGreaterThan(s.relevance, 0.6)
    }

    func testRSSParsing() {
        let xml = """
        <rss><channel><item><title>Apple beats estimates - Reuters</title><link>https://x.y/1</link>
        <pubDate>Fri, 06 Nov 2026 14:00:00 GMT</pubDate><description><![CDATA[<p>Strong &amp; steady</p>]]></description></item></channel></rss>
        """
        let items = RSSParser.parse(Data(xml.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Apple beats estimates")
        XCTAssertEqual(items[0].source, "Reuters")
        XCTAssertEqual(items[0].summary, "Strong & steady")
        XCTAssertNotNil(items[0].published)
    }

    func testYahooChartParsing() throws {
        let now = Date().timeIntervalSince1970
        let json = """
        {"chart":{"result":[{"meta":{"currency":"USD","symbol":"AAPL","regularMarketPrice":190,"regularMarketTime":\(now),"longName":"Apple Inc."},
        "timestamp":[\(now - 86400),\(now)],"indicators":{"quote":[{"close":[200,190],"volume":[10,20]}]}}]}}
        """
        let r = try YahooChartParser.parse(Data(json.utf8), symbol: "AAPL")
        XCTAssertEqual(r.name, "Apple Inc.")
        XCTAssertEqual(r.series.previousClose, 200)
        XCTAssertEqual(r.series.dayChangePercent, -5, accuracy: 1e-9)
    }

    func testDemoPortfolioProducesEveryKindOfCase() async throws {
        let builder = CaseBuilder(provider: DemoMarketData())
        let holdings = ["AAPL", "NVDA", "MSFT", "TSLA", "JPM"].map { HoldingInput(symbol: $0, sector: Sector.guess(for: $0), shares: 10) }
        var cases: [CaseFile] = []
        for h in holdings { cases.append(try await builder.buildCase(for: h)) }
        let reports = cases.map(RuleBasedDetective.investigate)
        for r in reports {
            XCTAssertFalse(r.whatHappened.isEmpty)
            XCTAssertFalse(r.watchNext.isEmpty)
            print(r.symbol, r.verdict, "|", r.headline)
        }
        let brief = cases[0].promptBrief()
        XCTAssertTrue(brief.contains("AAPL"))
        XCTAssertLessThan(brief.count, 2000, "Keep model prompts small")
        let snap = PortfolioSnapshot(cases: cases, holdings: holdings)
        XCTAssertEqual(snap.lines.count, 5)
        XCTAssertEqual(snap.topContributors.count, 5)
    }
}
