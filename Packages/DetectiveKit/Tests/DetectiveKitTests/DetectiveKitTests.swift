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

final class PortfolioImporterTests: XCTestCase {
    func testBrokerTable() {
        let text = """
        HOLDINGS
        SYM        QTY    PRICE($)    DAY%  DAY P&L(₪)
        VOO        238      675.99  +0.30%       1,534
        TSM        160      375.44  +6.33%      11,401
        IVV         66      738.68  +0.34%         520
        LLY         34     1354.00  -0.79%      -1,164
        NVDA       210      186.64  +2.78%       3,376
        AMZN       150      259.30  -0.35%        -435
        ASML        25     1424.75  +5.02%       5,430
        MSFT        64      530.61  -0.99%      -1,086
        GOOGL       28      284.78  +0.78%         197
        SPY          9      735.29  +0.31%          66
        """
        let r = PortfolioImporter.parse(text)
        XCTAssertEqual(r.rows.map(\.symbol), ["VOO", "TSM", "IVV", "LLY", "NVDA", "AMZN", "ASML", "MSFT", "GOOGL", "SPY"])
        XCTAssertEqual(r.rows.map(\.shares), [238, 160, 66, 34, 210, 150, 25, 64, 28, 9])
        XCTAssertEqual(r.rows[3].price, 1354)
        XCTAssertTrue(r.skipped.isEmpty)
    }

    func testOtherFormats() {
        let r = PortfolioImporter.parse("""
        Ticker,Shares,Cost
        AAPL,10,150.5
        brk.b\t3
        $TSLA 1,200
        AAPL 5
        Total 1000
        """)
        XCTAssertEqual(r.rows.map(\.symbol), ["AAPL", "BRK.B", "TSLA"])
        XCTAssertEqual(r.rows.map(\.shares), [15, 3, 1200])
    }
}

final class ChartTests: XCTestCase {
    func testDemoChartsForEveryRange() async throws {
        for range in ChartRange.allCases {
            let c = try await DemoMarketData().chart(for: "AAPL", range: range)
            XCTAssertGreaterThan(c.bars.count, 1, "\(range)")
            XCTAssertNotNil(c.changePercent)
            XCTAssertLessThan(c.priceDomain.lowerBound, c.priceDomain.upperBound)
        }
        let day = try await DemoMarketData().chart(for: "AAPL", range: .day)
        XCTAssertEqual(day.changePercent!, -3.4, accuracy: 0.01, "1D change matches the case's day move")
    }

    func testParseYahooChart() throws {
        let json = """
        {"chart":{"result":[{"meta":{"currency":"USD","symbol":"TSM","chartPreviousClose":353.1,"previousClose":353.1},
        "timestamp":[1,2,3],"indicators":{"quote":[{"open":[380,null,376],"high":[390,null,380],"low":[370,null,372],"close":[381,null,375.44],"volume":[100,null,300]}]}}]}}
        """
        let c = try YahooChartParser.parseChart(Data(json.utf8), symbol: "TSM", range: .day)
        XCTAssertEqual(c.bars.count, 2)
        XCTAssertEqual(c.bars[1].high, 380)
        XCTAssertEqual(c.changePercent!, (375.44 / 353.1 - 1) * 100, accuracy: 1e-9)
    }
}

final class ReportValidatorTests: XCTestCase {
    func facts(day: Double) -> MovementFacts {
        MovementFacts(symbol: "ASML", benchmark: "XLK", dayChange: day, weekChange: -9.01, monthChange: -19.5,
                      benchmarkDayChange: 1.5, marketDayChange: 0.3, beta: 1.12, expectedMove: 1.7, excessMove: day - 1.7,
                      typicalDailyMove: 2.6, zScore: day / 2.6, volumeRatio: 1.8, distanceFrom52wHigh: -28.38, character: .stockSpecific)
    }

    func testCatchesWrongDirectionAndNumbers() {
        // The headline from the ASML screenshot: stock was up 5.02%.
        XCTAssertTrue(ReportValidator.contradicts("ASML Stocks Fall 7.36% as Investors Question the Next Spending Cycle", facts: facts(day: 5.02)))
        XCTAssertTrue(ReportValidator.contradicts("ASML jumps 12% on guidance", facts: facts(day: 5.02)))
        XCTAssertFalse(ReportValidator.contradicts("ASML rebounds 5% after a 19.5% monthly slide", facts: facts(day: 5.02)))
        XCTAssertFalse(ReportValidator.contradicts("ASML surges 5.0% on heavy volume", facts: facts(day: 5.02)))
        XCTAssertTrue(ReportValidator.contradicts("ASML rallies on chip demand", facts: facts(day: -3)))
    }
}

final class RowSparklineTests: XCTestCase {
    /// The row's mini chart and its % pill must describe the same thing: the last trading day.
    func testIntradayMatchesDayChange() async throws {
        let builder = CaseBuilder(provider: DemoMarketData())
        for symbol in ["AAPL", "NVDA", "JPM"] {
            let file = try await builder.buildCase(for: HoldingInput(symbol: symbol, sector: .guess(for: symbol), shares: 1))
            let day = try XCTUnwrap(file.intraday)
            XCTAssertEqual(day.range, .day)
            XCTAssertEqual(try XCTUnwrap(day.changePercent), file.facts.dayChange, accuracy: 0.01, symbol)
        }
    }
}
