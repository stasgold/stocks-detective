import XCTest
import SwiftData
import SwiftUI
import UserNotifications
import DetectiveKit
@testable import StocksDetective

@MainActor
final class ModelRouterTests: XCTestCase {
    override func tearDown() { UserDefaults.standard.removeObject(forKey: ModelRouter.engineKey) }

    func testEngineAndPreference() {
        XCTAssertEqual(AIEngine.allCases.map(\.label), ["On-device", "Private Cloud"])
        XCTAssertEqual(AIEngine.onDevice.id, "onDevice")
        UserDefaults.standard.removeObject(forKey: ModelRouter.engineKey)
        XCTAssertEqual(ModelRouter.preferred, .onDevice, "default")
        UserDefaults.standard.set("privateCloud", forKey: ModelRouter.engineKey)
        XCTAssertEqual(ModelRouter.preferred, .privateCloud)
        UserDefaults.standard.set("nonsense", forKey: ModelRouter.engineKey)
        XCTAssertEqual(ModelRouter.preferred, .onDevice)
    }

    func testCloudStateAndAvailability() {
        #if !PCC_SDK
        XCTAssertEqual(ModelRouter.cloudState, .notInThisBuild)
        XCTAssertFalse(ModelRouter.cloudUsable)
        XCTAssertNil(ModelRouter.cloudSession(instructions: "x", tools: []))
        #endif
        ModelRouter.showLimitIncrease() // no-op without a cloud limit
        XCTAssertEqual(ModelRouter.anyAvailable, ModelRouter.onDeviceAvailable || (ModelRouter.preferred == .privateCloud && ModelRouter.cloudUsable))
    }

    func testSessionAndRunWithoutAI() async throws {
        ModelRouter.disabledForTesting = true; defer { ModelRouter.disabledForTesting = false }
        XCTAssertNil(ModelRouter.session(instructions: "x"))
        let result = await ModelRouter.run(instructions: "x") { _, _ in 1 }
        XCTAssertNil(result)
    }
}

@MainActor
final class DetectiveAITests: XCTestCase {
    func testStatusMatchesAvailability() {
        let ai = DetectiveAI()
        XCTAssertEqual(ai.status == .available, ModelRouter.onDeviceAvailable)
        if case .unavailable(let reason) = ai.status { XCTAssertFalse(reason.isEmpty) }
        XCTAssertFalse(DetectiveAI.instructions.isEmpty)
        ai.prewarm()
    }

    func testInvestigateAndBriefFallBackWithoutAI() async throws {
        ModelRouter.disabledForTesting = true; defer { ModelRouter.disabledForTesting = false }
        let file = try await demoCase("NVDA")
        let report = await DetectiveAI().investigate(file)
        XCTAssertEqual(report.author, .ruleBased)
        XCTAssertEqual(report, RuleBasedDetective.investigate(file).withDate(report.createdAt))
        let snapshot = PortfolioSnapshot(cases: [file], holdings: [HoldingInput(symbol: "NVDA", sector: .technology, shares: 1)])
        let brief = await DetectiveAI().brief(snapshot: snapshot, cases: [file], reports: ["NVDA": report])
        XCTAssertEqual(brief.author, .ruleBased)
        let empty = await DetectiveAI().brief(snapshot: snapshot, cases: [], reports: [:])
        XCTAssertEqual(empty.author, .ruleBased)
    }

    func testVerdictMapping() {
        XCTAssertEqual(DetectiveAI.verdict(from: .justified), .justified)
        XCTAssertEqual(DetectiveAI.verdict(from: .overreaction), .overreaction)
        XCTAssertEqual(DetectiveAI.verdict(from: .underreaction), .underreaction)
        XCTAssertEqual(DetectiveAI.verdict(from: .unexplained), .unexplained)
        XCTAssertEqual(DetectiveAI.verdict(from: .noise), .noise)
    }

