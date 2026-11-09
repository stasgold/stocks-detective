import XCTest
@testable import DetectiveKit

final class DemoMarketDataTests: XCTestCase {
    let demo = DemoMarketData()

    func testStableHashAndPRNG() {
        XCTAssertEqual("AAPL".hashValue_stable, "AAPL".hashValue_stable)
        XCTAssertNotEqual("AAPL".hashValue_stable, "MSFT".hashValue_stable)
        var a = DemoMarketData.SeededRandom(state: 7), b = DemoMarketData.SeededRandom(state: 7)
        XCTAssertEqual(a.next(), b.next())
        for _ in 0..<100 { let x = a.next(); XCTAssertTrue((0..<1).contains(x)) }
        XCTAssertTrue(a.normal().isFinite)
    }

    func testStoriesAndBenchmarks() {
        XCTAssertEqual(DemoMarketData.story("aapl").name, "Apple Inc.")
        XCTAssertEqual(DemoMarketData.story("ZZZ").name, "ZZZ", "unknown symbols get a quiet default story")
        XCTAssertEqual(DemoMarketData.benchmarkToday("SPY"), -0.6)
        XCTAssertNil(DemoMarketData.benchmarkToday("AAPL"))
    }

    func testPriceSeriesIsDeterministicAndScripted() async throws {
        let a = try await demo.priceSeries(for: "AAPL"), b = try await demo.priceSeries(for: "aapl")
        XCTAssertEqual(a.series.lastPrice, b.series.lastPrice, accuracy: 1e-9)
        XCTAssertEqual(a.series.dayChangePercent, -3.4, accuracy: 1e-9)
        XCTAssertEqual(a.series.points.count, 125)
        XCTAssertEqual(a.name, "Apple Inc.")
        let spy = try await demo.priceSeries(for: "SPY")
        XCTAssertEqual(spy.series.dayChangePercent, -0.6, accuracy: 1e-9)
    }

    func testNewsMarketNewsSearch() async throws {
        let news = try await demo.news(for: "AAPL")
        XCTAssertEqual(news.count, 3)
        XCTAssertTrue(news.allSatisfy { $0.published != nil })
        let tsla = try await demo.news(for: "TSLA")
        XCTAssertTrue(tsla.isEmpty, "TSLA's demo story has no news on purpose")
        let market = try await demo.marketNews()
        XCTAssertEqual(market.count, 2)
        let ap = try await demo.search("ap")
        XCTAssertEqual(ap.map(\.symbol), ["AAPL"])
        let corp = try await demo.search("corp")
        XCTAssertEqual(corp.map(\.symbol), ["MSFT", "NVDA"], "matches names, sorted")
    }

    func testChartForEveryRange() async throws {
        for r in ChartRange.allCases {
            let c = try await demo.chart(for: "NVDA", range: r)
            XCTAssertGreaterThan(c.bars.count, 1, "\(r)")
            XCTAssertEqual(c.range, r)
            XCTAssertEqual(c.previousClose != nil, r == .day)
            XCTAssertTrue(zip(c.bars, c.bars.dropFirst()).allSatisfy { $0.date < $1.date }, "\(r) bars in time order")
        }
    }
}

final class CaseBuilderTests: XCTestCase {
    func testBuildsCompleteCase() async throws {
        let builder = CaseBuilder(provider: DemoMarketData())
        let file = try await builder.buildCase(for: HoldingInput(symbol: "aapl", sector: .technology, shares: 10))
        XCTAssertEqual(file.symbol, "AAPL")
        XCTAssertEqual(file.companyName, "Apple Inc.")
        XCTAssertEqual(file.facts.benchmark, "XLK")
        XCTAssertEqual(file.news.count, 3)
        XCTAssertEqual(file.marketNews.count, 2)
        XCTAssertNotNil(file.intraday)
    }

    func testHoldingInputDefaults() {
        let h = HoldingInput(symbol: "A", sector: .energy, shares: 2)
        XCTAssertNil(h.costBasis); XCTAssertEqual(h.shares, 2)
    }

