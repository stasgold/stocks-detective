import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import DetectiveKit

final class RSSParserTests: XCTestCase {
    func testGoogleStyleTitleSourceSplit() {
        let items = RSSParser.parse(Data("<rss><channel><item><title>Apple beats - Reuters</title><link>https://x/1</link><pubDate>Fri, 06 Nov 2026 14:00:00 GMT</pubDate><description><![CDATA[<p>Strong &amp; steady</p>]]></description></item></channel></rss>".utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Apple beats"); XCTAssertEqual(items[0].source, "Reuters")
        XCTAssertEqual(items[0].link, "https://x/1"); XCTAssertEqual(items[0].summary, "Strong & steady")
        XCTAssertNotNil(items[0].published)
    }

    func testSourceElementAndTitleSuffix() {
        let items = RSSParser.parse(Fixtures.rss([("Chips rally - Bloomberg", "Bloomberg")]))
        XCTAssertEqual(items[0].title, "Chips rally", "duplicate ' - Source' suffix removed")
        XCTAssertEqual(items[0].source, "Bloomberg")
    }

    func testSkipsEmptyTitlesBadDatesAndJunk() {
        let xml = "<rss><channel><title>Feed title</title><item><title></title></item><item><title>Kept</title><pubDate>not a date</pubDate></item></channel></rss>"
        let items = RSSParser.parse(Data(xml.utf8))
        XCTAssertEqual(items.map(\.title), ["Kept"], "channel title isn't an item; empty titles skipped")
        XCTAssertNil(items[0].published)
        XCTAssertEqual(RSSParser.parse(Data("not xml".utf8)).count, 0)
    }

    func testStripHTML() {
        XCTAssertEqual(RSSParser.stripHTML("<b>A</b>&nbsp;&quot;B&quot; &#39;C&apos; &lt;D&gt;  \n E"), "A \"B\" 'C' <D> E")
        XCTAssertEqual(RSSParser.stripHTML(String(repeating: "x", count: 500)).count, 280, "truncated")
    }
}

final class YahooParserTests: XCTestCase {
    func testParseSeriesSameDay() throws {
        let r = try YahooChartParser.parse(Fixtures.chartJSON(closes: [100, nil, 200, 190]), symbol: "AAPL")
        XCTAssertEqual(r.name, "Apple Inc.")
        XCTAssertEqual(r.series.points.count, 3, "null closes skipped")
        XCTAssertEqual(r.series.previousClose, 200, "latest bar is today → previous bar is yesterday's close")
        XCTAssertEqual(r.series.lastPrice, 190)
    }

    func testParseSeriesMarketClosed() throws {
        let r = try YahooChartParser.parse(Fixtures.chartJSON(closes: [100, 200], sameDay: false, name: nil), symbol: "AAPL")
        XCTAssertEqual(r.series.previousClose, 200, "no bar for today yet → last bar is the previous close")
        XCTAssertNil(r.name)
    }

    func testParseSeriesErrors() {
        XCTAssertThrowsError(try YahooChartParser.parse(Data("{\"chart\":{\"result\":null}}".utf8), symbol: "X"))
        XCTAssertThrowsError(try YahooChartParser.parse(Fixtures.chartJSON(closes: [100]), symbol: "X"), "needs 2 points")
        XCTAssertThrowsError(try YahooChartParser.parse(Data("garbage".utf8), symbol: "X"))
    }

    func testParseChart() throws {
        let day = try YahooChartParser.parseChart(Fixtures.chartJSON(symbol: "TSM", closes: [380, nil, 375.44], prevClose: 353.1), symbol: "TSM", range: .day)
        XCTAssertEqual(day.bars.count, 2)
        XCTAssertEqual(day.bars[1].high, 376.44); XCTAssertEqual(day.bars[1].low, 374.44); XCTAssertEqual(day.bars[1].open, 375.44)
        XCTAssertEqual(day.previousClose, 353.1)
        XCTAssertEqual(day.currency, "USD")
        let month = try YahooChartParser.parseChart(Fixtures.chartJSON(closes: [1, 2]), symbol: "A", range: .month)
        XCTAssertNil(month.previousClose)
        let noBars = #"{"chart":{"result":[{"meta":{"symbol":"A"},"timestamp":[1,2],"indicators":{"quote":[{"close":[null,null]}]}}]}}"#
        XCTAssertThrowsError(try YahooChartParser.parseChart(Data(noBars.utf8), symbol: "A", range: .day), "no usable bars")
        XCTAssertThrowsError(try YahooChartParser.parseChart(Data(#"{"chart":{}}"#.utf8), symbol: "A", range: .day))
    }

    func testParseSearch() throws {
        let json = """
        {"quotes":[{"symbol":"AAPL","shortname":"Apple","longname":"Apple Inc.","exchDisp":"NASDAQ","quoteType":"EQUITY"},
        {"symbol":"VOO","shortname":"Vanguard S&P 500","quoteType":"ETF"},{"symbol":"AAPL250C","quoteType":"OPTION"},{"symbol":"X"}]}
        """
        let r = try YahooSearchParser.parse(Data(json.utf8))
        XCTAssertEqual(r.map(\.symbol), ["AAPL", "VOO", "X"], "options filtered out; missing type treated as equity")
        XCTAssertEqual(r[0].name, "Apple Inc."); XCTAssertEqual(r[0].exchange, "NASDAQ")
        XCTAssertEqual(r[1].name, "Vanguard S&P 500"); XCTAssertEqual(r[2].name, "X")
        XCTAssertEqual(try YahooSearchParser.parse(Data("{}".utf8)), [])
    }
}

final class YahooNetworkTests: XCTestCase {
    var yahoo: YahooMarketData!

    override func setUp() {
        StubURLProtocol.reset()
        yahoo = YahooMarketData(session: StubURLProtocol.session())
    }

    func testGetSendsUserAgentAndRejectsErrors() async throws {
        StubURLProtocol.reset([.init(match: "ok", status: 200, body: Data("hi".utf8)), .init(match: "bad", status: 429, body: Data())])
        let data = try await yahoo.get(URL(string: "https://h/ok")!)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hi")
        XCTAssertNotNil(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "User-Agent"))
        do {
            _ = try await yahoo.get(URL(string: "https://h/bad")!)
            XCTFail("429 must throw")
        } catch {
            XCTAssertTrue(error is MarketDataError)
        }
    }

    func testPriceSeriesRequest() async throws {
        StubURLProtocol.reset([.init(match: "/v8/finance/chart/BRK-B", status: 200, body: Fixtures.chartJSON(symbol: "BRK-B", closes: [1, 2, 3]))])
        let r = try await yahoo.priceSeries(for: "BRK-B")
        XCTAssertEqual(r.series.symbol, "BRK-B")
        XCTAssertTrue(StubURLProtocol.requests[0].url!.absoluteString.contains("range=6mo&interval=1d"))
    }

    func testNewsMergesFeedsLabelsSourcesAndSorts() async throws {
        StubURLProtocol.reset([
            .init(match: "feeds.finance.yahoo.com", status: 200, body: Data("<rss><channel><item><title>Yahoo story</title><pubDate>Fri, 06 Nov 2026 10:00:00 GMT</pubDate></item></channel></rss>".utf8)),
            .init(match: "news.google.com", status: 200, body: Data("<rss><channel><item><title>Google story - CNBC</title><pubDate>Fri, 06 Nov 2026 12:00:00 GMT</pubDate></item></channel></rss>".utf8)),
        ])
        let news = try await yahoo.news(for: "AAPL")
        XCTAssertEqual(news.map(\.title), ["Google story", "Yahoo story"], "newest first")
        XCTAssertEqual(news.map(\.source), ["CNBC", "Yahoo Finance"], "Yahoo items get a source label")
    }

    func testNewsSurvivesOneFeedFailing() async throws {
        StubURLProtocol.reset([.init(match: "news.google.com", status: 200, body: Fixtures.rss([("Only Google", nil)]))])
        let news = try await yahoo.news(for: "AAPL")
        XCTAssertEqual(news.map(\.title), ["Only Google"])
    }

    func testMarketNewsAndSearch() async throws {
        StubURLProtocol.reset([
            .init(match: "stock+market+today", status: 200, body: Fixtures.rss([("Stocks rise - AP", nil)])),
            .init(match: "/v1/finance/search", status: 200, body: Data("{\"quotes\":[{\"symbol\":\"AAPL\",\"shortname\":\"Apple\"}]}".utf8)),
        ])
        let market = try await yahoo.marketNews()
        XCTAssertEqual(market.first?.title, "Stocks rise")
        let found = try await yahoo.search("apple inc")
        XCTAssertEqual(found.map(\.symbol), ["AAPL"])
        XCTAssertTrue(StubURLProtocol.requests.last!.url!.absoluteString.contains("q=apple%20inc"))
    }

    func testChartRequestsRightRangeAndInterval() async throws {
        StubURLProtocol.reset([.init(match: "/v8/finance/chart/", status: 200, body: Fixtures.chartJSON(closes: [1, 2]))])
        for r in ChartRange.allCases {
            _ = try await yahoo.chart(for: "AAPL", range: r)
            let url = StubURLProtocol.requests.last!.url!.absoluteString
            XCTAssertTrue(url.contains("range=\(r.yahooRange)&interval=\(r.yahooInterval)"), url)
        }
    }
}