    func testMakeReportKeepsGoodTextAndReplacesContradictions() async throws {
        let file = try await demoCase("NVDA") // up 12.6%
        let fallback = RuleBasedDetective.investigate(file)
        let good = DetectiveAI.makeReport(symbol: "NVDA", headline: "Nvidia surges on capex news", whatHappened: "Shares jumped.",
                                          causes: [(title: "Capex", detail: "d", evidence: "Nvidia jumps"), (title: "Volume", detail: "d", evidence: "")],
                                          verdict: .overreaction, verdictReasoning: "r", watchNext: ["a", "b", "c"], confidence: 70,
                                          facts: file.facts, fallback: fallback, author: .privateCloud)
        XCTAssertEqual(good.headline, "Nvidia surges on capex news")
        XCTAssertEqual(good.causes[0].evidence, "Nvidia jumps"); XCTAssertNil(good.causes[1].evidence, "empty evidence → nil")
        XCTAssertEqual(good.author, .privateCloud); XCTAssertEqual(good.verdict, .overreaction); XCTAssertEqual(good.confidence, 70)
        let bad = DetectiveAI.makeReport(symbol: "NVDA", headline: "Nvidia falls 7.4%", whatHappened: "Shares slumped 3%.", causes: [],
                                         verdict: .justified, verdictReasoning: "r", watchNext: [], confidence: 50,
                                         facts: file.facts, fallback: fallback, author: .appleIntelligence)
        XCTAssertEqual(bad.headline, fallback.headline)
        XCTAssertEqual(bad.whatHappened, fallback.whatHappened)
    }

    func testRuleBasedBriefing() async throws {
        let files = [try await demoCase("NVDA"), try await demoCase("MSFT")]
        let holdings = files.map { HoldingInput(symbol: $0.symbol, sector: .technology, shares: 10) }
        let reports = Dictionary(uniqueKeysWithValues: files.map { ($0.symbol, RuleBasedDetective.investigate($0)) })
        let b = DetectiveAI.ruleBasedBriefing(snapshot: PortfolioSnapshot(cases: files, holdings: holdings), reports: reports)
        XCTAssertTrue(b.headline.contains("NVDA"))
        XCTAssertEqual(b.keyFindings.count, 2)
        XCTAssertEqual(b.author, .ruleBased)
        let none = DetectiveAI.ruleBasedBriefing(snapshot: PortfolioSnapshot(cases: [], holdings: []), reports: [:])
        XCTAssertTrue(none.headline.contains("no single holding"))
    }
}

private extension InvestigationReport {
    func withDate(_ d: Date) -> InvestigationReport {
        InvestigationReport(symbol: symbol, headline: headline, whatHappened: whatHappened, causes: causes, verdict: verdict,
                            verdictReasoning: verdictReasoning, watchNext: watchNext, confidence: confidence, author: author, createdAt: d)
    }
}

@MainActor
final class InterrogationTests: XCTestCase {
    func testToolsAnswerFromMarketData() async throws {
        let prices = PriceHistoryTool(provider: DemoMarketData())
        XCTAssertEqual(prices.name, "getPriceHistory")
        let text = try await prices.history(symbol: "aapl", days: 5)
        XCTAssertTrue(text.hasPrefix("AAPL: last"))
        XCTAssertTrue(text.contains("over 5 days"))
        let one = try await prices.history(symbol: "AAPL", days: 0)
        XCTAssertTrue(one.contains("over 1 days"), "at least one day")
        let news = NewsLookupTool(provider: DemoMarketData())
        XCTAssertEqual(news.name, "getHeadlines")
        let headlines = try await news.headlines(symbol: "aapl")
        XCTAssertEqual(headlines.components(separatedBy: "\n").count, 3)
        let none = try await news.headlines(symbol: "TSLA")
        XCTAssertEqual(none, "No recent headlines found for TSLA.")
    }

    func testAskWithoutAI() async throws {
        ModelRouter.disabledForTesting = true; defer { ModelRouter.disabledForTesting = false }
        let file = try await demoCase("AAPL")
        let i = Interrogation(file: file, report: nil, provider: DemoMarketData())
        XCTAssertNil(i.author)
        XCTAssertTrue(i.suggestions.contains { $0.contains("XLK") })
        await i.ask("   ")
        XCTAssertTrue(i.messages.isEmpty, "blank questions ignored")
        await i.ask("Why did it fall?")
        XCTAssertEqual(i.messages.map(\.role), [.user, .detective])
        XCTAssertTrue(i.messages[1].text.contains("Apple Intelligence"))
        XCTAssertFalse(i.isThinking)
    }
}

