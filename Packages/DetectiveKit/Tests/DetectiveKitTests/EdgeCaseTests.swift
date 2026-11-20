import XCTest
@testable import DetectiveKit

/// Fallback paths: what happens when data is missing or duplicated.
final class EdgeCaseTests: XCTestCase {
    func testYahooPayloadWithMissingFields() throws {
        // No currency, price, market time, names or volumes.
        let json = #"{"chart":{"result":[{"meta":{"symbol":"X"},"timestamp":[1,2,3],"indicators":{"quote":[{"close":[1,2,4]}]}}]}}"#
        let r = try YahooChartParser.parse(Data(json.utf8), symbol: "X")
        XCTAssertEqual(r.series.currency, "USD")
        XCTAssertEqual(r.series.lastPrice, 4, "falls back to the last close")
        XCTAssertEqual(r.series.previousClose, 4, "no market time → last bar is the previous close")
        XCTAssertEqual(r.series.points.map(\.volume), [0, 0, 0])
        XCTAssertNil(r.name)
        let c = try YahooChartParser.parseChart(Data(json.utf8), symbol: "X", range: .month)
        XCTAssertEqual(c.currency, "USD")
        XCTAssertNil(c.bars[0].open); XCTAssertEqual(c.bars[0].volume, 0)
        let short = #"{"chart":{"result":[{"meta":{"symbol":"X"},"timestamp":[1,2,3],"indicators":{"quote":[{"close":[1,2]}]}}]}}"#
        XCTAssertEqual(try YahooChartParser.parse(Data(short.utf8), symbol: "X").series.points.count, 2, "more timestamps than closes")
    }

    func testEmptyChartDomain() {
        let d = ChartData(symbol: "A", range: .month, currency: "USD", bars: [], previousClose: nil).priceDomain
        XCTAssertLessThan(d.lowerBound, d.upperBound)
    }

    func testMarketNewsFailureIsTolerated() async throws {
        let provider = CountingProvider(failing: ["marketNews"])
        let file = try await CaseBuilder(provider: provider).buildCase(for: HoldingInput(symbol: "AAPL", sector: .technology, shares: 1))
        XCTAssertTrue(file.marketNews.isEmpty)
        XCTAssertFalse(file.news.isEmpty)
    }

    func testSnapshotWithDuplicatesAndMissingNews() async throws {
        let builder = CaseBuilder(provider: DemoMarketData())
        let tsla = try await builder.buildCase(for: HoldingInput(symbol: "TSLA", sector: .consumerDiscretionary, shares: 1))
        let holdings = [HoldingInput(symbol: "TSLA", sector: .consumerDiscretionary, shares: 2),
                        HoldingInput(symbol: "tsla", sector: .consumerDiscretionary, shares: 5)]
        let s = PortfolioSnapshot(cases: [tsla, tsla], holdings: holdings)
        XCTAssertEqual(s.lines.count, 2, "one line per case")
        XCTAssertEqual(s.lines[0].value, 2 * tsla.series.lastPrice, accuracy: 1e-9, "first holding wins on duplicates")
        XCTAssertTrue(s.promptBrief(cases: [tsla, tsla]).contains("no headline"), "TSLA demo has no news")
        XCTAssertTrue(PortfolioSnapshot(cases: [tsla], holdings: []).lines.isEmpty, "cases without a holding are ignored")
    }

    func testImporterSkipsHeaderOnlyAndTickerOnlyLines() {
        let r = PortfolioImporter.parse("SYMBOL SHARES\nAAPL\nMSFT QTY")
        XCTAssertTrue(r.rows.isEmpty)
        XCTAssertTrue(r.skipped.isEmpty, "a ticker followed by a header word isn't reported as unreadable")
    }

    func testRSSWithSourceButNoSuffix() {
        let items = RSSParser.parse(Fixtures.rss([("Plain title", "Reuters")]))
        XCTAssertEqual(items[0].title, "Plain title"); XCTAssertEqual(items[0].source, "Reuters")
    }

    func testAnalyzeWithMinimalHistory() {
        let s = makeSeries("A", closes: [10, 11], last: 12, volumes: [0, 0])
        let f = MovementAnalyzer.analyze(stock: s, benchmark: s, market: s)
        XCTAssertEqual(f.typicalDailyMove, 3, "new-listing range when there's almost no history")
        XCTAssertTrue(f.limitedHistory)
        XCTAssertEqual(f.volumeRatio, 1, "no volume data → neutral")
        XCTAssertEqual(f.beta, 1)
    }
}

