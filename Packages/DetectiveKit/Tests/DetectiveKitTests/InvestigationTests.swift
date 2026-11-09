import XCTest
@testable import DetectiveKit

final class InvestigationModelTests: XCTestCase {
    func testVerdictLabels() {
        XCTAssertEqual(Verdict.allCases.count, 5)
        XCTAssertEqual(Set(Verdict.allCases.map(\.label)).count, 5)
    }

    func testCauseAndAuthor() {
        let c = Cause(title: "Earnings", detail: "d")
        XCTAssertEqual(c.id, "Earnings"); XCTAssertNil(c.evidence)
        XCTAssertTrue(ReportAuthor.appleIntelligence.isAI)
        XCTAssertTrue(ReportAuthor.privateCloud.isAI)
        XCTAssertFalse(ReportAuthor.ruleBased.isAI)
    }

    func testReportClampsConfidence() {
        func report(_ c: Int) -> InvestigationReport {
            InvestigationReport(symbol: "A", headline: "", whatHappened: "", causes: [], verdict: .noise,
                                verdictReasoning: "", watchNext: [], confidence: c, author: .ruleBased)
        }
        XCTAssertEqual(report(150).confidence, 100)
        XCTAssertEqual(report(-5).confidence, 0)
        XCTAssertEqual(report(42).confidence, 42)
    }

    func testFmt() {
        XCTAssertEqual(fmt(1.234), "+1.2")
        XCTAssertEqual(fmt(-1.25, 2), "-1.25")
        XCTAssertEqual(fmt(0), "0.0")
    }

    func testNewsSentiment() {
        XCTAssertEqual(makeCase(makeFacts()).newsSentiment, 0, "no news")
        let file = makeCase(makeFacts(), news: [scored("a", sentiment: 1, relevance: 0.5), scored("b", sentiment: -1, relevance: 1),
                                                 scored("ignored", sentiment: 1, relevance: 0.3)])
        XCTAssertEqual(file.newsSentiment, (0.5 - 1) / 2, accuracy: 1e-9, "relevance-weighted, low-relevance ignored")
    }

    func testPromptBrief() {
        let news = (1...8).map { scored("Headline \($0)", catalysts: $0 == 1 ? ["earnings"] : [], hoursAgo: $0 == 1 ? 0.2 : $0 == 2 ? 10 : 72) }
        let market = (1...5).map { scored("Market \($0)") }
        let file = makeCase(makeFacts(day: 2, character: .stockSpecific), news: news, marketNews: market)
        let short = file.promptBrief()
        XCTAssertTrue(short.contains("STOCK: TEST (Test Corp)"))
        XCTAssertTrue(short.contains("Headline 5")); XCTAssertFalse(short.contains("Headline 6"))
        XCTAssertTrue(short.contains("Market 3")); XCTAssertFalse(short.contains("Market 4"))
        XCTAssertTrue(short.contains("(just now) [earnings]"))
        XCTAssertTrue(short.contains("(10h ago)"))
        XCTAssertTrue(short.contains("(3d ago)"))
        XCTAssertTrue(short.contains("STATISTICAL READ: Stock-specific"))
        let long = file.promptBrief(headlines: 10, marketHeadlines: 6)
        XCTAssertTrue(long.contains("Headline 8")); XCTAssertTrue(long.contains("Market 5"))
        let empty = makeCase(makeFacts(), name: nil).promptBrief()
        XCTAssertTrue(empty.contains("- none found")); XCTAssertFalse(empty.contains("MARKET HEADLINES"))
        XCTAssertTrue(empty.contains("STOCK: TEST, sector"))
    }
}

final class RuleBasedDetectiveTests: XCTestCase {
    func testNoise() {
        let r = RuleBasedDetective.investigate(makeCase(makeFacts(day: 0.3, typical: 1, character: .noise)))
        XCTAssertEqual(r.verdict, .noise)
        XCTAssertEqual(r.author, .ruleBased)
        XCTAssertEqual(r.causes.first?.title, "No clear catalyst")
        XCTAssertEqual(r.confidence, 60)
        XCTAssertTrue(r.headline.contains("rose 0.3%"))
    }

    func testMarketDriven() {
        let r = RuleBasedDetective.investigate(makeCase(makeFacts(day: -3, bench: -3, expected: -3, character: .marketDriven),
                                                        marketNews: [scored("Stocks slide")]))
        XCTAssertEqual(r.verdict, .justified)
        XCTAssertEqual(r.causes.first?.title, "Sector & market move")
        XCTAssertEqual(r.causes.first?.evidence, "Stocks slide")
        XCTAssertTrue(r.headline.contains("fell 3.0%"))
    }