@MainActor
final class BackgroundInvestigatorTests: XCTestCase {
    func testShouldAlert() {
        func facts(z: Double, _ c: MoveCharacter) -> MovementFacts {
            MovementFacts(symbol: "A", benchmark: "B", dayChange: z, weekChange: 0, monthChange: 0, benchmarkDayChange: 0,
                          marketDayChange: 0, beta: 1, expectedMove: 0, excessMove: z, typicalDailyMove: 1, zScore: z,
                          volumeRatio: 1, distanceFrom52wHigh: 0, character: c)
        }
        XCTAssertTrue(BackgroundInvestigator.shouldAlert(facts(z: 3, .stockSpecific), threshold: 2))
        XCTAssertTrue(BackgroundInvestigator.shouldAlert(facts(z: -2, .amplified), threshold: 2))
        XCTAssertFalse(BackgroundInvestigator.shouldAlert(facts(z: 1.9, .stockSpecific), threshold: 2))
        XCTAssertFalse(BackgroundInvestigator.shouldAlert(facts(z: 5, .marketDriven), threshold: 2))
        XCTAssertFalse(BackgroundInvestigator.shouldAlert(facts(z: 5, .noise), threshold: 2))
    }

    func testAlertKey() {
        let d = Date()
        XCTAssertEqual(BackgroundInvestigator.alertKey(symbol: "A", on: d), BackgroundInvestigator.alertKey(symbol: "A", on: d.addingTimeInterval(1)))
        XCTAssertNotEqual(BackgroundInvestigator.alertKey(symbol: "A", on: d), BackgroundInvestigator.alertKey(symbol: "A", on: d.addingTimeInterval(86400 * 2)))
        XCTAssertNotEqual(BackgroundInvestigator.alertKey(symbol: "A", on: d), BackgroundInvestigator.alertKey(symbol: "B", on: d))
    }

    func testCasesToAlertOncePerDay() async {
        let defaults = UserDefaults(suiteName: "alerts-test-\(UUID())")!
        let builder = CaseBuilder(provider: DemoMarketData())
        let first = await BackgroundInvestigator.casesToAlert(demoInputs, builder: builder, threshold: 1.5, defaults: defaults)
        XCTAssertTrue(first.contains { $0.symbol == "NVDA" }, "big stock-specific move alerts")
        XCTAssertFalse(first.contains { $0.symbol == "MSFT" }, "market-driven move doesn't")
        let again = await BackgroundInvestigator.casesToAlert(demoInputs, builder: builder, threshold: 1.5, defaults: defaults)
        XCTAssertTrue(again.isEmpty, "one alert per stock per day")
    }

    func testNotificationContent() async throws {
        let file = try await demoCase("NVDA")
        let report = RuleBasedDetective.investigate(file)
        let c = BackgroundInvestigator.notificationContent(report: report, facts: file.facts)
        XCTAssertTrue(c.title.hasPrefix("NVDA +12.6%"))
        XCTAssertTrue(c.title.contains(report.verdict.label))
        XCTAssertTrue(c.body.hasPrefix(report.headline))
        XCTAssertEqual(c.userInfo["symbol"] as? String, "NVDA")
    }

    func testLoadHoldingsScheduleAndRunWhenDisabled() async throws {
        let c = try makeContainer()
        c.mainContext.insert(Holding(symbol: "AAPL", name: "Apple", shares: 2, costBasis: nil, sector: .technology))
        try c.mainContext.save()
        XCTAssertEqual(BackgroundInvestigator.loadHoldings(from: c).map(\.symbol), ["AAPL"])
        BackgroundInvestigator.schedule()
        UserDefaults.standard.set(false, forKey: BackgroundInvestigator.alertsKey)
        await BackgroundInvestigator.run() // alerts off → returns without fetching
        let report = await BackgroundInvestigator.investigate(try await demoCase("AAPL"))
        XCTAssertFalse(report.headline.isEmpty)
    }
}

