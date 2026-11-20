import XCTest
@testable import DetectiveKit

/// Calls the real data sources. Skipped unless LIVE_NETWORK=1 (CI "Diagnose" workflow).
final class LiveDataTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_NETWORK"] == "1", "Set LIVE_NETWORK=1 to hit live endpoints")
    }

    let provider = YahooMarketData()

    func testPrices() async throws {
        for symbol in ["AAPL", "VOO", "TSM"] {
            do {
                let r = try await provider.priceSeries(for: symbol)
                print("PRICES \(symbol): \(r.series.points.count) days, last \(r.series.lastPrice), today \(String(format: "%+.2f", r.series.dayChangePercent))%, name \(r.name ?? "-")")
            } catch {
                print("PRICES \(symbol): FAILED \(error)")
                XCTFail("Price fetch failed for \(symbol): \(error)")
            }
        }
    }

    func testCompanyNews() async throws {
        for symbol in ["AAPL", "NVDA", "VOO"] {
            let news = try await provider.news(for: symbol)
            let sources = Dictionary(grouping: news, by: { $0.source.isEmpty ? "?" : $0.source }).mapValues(\.count)
            print("NEWS \(symbol): \(news.count) headlines, \(news.filter { $0.published != nil }.count) dated, top sources \(sources.sorted { $0.value > $1.value }.prefix(4))")
            for n in news.prefix(3) { print("   - \(n.title) [\(n.source)] \(n.published.map { "\($0)" } ?? "no date")") }
            XCTAssertFalse(news.isEmpty, "No headlines for \(symbol)")
        }
    }

    func testFeedsIndividually() async throws {
        let feeds = [
            "Yahoo RSS": "https://feeds.finance.yahoo.com/rss/2.0/headline?s=AAPL&region=US&lang=en-US",
            "Google News": "https://news.google.com/rss/search?q=AAPL+stock&hl=en-US&gl=US&ceid=US:en",
            "Market news": "https://news.google.com/rss/search?q=stock+market+today&hl=en-US&gl=US&ceid=US:en",
        ]
        for (name, url) in feeds.sorted(by: { $0.key < $1.key }) {
            do {
                let data = try await provider.get(URL(string: url)!)
                print("FEED \(name): \(data.count) bytes, \(RSSParser.parse(data).count) items")
            } catch {
                print("FEED \(name): FAILED \(error)")
            }
        }
    }

    func testFullCase() async throws {
        let builder = CaseBuilder(provider: provider)
        let file = try await builder.buildCase(for: HoldingInput(symbol: "NVDA", sector: .technology, shares: 1))
        print("CASE NVDA: \(file.facts.character.label), z \(String(format: "%.1f", file.facts.zScore)), \(file.news.count) ranked headlines, \(file.marketNews.count) market headlines")
        print(file.promptBrief())
        let report = RuleBasedDetective.investigate(file)
        print("REPORT: \(report.verdict.label) — \(report.headline)")
    }
}

final class LiveChartTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_NETWORK"] == "1", "Set LIVE_NETWORK=1 to hit live endpoints")
    }

    func testEveryRange() async throws {
        for range in ChartRange.allCases {
            let c = try await YahooMarketData().chart(for: "TSM", range: range)
            let withOHLC = c.bars.filter { $0.open != nil && $0.high != nil && $0.low != nil }.count
            print("CHART TSM \(range.rawValue): \(c.bars.count) bars (\(withOHLC) with OHLC), \(c.bars.first!.date) → \(c.bars.last!.date), change \(String(format: "%+.2f", c.changePercent ?? 0))%, prevClose \(c.previousClose.map { "\($0)" } ?? "-")")
            XCTAssertGreaterThan(c.bars.count, 1)
        }
    }
}

/// Debug a specific ticker: LIVE_NETWORK=1 LIVE_SYMBOLS=ANT,AAPL swift test --filter LiveSymbolProbe
final class LiveSymbolProbe: XCTestCase {
    func testProbeSymbols() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["LIVE_NETWORK"] == "1", "Set LIVE_NETWORK=1 to hit live endpoints")
        let yahoo = YahooMarketData()
        for symbol in (env["LIVE_SYMBOLS"] ?? "ANT").split(separator: ",").map(String.init) {
            print("PROBE ===== \(symbol)")
            for (label, url) in [
                ("chart 6mo", "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?range=6mo&interval=1d"),
                ("chart 1d", "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?range=1d&interval=5m"),
                ("search", "https://query1.finance.yahoo.com/v1/finance/search?q=\(symbol)&quotesCount=8&newsCount=0"),
            ] {
                do {
                    let data = try await yahoo.get(URL(string: url)!)
                    print("PROBE \(label): \(data.count) bytes: \(String(decoding: data.prefix(1200), as: UTF8.self))")
                } catch {
                    print("PROBE \(label): FAILED \(error)")
                }
            }
            do {
                let r = try await yahoo.priceSeries(for: symbol)
                print("PROBE priceSeries OK: \(r.series.points.count) days, name \(r.name ?? "-")")
            } catch {
                print("PROBE priceSeries FAILED: \(error)")
            }
            do {
                let file = try await CaseBuilder(provider: yahoo).buildCase(for: HoldingInput(symbol: symbol, sector: .guess(for: symbol), shares: 1))
                print("PROBE case OK: \(file.facts.character.label), \(file.news.count) headlines")
            } catch {
                print("PROBE case FAILED: \(error)")
            }
        }
    }
}
