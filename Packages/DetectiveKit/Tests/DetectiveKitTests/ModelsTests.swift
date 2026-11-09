import XCTest
@testable import DetectiveKit

final class ModelsTests: XCTestCase {
    func testPricePointInit() {
        let d = Date()
        let p = PricePoint(date: d, close: 10, volume: 5)
        XCTAssertEqual(p.date, d); XCTAssertEqual(p.close, 10); XCTAssertEqual(p.volume, 5)
    }

    func testPriceSeriesDayChange() {
        XCTAssertEqual(makeSeries("A", closes: [100], last: 110, prev: 100).dayChangePercent, 10, accuracy: 1e-9)
        XCTAssertEqual(makeSeries("A", closes: [100], last: 90, prev: 100).dayChangePercent, -10, accuracy: 1e-9)
        XCTAssertEqual(makeSeries("A", closes: [100], last: 90, prev: 0).dayChangePercent, 0, "no division by zero")
        XCTAssertEqual(PriceSeries(symbol: "A", points: [], lastPrice: 1, previousClose: 1).currency, "USD")
    }

    func testNewsArticleID() {
        XCTAssertEqual(NewsArticle(title: "T", link: "https://a").id, "https://a")
        XCTAssertEqual(NewsArticle(title: "T").id, "T", "falls back to title without a link")
        let a = NewsArticle(title: "T")
        XCTAssertEqual(a.summary, ""); XCTAssertEqual(a.source, ""); XCTAssertNil(a.published)
    }

    func testSectorETFsAndNames() {
        let expected: [Sector: String] = [.technology: "XLK", .communication: "XLC", .consumerDiscretionary: "XLY",
                                          .consumerStaples: "XLP", .energy: "XLE", .financials: "XLF", .healthCare: "XLV",
                                          .industrials: "XLI", .materials: "XLB", .realEstate: "XLRE", .utilities: "XLU",
                                          .broadMarket: "SPY"]
        XCTAssertEqual(Sector.allCases.count, expected.count)
        for s in Sector.allCases {
            XCTAssertEqual(s.etf, expected[s], "\(s)")
            XCTAssertFalse(s.displayName.isEmpty)
            XCTAssertEqual(s.id, s.rawValue)
        }
        XCTAssertEqual(Set(Sector.allCases.map(\.displayName)).count, Sector.allCases.count, "names are unique")
    }

    func testSectorGuess() {
        XCTAssertEqual(Sector.guess(for: "AAPL"), .technology)
        XCTAssertEqual(Sector.guess(for: "aapl"), .technology, "case-insensitive")
        XCTAssertEqual(Sector.guess(for: "GOOGL"), .communication)
        XCTAssertEqual(Sector.guess(for: "AMZN"), .consumerDiscretionary)
        XCTAssertEqual(Sector.guess(for: "KO"), .consumerStaples)
        XCTAssertEqual(Sector.guess(for: "XOM"), .energy)
        XCTAssertEqual(Sector.guess(for: "JPM"), .financials)
        XCTAssertEqual(Sector.guess(for: "LLY"), .healthCare)
        XCTAssertEqual(Sector.guess(for: "CAT"), .industrials)
        XCTAssertEqual(Sector.guess(for: "LIN"), .materials)
        XCTAssertEqual(Sector.guess(for: "PLD"), .realEstate)
        XCTAssertEqual(Sector.guess(for: "NEE"), .utilities)
        XCTAssertEqual(Sector.guess(for: "VOO"), .broadMarket, "unknown → broad market")
        XCTAssertEqual(Sector.guess(for: ""), .broadMarket)
    }

    func testSymbolMatch() {
        let m = SymbolMatch(symbol: "AAPL", name: "Apple")
        XCTAssertEqual(m.id, "AAPL"); XCTAssertEqual(m.exchange, "")
    }

    func testMarketDataErrorDescriptions() {
        XCTAssertTrue(MarketDataError.badResponse("host").errorDescription!.contains("host"))
        XCTAssertTrue(MarketDataError.noData("ZZZ").errorDescription!.contains("ZZZ"))
    }
}

final class MovementAnalyzerTests: XCTestCase {
    func testReturns() {
        XCTAssertEqual(MovementAnalyzer.returns([]), [])
        XCTAssertEqual(MovementAnalyzer.returns([5]), [])
        let r = MovementAnalyzer.returns([100, 110, 99])
        XCTAssertEqual(r[0], 10, accuracy: 1e-9); XCTAssertEqual(r[1], -10, accuracy: 1e-9)
        XCTAssertEqual(MovementAnalyzer.returns([0, 10, 11]).count, 1, "skips returns from a zero price")
    }