    func testStockFailureThrowsAndNothingElseIsRequested() async throws {
        let provider = CountingProvider(failing: ["BAD"])
        let builder = CaseBuilder(provider: provider)
        do {
            _ = try await builder.buildCase(for: HoldingInput(symbol: "BAD", sector: .technology, shares: 1))
            XCTFail("should throw")
        } catch {}
        let news = await provider.counter.count("news:BAD")
        let bench = await provider.counter.count("series:XLK")
        XCTAssertEqual(news + bench, 0, "no other requests start when the stock fails")
    }

    func testOptionalPartsMayFail() async throws {
        let provider = CountingProvider(failing: ["XLK", "SPY", "news", "chart"])
        let file = try await CaseBuilder(provider: provider).buildCase(for: HoldingInput(symbol: "AAPL", sector: .technology, shares: 1))
        XCTAssertEqual(file.facts.benchmark, "AAPL", "falls back to the stock itself")
        XCTAssertTrue(file.news.isEmpty)
        XCTAssertNil(file.intraday)
    }

    func testCachesSeriesAndMarketNews() async throws {
        let provider = CountingProvider()
        let builder = CaseBuilder(provider: provider)
        for s in ["AAPL", "MSFT", "NVDA"] {
            _ = try await builder.buildCase(for: HoldingInput(symbol: s, sector: .technology, shares: 1))
        }
        _ = try await builder.series("AAPL")
        let spy = await provider.counter.count("series:SPY")
        let xlk = await provider.counter.count("series:XLK")
        let aapl = await provider.counter.count("series:AAPL")
        let market = await provider.counter.count("marketNews")
        XCTAssertEqual(spy, 1); XCTAssertEqual(xlk, 1); XCTAssertEqual(aapl, 1); XCTAssertEqual(market, 1)
        let news = await builder.companyNews("AAPL")
        XCTAssertEqual(news.count, 3)
        let ranked = await builder.marketNews()
        XCTAssertEqual(ranked.count, 2)
    }
}

final class PortfolioSnapshotTests: XCTestCase {
    func caseFile(_ symbol: String, prev: Double, last: Double, z: Double, character: MoveCharacter) -> CaseFile {
        var f = makeFacts(day: (last / prev - 1) * 100, typical: 1, z: z, character: character)
        f = MovementFacts(symbol: symbol, benchmark: f.benchmark, dayChange: f.dayChange, weekChange: 0, monthChange: 0,
                          benchmarkDayChange: 0, marketDayChange: 0.3, beta: 1, expectedMove: 0, excessMove: f.dayChange,
                          typicalDailyMove: 1, zScore: z, volumeRatio: 1, distanceFrom52wHigh: 0, character: character)
        return CaseFile(symbol: symbol, companyName: nil, sector: .technology, facts: f, news: [scored("\(symbol) news")], marketNews: [],
                        series: makeSeries(symbol, closes: [prev], last: last, prev: prev))
    }

    func testTotalsContributorsSuspects() {
        let cases = [caseFile("UP", prev: 100, last: 110, z: 3, character: .stockSpecific),
                     caseFile("DN", prev: 50, last: 49, z: -0.5, character: .noise),
                     caseFile("MKT", prev: 10, last: 9, z: -2, character: .marketDriven)]
        let holdings = [HoldingInput(symbol: "up", sector: .technology, shares: 10, costBasis: 55),
                        HoldingInput(symbol: "DN", sector: .technology, shares: 100),
                        HoldingInput(symbol: "MKT", sector: .technology, shares: 5, costBasis: 0)]
        let s = PortfolioSnapshot(cases: cases, holdings: holdings)
        XCTAssertEqual(s.lines.count, 3)
        XCTAssertEqual(s.totalValue, 1100 + 4900 + 45, accuracy: 1e-9)
        XCTAssertEqual(s.dayPnL, 100 - 100 - 5, accuracy: 1e-9)
        XCTAssertEqual(s.dayChangePercent, -5 / (6045 + 5) * 100, accuracy: 1e-9)
        XCTAssertEqual(s.topContributors.map(\.symbol).prefix(2).sorted(), ["DN", "UP"])
        XCTAssertEqual(s.suspects.map(\.symbol), ["UP"], "market-driven and normal moves aren't suspects")
        XCTAssertEqual(s.lines.first { $0.symbol == "UP" }!.totalReturn!, 100, accuracy: 1e-9)
        XCTAssertNil(s.lines.first { $0.symbol == "DN" }!.totalReturn)
        XCTAssertNil(s.lines.first { $0.symbol == "MKT" }!.totalReturn, "zero cost basis ignored")
        XCTAssertEqual(s.lines[0].id, s.lines[0].symbol)

        let brief = s.promptBrief(cases: cases, holdings: 2)
        XCTAssertTrue(brief.hasPrefix("PORTFOLIO today:"))
        XCTAssertEqual(brief.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count, 2)
        XCTAssertTrue(brief.contains("UP news"))
        XCTAssertTrue(brief.contains("S&P 500 today: +0.3%"))
    }

