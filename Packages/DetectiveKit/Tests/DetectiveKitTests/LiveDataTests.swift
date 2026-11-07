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