    func testMeanAndStdev() {
        XCTAssertEqual(MovementAnalyzer.mean([]), 0)
        XCTAssertEqual(MovementAnalyzer.mean([1, 2, 3]), 2)
        XCTAssertEqual(MovementAnalyzer.stdev([]), 0)
        XCTAssertEqual(MovementAnalyzer.stdev([7]), 0)
        XCTAssertEqual(MovementAnalyzer.stdev([2, 4, 4, 4, 5, 5, 7, 9]), 2.138, accuracy: 0.001)
    }

    func testBeta() {
        let b = [1.0, -1, 2, -2, 0.5, -0.5, 1.5]
        XCTAssertEqual(MovementAnalyzer.beta(stock: b.map { $0 * 2 }, benchmark: b), 2, accuracy: 1e-9)
        XCTAssertEqual(MovementAnalyzer.beta(stock: [1, 2], benchmark: [1, 2]), 1, "too little data → 1")
        XCTAssertEqual(MovementAnalyzer.beta(stock: b, benchmark: Array(repeating: 1, count: 7)), 1, "flat benchmark → 1")
        XCTAssertEqual(MovementAnalyzer.beta(stock: b.map { $0 * 10 }, benchmark: b), 4, "clamped high")
        XCTAssertEqual(MovementAnalyzer.beta(stock: b.map { $0 * -5 }, benchmark: b), -1, "clamped low")
    }

    func testChange() {
        XCTAssertEqual(MovementAnalyzer.change([100, 105, 110], last: 121, sessions: 1), 15.238, accuracy: 0.001)
        XCTAssertEqual(MovementAnalyzer.change([100, 110], last: 120, sessions: 5), 20, accuracy: 1e-9, "short series uses first close")
        XCTAssertEqual(MovementAnalyzer.change([], last: 120, sessions: 5), 0)
        XCTAssertEqual(MovementAnalyzer.change([0, 0, 0], last: 120, sessions: 1), 0, "zero base")
    }

    func testClassifyEveryBranch() {
        XCTAssertEqual(MovementAnalyzer.classify(day: 0.5, excess: 0.2, expected: 0.3, typical: 1), .noise)
        XCTAssertEqual(MovementAnalyzer.classify(day: -3, excess: -0.5, expected: -2.5, typical: 1), .marketDriven)
        XCTAssertEqual(MovementAnalyzer.classify(day: -4, excess: -2, expected: -2, typical: 1), .amplified)
        XCTAssertEqual(MovementAnalyzer.classify(day: -4, excess: -4, expected: 0, typical: 1), .stockSpecific)
        XCTAssertEqual(MovementAnalyzer.classify(day: 4, excess: 5, expected: -1, typical: 1), .stockSpecific, "against the market")
    }

    func testMoveCharacterLabels() {
        for c in [MoveCharacter.noise, .marketDriven, .stockSpecific, .amplified] { XCTAssertFalse(c.label.isEmpty) }
    }

    func testFactsHelpers() {
        XCTAssertEqual(makeFacts(day: 0).explainedByMarket, 1, "no move is fully 'explained'")
        XCTAssertEqual(makeFacts(day: 4, expected: 2).explainedByMarket, 0.5, accuracy: 1e-9)
        XCTAssertEqual(makeFacts(day: 2, expected: 4).explainedByMarket, 1, "clamped to 1")
        XCTAssertEqual(makeFacts(day: 2, expected: -1).explainedByMarket, 0, "clamped to 0")
        XCTAssertTrue(makeFacts(day: 3.5, typical: 5).isSignificant, "big absolute move")
        XCTAssertTrue(makeFacts(day: 2, typical: 1).isSignificant, "big vs normal")
        XCTAssertFalse(makeFacts(day: 1, typical: 1).isSignificant)
    }

    func testAnalyzeMarketDriven() {
        var bench: [Double] = [100], stock: [Double] = [50]
        for i in 0..<60 {
            let r = (i % 2 == 0 ? 1.0 : -0.9) / 100
            bench.append(bench.last! * (1 + r))
            stock.append(stock.last! * (1 + r + (i % 3 == 0 ? 0.0005 : -0.0005)))
        }
        let b = makeSeries("XLK", closes: bench, last: bench.last! * 0.97)
        let s = makeSeries("AAA", closes: stock, last: stock.last! * 0.97)
        let f = MovementAnalyzer.analyze(stock: s, benchmark: b, market: b)
        XCTAssertEqual(f.character, .marketDriven)
        XCTAssertEqual(f.benchmark, "XLK"); XCTAssertEqual(f.symbol, "AAA")
        XCTAssertEqual(f.dayChange, -3, accuracy: 0.01)
        XCTAssertEqual(f.beta, 1, accuracy: 0.1)
        XCTAssertGreaterThan(f.explainedByMarket, 0.8)
    }