    func testEmptyPortfolio() {
        let s = PortfolioSnapshot(cases: [], holdings: [])
        XCTAssertEqual(s.totalValue, 0); XCTAssertEqual(s.dayChangePercent, 0)
        XCTAssertFalse(s.promptBrief(cases: []).contains("S&P"))
    }
}

final class PortfolioImporterUnitTests: XCTestCase {
    func testIsTicker() {
        for t in ["AAPL", "BRK.B", "BRK-B", "A", "GOOGL", "TSM"] { XCTAssertTrue(PortfolioImporter.isTicker(t), t) }
        for t in ["SYM", "QTY", "HOLDINGS", "TOTAL", "aapl", "1ABC", "TOOLONGX", "", "AB.CDE"] { XCTAssertFalse(PortfolioImporter.isTicker(t), t) }
    }

    func testNumber() {
        XCTAssertEqual(PortfolioImporter.number("1,534"), 1534)
        XCTAssertEqual(PortfolioImporter.number("-1,164"), -1164)
        XCTAssertEqual(PortfolioImporter.number("1,234,567.5"), 1234567.5)
        XCTAssertEqual(PortfolioImporter.number("675.99"), 675.99)
        XCTAssertEqual(PortfolioImporter.number("12,5"), 12.5, "decimal comma")
        XCTAssertEqual(PortfolioImporter.number("$12"), 12)
        XCTAssertEqual(PortfolioImporter.number("₪7"), 7)
        XCTAssertEqual(PortfolioImporter.number("€3"), 3)
        XCTAssertEqual(PortfolioImporter.number("£4"), 4)
        XCTAssertNil(PortfolioImporter.number("+6.33%"), "percentages are never quantities")
        XCTAssertNil(PortfolioImporter.number("abc"))
    }

    func testTokens() {
        XCTAssertEqual(PortfolioImporter.tokens("VOO   238  675.99"), ["VOO", "238", "675.99"])
        XCTAssertEqual(PortfolioImporter.tokens("AAPL,10,150.5"), ["AAPL", "10", "150.5"])
        XCTAssertEqual(PortfolioImporter.tokens("AAPL\t10;12|x"), ["AAPL", "10", "12", "x"])
        XCTAssertEqual(PortfolioImporter.tokens("\"MSFT\" '5'"), ["MSFT", "5"])
        XCTAssertEqual(PortfolioImporter.tokens("   "), [])
    }

    func testParseEdgeCases() {
        let r = PortfolioImporter.parse("AAPL 0\nMSFT abc\nNVDA 3 100\nnvda 2\nQTY 5")
        XCTAssertEqual(r.rows.map(\.symbol), ["NVDA"])
        XCTAssertEqual(r.rows[0].shares, 5, "lower-case ticker merged")
        XCTAssertEqual(r.rows[0].price, 100)
        XCTAssertEqual(r.rows[0].id, "NVDA")
        XCTAssertEqual(r.skipped, ["AAPL 0", "MSFT abc"])
        XCTAssertTrue(PortfolioImporter.parse("").rows.isEmpty)
    }
}