@MainActor
final class FormattingTests: XCTestCase {
    func testChartLabels() {
        XCTAssertEqual(StockChartView.labelIndices(count: 3), [0, 1, 2])
        let idx = StockChartView.labelIndices(count: 101)
        XCTAssertEqual(idx.count, 4)
        XCTAssertEqual(idx, idx.sorted()); XCTAssertTrue(idx.allSatisfy { (0..<101).contains($0) })
        let d = Date(timeIntervalSince1970: 1_778_000_000)
        for r in ChartRange.allCases { XCTAssertFalse(StockChartView.axisDate(d, range: r).isEmpty, r.rawValue) }
        XCTAssertNotEqual(StockChartView.axisDate(d, range: .day), StockChartView.axisDate(d, range: .all))
        XCTAssertNotEqual(StockChartView.tooltipDate(d, range: .day), StockChartView.tooltipDate(d, range: .month), "intraday shows time")
    }

    func testThemeAndNumberFormatting() {
        XCTAssertEqual(Theme.change(1), Theme.up); XCTAssertEqual(Theme.change(0), Theme.up); XCTAssertEqual(Theme.change(-1), Theme.down)
        XCTAssertEqual(Set(Verdict.allCases.map { Theme.icon(for: $0) }).count, Verdict.allCases.count)
        XCTAssertEqual(Set(Verdict.allCases.map { "\(Theme.color(for: $0))" }).count, Verdict.allCases.count)
        XCTAssertEqual(1.234.signedPercent, "+1.23%")
        XCTAssertEqual((-2.0).signedPercent, "-2.00%")
        XCTAssertTrue(1234.5.currency.contains("1,234.5"))
        XCTAssertTrue(10.0.signedCurrency.hasPrefix("+"))
        XCTAssertFalse((-10.0).signedCurrency.hasPrefix("+"))
    }

    func testLaunchOptions() {
        let d = UserDefaults.standard
        d.set(true, forKey: "seedDemoPortfolio"); d.set("NVDA", forKey: "openCase"); d.set("briefing", forKey: "openTab")
        XCTAssertTrue(LaunchOptions.seedDemo); XCTAssertEqual(LaunchOptions.openCase, "NVDA"); XCTAssertEqual(LaunchOptions.openTab, "briefing")
        for k in ["seedDemoPortfolio", "openCase", "openTab"] { d.removeObject(forKey: k) }
        XCTAssertFalse(LaunchOptions.seedDemo); XCTAssertNil(LaunchOptions.openCase)
        XCTAssertEqual(AppTab(rawValue: "settings"), .settings)
    }
}

/// Runs the real on-device model when the machine has Apple Intelligence (skipped otherwise).
@MainActor
final class LiveAppleIntelligenceTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ModelRouter.onDeviceAvailable, "Apple Intelligence isn't available here")
    }

    func testInvestigationByOnDeviceModel() async throws {
        let file = try await demoCase("NVDA")
        let report = await DetectiveAI().investigate(file)
        XCTAssertEqual(report.author, .appleIntelligence)
        XCTAssertFalse(report.headline.isEmpty)
        XCTAssertFalse(ReportValidator.contradicts(report.headline, facts: file.facts), "validator guarantees a consistent headline")
        XCTAssertLessThanOrEqual(report.watchNext.count, 3)
        print("AI REPORT:", report.verdict.label, "|", report.headline, "|", report.whatHappened)
    }

    func testBriefingByOnDeviceModel() async throws {
        let files = [try await demoCase("NVDA"), try await demoCase("AAPL")]
        let holdings = files.map { HoldingInput(symbol: $0.symbol, sector: .technology, shares: 10) }
        let b = await DetectiveAI().brief(snapshot: PortfolioSnapshot(cases: files, holdings: holdings), cases: files, reports: [:])
        XCTAssertEqual(b.author, .appleIntelligence)
        XCTAssertFalse(b.summary.isEmpty)
        print("AI BRIEFING:", b.headline)
    }

    func testInterrogationAnswers() async throws {
        let i = Interrogation(file: try await demoCase("AAPL"), report: nil, provider: DemoMarketData())
        XCTAssertEqual(i.author, .appleIntelligence)
        await i.ask("In one sentence, was today's move about Apple or the whole market?")
        XCTAssertEqual(i.messages.count, 2)
        XCTAssertFalse(i.messages[1].text.isEmpty)
        print("AI ANSWER:", i.messages[1].text)
    }
}
