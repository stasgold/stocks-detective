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
        XCTAssertEqual(f.typicalDailyMove, 0.25, "floor when there's no history")
        XCTAssertEqual(f.volumeRatio, 1, "no volume data → neutral")
        XCTAssertEqual(f.beta, 1)
    }
}