    func testUnexplainedWithoutNews() {
        let r = RuleBasedDetective.investigate(makeCase(makeFacts(day: -6, typical: 2, character: .stockSpecific)))
        XCTAssertEqual(r.verdict, .unexplained)
        XCTAssertEqual(r.confidence, 30)
    }

    func testUnexplainedWhenNewsDisagrees() {
        let r = RuleBasedDetective.investigate(makeCase(makeFacts(day: -6, typical: 2, character: .stockSpecific),
                                                        news: [scored("Acme beats", sentiment: 1, relevance: 0.9)]))
        XCTAssertEqual(r.verdict, .unexplained)
    }

    func testOverreaction() {
        let r = RuleBasedDetective.investigate(makeCase(makeFacts(day: 12, typical: 2, volume: 1.0, character: .stockSpecific),
                                                        news: [scored("Acme soars", sentiment: 1, relevance: 0.9, catalysts: ["analyst"])]))
        XCTAssertEqual(r.verdict, .overreaction)
        XCTAssertEqual(r.causes.first?.title, "Analyst")
        XCTAssertTrue(r.watchNext.contains { $0.contains("analysts") })
    }

    func testUnderreaction() {
        let r = RuleBasedDetective.investigate(makeCase(makeFacts(day: 2, typical: 2, volume: 2.5, character: .amplified),
                                                        news: [scored("Acme wins deal", sentiment: 1, relevance: 0.9, catalysts: ["deal"])]))
        XCTAssertEqual(r.verdict, .underreaction)
        XCTAssertTrue(r.causes.contains { $0.title == "Heavy trading" })
        XCTAssertTrue(r.causes.contains { $0.title == "Sector & market move" }, "amplified moves mention the market")
    }

    func testJustified() {
        let r = RuleBasedDetective.investigate(makeCase(makeFacts(day: -5, typical: 2, volume: 2, fromHigh: -30, character: .stockSpecific),
                                                        news: [scored("Acme misses", sentiment: -1, relevance: 0.9, catalysts: ["earnings"])]))
        XCTAssertEqual(r.verdict, .justified)
        XCTAssertEqual(r.confidence, 65)
        XCTAssertEqual(r.watchNext.count, 3, "capped at 3")
        XCTAssertTrue(r.watchNext[0].contains("estimate revisions"))
    }

    func testWatchListPerCatalyst() {
        func watch(_ tag: String) -> String {
            RuleBasedDetective.investigate(makeCase(makeFacts(day: -5, typical: 2, character: .stockSpecific),
                                                    news: [scored("Acme falls", sentiment: -1, relevance: 0.9, catalysts: [tag])])).watchNext[0]
        }
        XCTAssertTrue(watch("guidance").contains("estimate"))
        XCTAssertTrue(watch("legal/regulatory").contains("regulators"))
        XCTAssertTrue(watch("macro").contains("macro"))
        XCTAssertTrue(watch("product").contains("Acme falls"))
        let noTag = RuleBasedDetective.investigate(makeCase(makeFacts(day: 1, character: .noise)))
        XCTAssertTrue(noTag.watchNext.last!.contains("XLK"))
    }
}

final class ReportValidatorTests2: XCTestCase {
    func testPercentages() {
        XCTAssertEqual(ReportValidator.percentages(in: "up 5%, down 1.25 % and 300"), [5, 1.25])
        XCTAssertEqual(ReportValidator.percentages(in: "no numbers"), [])
    }

    func testDirectionChecks() {
        let up = makeFacts(day: 5, character: .stockSpecific)
        XCTAssertTrue(ReportValidator.contradicts("Shares fall on news", facts: up))
        XCTAssertFalse(ReportValidator.contradicts("Shares rise on news", facts: up))
        XCTAssertFalse(ReportValidator.contradicts("Shares rebound after a fall", facts: up), "mixed wording is allowed")
        let down = makeFacts(day: -5, character: .stockSpecific)
        XCTAssertTrue(ReportValidator.contradicts("Shares surge", facts: down))
        XCTAssertFalse(ReportValidator.contradicts("Shares slide", facts: down))
        XCTAssertFalse(ReportValidator.contradicts("Shares fall", facts: makeFacts(day: 0.2)), "tiny moves aren't judged on direction")
    }

    func testNumberChecks() {
        let f = makeFacts(day: 5.02, week: -9.01, character: .stockSpecific)
        XCTAssertFalse(ReportValidator.contradicts("up 5%", facts: f))
        XCTAssertFalse(ReportValidator.contradicts("rebounds after a 9% slide this week", facts: f))
        XCTAssertTrue(ReportValidator.contradicts("up 7.4%", facts: f))
    }
}