final class ChartModelTests: XCTestCase {
    func testRangeProperties() {
        XCTAssertEqual(ChartRange.allCases.map(\.rawValue), ["1D", "5D", "1M", "6M", "YTD", "1Y", "5Y", "All"])
        XCTAssertEqual(ChartRange.allCases.map(\.yahooRange), ["1d", "5d", "1mo", "6mo", "ytd", "1y", "5y", "max"])
        XCTAssertEqual(ChartRange.allCases.map(\.yahooInterval), ["5m", "15m", "1d", "1d", "1d", "1d", "1wk", "1mo"])
        XCTAssertEqual(ChartRange.allCases.filter(\.isIntraday), [.day, .fiveDays])
        XCTAssertEqual(Set(ChartRange.allCases.map(\.periodLabel)).count, 8)
        XCTAssertEqual(ChartRange.day.id, "1D")
    }

    func bars(_ closes: [Double], minutesApart: Double = 5) -> [ChartBar] {
        closes.enumerated().map { ChartBar(date: Date(timeIntervalSince1970: Double($0.offset) * minutesApart * 60), open: nil, high: nil, low: nil, close: $0.element, volume: 1) }
    }

    func testBaselineAndChange() {
        let withPrev = ChartData(symbol: "A", range: .day, currency: "USD", bars: bars([105, 110]), previousClose: 100)
        XCTAssertEqual(withPrev.baseline, 100); XCTAssertEqual(withPrev.change, 10); XCTAssertEqual(withPrev.changePercent!, 10, accuracy: 1e-9)
        let noPrev = ChartData(symbol: "A", range: .month, currency: "USD", bars: bars([50, 40]), previousClose: nil)
        XCTAssertEqual(noPrev.baseline, 50); XCTAssertEqual(noPrev.changePercent!, -20, accuracy: 1e-9)
        let zeroPrev = ChartData(symbol: "A", range: .month, currency: "USD", bars: bars([50, 40]), previousClose: 0)
        XCTAssertEqual(zeroPrev.baseline, 50, "ignores a zero previous close")
        let empty = ChartData(symbol: "A", range: .day, currency: "USD", bars: [], previousClose: nil)
        XCTAssertNil(empty.baseline); XCTAssertNil(empty.change); XCTAssertNil(empty.changePercent)
    }

    func testXSlots() {
        XCTAssertEqual(ChartData(symbol: "A", range: .day, currency: "USD", bars: bars([1, 2, 3]), previousClose: nil).xSlots, 79, "mid-day: room for the whole session")
        XCTAssertEqual(ChartData(symbol: "A", range: .day, currency: "USD", bars: bars(Array(repeating: 1, count: 100)), previousClose: nil).xSlots, 100, "full day")
        XCTAssertEqual(ChartData(symbol: "A", range: .month, currency: "USD", bars: bars([1, 2, 3]), previousClose: nil).xSlots, 3)
    }

    func testPriceDomain() {
        let d = ChartData(symbol: "A", range: .month, currency: "USD", bars: bars([100, 110]), previousClose: 95).priceDomain
        XCTAssertLessThan(d.lowerBound, 95, "nearby baseline kept on screen")
        XCTAssertGreaterThan(d.upperBound, 110)
        let far = ChartData(symbol: "A", range: .all, currency: "USD", bars: bars([100, 110]), previousClose: 5).priceDomain
        XCTAssertGreaterThan(far.lowerBound, 50, "far-away baseline (e.g. All) doesn't squash the chart")
        let flat = ChartData(symbol: "A", range: .month, currency: "USD", bars: bars([7, 7]), previousClose: nil).priceDomain
        XCTAssertLessThan(flat.lowerBound, flat.upperBound, "flat prices still give a valid range")
        let ohlc = ChartData(symbol: "A", range: .month, currency: "USD",
                             bars: [ChartBar(date: Date(), open: 10, high: 20, low: 5, close: 10, volume: 1)], previousClose: nil).priceDomain
        XCTAssertLessThan(ohlc.lowerBound, 5); XCTAssertGreaterThan(ohlc.upperBound, 20)
    }
}