    func testAnalyzeStockSpecificWithVolumeAndHigh() {
        var bench: [Double] = [100], stock: [Double] = [50]
        for i in 0..<60 {
            let r = (i % 2 == 0 ? 0.8 : -0.7) / 100
            bench.append(bench.last! * (1 + r)); stock.append(stock.last! * (1 + r))
        }
        var volumes = Array(repeating: 1000.0, count: stock.count); volumes[volumes.count - 1] = 3000
        let b = makeSeries("XLK", closes: bench, last: bench.last!)
        let s = makeSeries("AAA", closes: stock, last: stock.last! * 0.9, volumes: volumes)
        let f = MovementAnalyzer.analyze(stock: s, benchmark: b, market: b)
        XCTAssertEqual(f.character, .stockSpecific)
        XCTAssertEqual(f.volumeRatio, 3, accuracy: 0.01)
        XCTAssertLessThan(f.distanceFrom52wHigh, -9)
        XCTAssertLessThan(f.zScore, -5)
    }
}

final class NewsScorerTests: XCTestCase {
    func testWords() {
        XCTAssertEqual(NewsScorer.words("Apple's Q3: beats, sell-off!"), ["apple", "s", "q3", "beats", "sell-off"])
    }

    func testScoreSentimentAndCatalysts() {
        let neg = NewsScorer.score(NewsArticle(title: "Acme misses earnings estimates, cuts guidance", published: Date()), symbol: "ACME", companyName: "Acme Corp")
        XCTAssertLessThan(neg.sentiment, 0)
        XCTAssertTrue(neg.catalysts.contains("earnings")); XCTAssertTrue(neg.catalysts.contains("guidance"))
        let pos = NewsScorer.score(NewsArticle(title: "Acme surges to record on upgrade"), symbol: "ACME", companyName: nil)
        XCTAssertGreaterThan(pos.sentiment, 0); XCTAssertTrue(pos.catalysts.contains("analyst"))
        let neutral = NewsScorer.score(NewsArticle(title: "Acme hosts annual meeting"), symbol: "ACME", companyName: nil)
        XCTAssertEqual(neutral.sentiment, 0)
        XCTAssertTrue(NewsScorer.score(NewsArticle(title: "Fed holds rates steady"), symbol: "X", companyName: nil).catalysts.contains("macro"))
        XCTAssertTrue(NewsScorer.score(NewsArticle(title: "CEO steps down at Acme"), symbol: "X", companyName: nil).catalysts.contains("management"), "multi-word keyword")
    }

    func testRelevanceFactors() {
        let now = Date()
        let base = NewsScorer.score(NewsArticle(title: "Something happened", published: now.addingTimeInterval(-30 * 3600)), symbol: "ACME", companyName: nil, now: now).relevance
        XCTAssertEqual(base, 0.2, accuracy: 1e-9)
        let withSymbol = NewsScorer.score(NewsArticle(title: "ACME something", published: now.addingTimeInterval(-30 * 3600)), symbol: "ACME", companyName: nil, now: now).relevance
        XCTAssertEqual(withSymbol, 0.45, accuracy: 1e-9)
        let withName = NewsScorer.score(NewsArticle(title: "Globex something", published: now.addingTimeInterval(-30 * 3600)), symbol: "GBX", companyName: "Globex Inc", now: now).relevance
        XCTAssertEqual(withName, 0.45, accuracy: 1e-9)
        let fresh = NewsScorer.score(NewsArticle(title: "Something", published: now.addingTimeInterval(-3600)), symbol: "ACME", companyName: nil, now: now).relevance
        XCTAssertEqual(fresh, 0.3, accuracy: 1e-9)
        let stale = NewsScorer.score(NewsArticle(title: "Something", published: now.addingTimeInterval(-100 * 3600)), symbol: "ACME", companyName: nil, now: now).relevance
        XCTAssertEqual(stale, 0, accuracy: 1e-9, "clamped at 0")
        let loaded = NewsScorer.score(NewsArticle(title: "ACME Acme earnings guidance upgrade lawsuit beats", published: now), symbol: "ACME", companyName: "Acme", now: now).relevance
        XCTAssertEqual(loaded, 1, "clamped at 1")
    }

    func testRankDedupesSortsAndLimits() {
        let articles = [
            NewsArticle(title: "Unrelated story"),
            NewsArticle(title: "ACME beats earnings", published: Date()),
            NewsArticle(title: "acme beats earnings"),
            NewsArticle(title: "ACME update"),
        ]
        let ranked = NewsScorer.rank(articles, symbol: "ACME", companyName: nil, limit: 2)
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.first?.article.title, "ACME beats earnings")
        XCTAssertGreaterThanOrEqual(ranked[0].relevance, ranked[1].relevance)
        XCTAssertEqual(NewsScorer.rank(articles, symbol: "ACME", companyName: nil).count, 3, "duplicate title removed")
        XCTAssertEqual(ranked[0].id, ranked[0].article.id)
    }
}