/// New listings (e.g. ANT on its first days): Yahoo has a price but almost no history.
final class NewListingTests: XCTestCase {
    /// Shape of Yahoo's reply for ANT on its first trading day (trimmed).
    static let antFirstDay = #"""
    {"chart":{"result":[{"meta":{"currency":"USD","symbol":"ANT","regularMarketTime":1795122001,"regularMarketPrice":97.17,
    "regularMarketVolume":851818130,"longName":"Anthropic, PBC","chartPreviousClose":83.0},
    "timestamp":[1795122001],"indicators":{"quote":[{"close":[97.17],"volume":[851818130]}]}}]}}
    """#

    func testParsesFirstDayWithOneBar() throws {
        let r = try YahooChartParser.parse(Data(Self.antFirstDay.utf8), symbol: "ANT")
        XCTAssertEqual(r.name, "Anthropic, PBC")
        XCTAssertEqual(r.series.points.count, 1)
        XCTAssertEqual(r.series.previousClose, 83)
        XCTAssertEqual(r.series.dayChangePercent, 17.07, accuracy: 0.01, "matches Yahoo's +17.07%")
    }

    func testParsesWithNoBarsAtAll() throws {
        let json = #"{"chart":{"result":[{"meta":{"symbol":"NEW","regularMarketPrice":12,"previousClose":10,"regularMarketVolume":5}}]}}"#
        let r = try YahooChartParser.parse(Data(json.utf8), symbol: "NEW")
        XCTAssertEqual(r.series.points.count, 1)
        XCTAssertEqual(r.series.points[0].volume, 5)
        XCTAssertEqual(r.series.dayChangePercent, 20, accuracy: 1e-9)
    }

    func testStillRejectsWhenThereIsNoPriceOrReference() {
        let noPrev = #"{"chart":{"result":[{"meta":{"symbol":"X","regularMarketPrice":12},"timestamp":[1],"indicators":{"quote":[{"close":[12]}]}}]}}"#
        XCTAssertThrowsError(try YahooChartParser.parse(Data(noPrev.utf8), symbol: "X"))
        let noPrice = #"{"chart":{"result":[{"meta":{"symbol":"X","previousClose":10}}]}}"#
        XCTAssertThrowsError(try YahooChartParser.parse(Data(noPrice.utf8), symbol: "X"))
    }

    func testAnalysisAndVerdictForANewListing() throws {
        let ant = try YahooChartParser.parse(Data(Self.antFirstDay.utf8), symbol: "ANT").series
        let spy = makeSeries("SPY", closes: (0..<60).map { 100 + Double($0 % 3) }, last: 101, prev: 100)
        let f = MovementAnalyzer.analyze(stock: ant, benchmark: spy, market: spy)
        XCTAssertTrue(f.limitedHistory)
        XCTAssertEqual(f.historyDays, 1)
        XCTAssertEqual(f.typicalDailyMove, 3, "IPO-like range instead of a tiny floor")
        XCTAssertEqual(f.character, .stockSpecific)

        let withNews = CaseFile(symbol: "ANT", companyName: "Anthropic, PBC", sector: .technology, facts: f,
                                news: [scored("Anthropic soars in Nasdaq debut", sentiment: 1, relevance: 0.9)], marketNews: [], series: ant)
        let r = RuleBasedDetective.investigate(withNews)
        XCTAssertEqual(r.verdict, .justified, "never 'overreaction' without a baseline")
        XCTAssertEqual(r.causes.first?.title, "Newly listed")
        XCTAssertTrue(r.watchNext.first!.contains("first weeks"))
        XCTAssertTrue(withNews.promptBrief().contains("NEW LISTING: only 1 trading day"))

        let noNews = RuleBasedDetective.investigate(CaseFile(symbol: "ANT", companyName: nil, sector: .technology, facts: f,
                                                             news: [], marketNews: [], series: ant))
        XCTAssertEqual(noNews.verdict, .unexplained)
        XCTAssertTrue(noNews.verdictReasoning.contains("newly listed"))
    }

    func testEstablishedStocksAreUnaffected() {
        XCTAssertFalse(makeFacts(day: 1).limitedHistory, "default history is a full year")
        XCTAssertFalse(makeCase(makeFacts(day: 1)).promptBrief().contains("NEW LISTING"))
    }
}
