import XCTest
import DetectiveKit
@testable import StocksDetective

@MainActor
final class AppModelTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppModel.demoKey)
    }

    func testInitReadsDemoModeAndSwitchingResetsData() async {
        let model = makeModel(demo: true)
        XCTAssertTrue(model.demoMode)
        await model.refresh(demoInputs)
        XCTAssertEqual(model.cases.count, 5)
        let gen = model.generation
        model.demoMode = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: AppModel.demoKey), "persisted")
        XCTAssertTrue(model.cases.isEmpty, "switching source clears data")
        XCTAssertEqual(model.generation, gen + 1)
        XCTAssertFalse(makeModel(demo: false).demoMode)
    }

    func testRefreshBuildsCasesReportsAndFailures() async {
        let model = makeModel(failing: ["BAD"])
        let inputs = demoInputs + [HoldingInput(symbol: "BAD", sector: .technology, shares: 1)]
        await model.refresh(inputs)
        XCTAssertEqual(model.cases.count, 5)
        XCTAssertEqual(model.reports.count, 5)
        XCTAssertNotNil(model.failures["BAD"])
        XCTAssertNil(model.cases["BAD"])
        XCTAssertFalse(model.isRefreshing)
        XCTAssertNotNil(model.lastRefresh)
        await model.refresh([])
        XCTAssertEqual(model.cases.count, 5, "empty refresh is a no-op")
    }

    func testRefreshQueuesHoldingsAddedMidway() async {
        let model = makeModel()
        let later = Task { await model.refresh(Array(demoInputs.prefix(2)) + [HoldingInput(symbol: "JPM", sector: .financials, shares: 1)]) }
        await model.refresh(Array(demoInputs.prefix(2)))
        await later.value
        XCTAssertNotNil(model.cases["JPM"], "holding added during a refresh is fetched afterwards")
    }

    func testResultsFromOldDataSourceAreDropped() async {
        let model = makeModel(delay: 0.5)
        let run = Task { await model.refresh(demoInputs) }
        try? await Task.sleep(nanoseconds: 100_000_000) // refresh is now waiting on the slow provider
        XCTAssertTrue(model.isRefreshing)
        model.clearCaches()
        await run.value
        XCTAssertFalse(model.isRefreshing)
        XCTAssertTrue(model.cases.isEmpty, "results from the old data source are ignored")
    }

    func testSnapshotInvestigateBriefingClearRemove() async throws {
        try XCTSkipIf(ModelRouter.anyAvailable, "Exercises the no-AI path")
        let model = makeModel()
        await model.refresh(demoInputs)
        XCTAssertEqual(model.snapshot(for: demoInputs).lines.count, 5)
        await model.investigate("AAPL")
        XCTAssertEqual(model.reports["AAPL"]?.author, .ruleBased)
        await model.investigate("NOPE")
        XCTAssertNil(model.reports["NOPE"])
        await model.writeBriefing(demoInputs)
        XCTAssertEqual(model.briefing?.author, .ruleBased)
        XCTAssertFalse(model.isBriefing)
        model.clearReports()
        XCTAssertNil(model.briefing)
        XCTAssertEqual(model.reports.count, 5)
        model.remove("AAPL")
        XCTAssertNil(model.cases["AAPL"]); XCTAssertNil(model.reports["AAPL"]); XCTAssertNil(model.failures["AAPL"])
        model.clearCaches()
        XCTAssertTrue(model.cases.isEmpty && model.reports.isEmpty && model.failures.isEmpty)
    }

    func testWriteBriefingRefreshesFirstWhenEmpty() async throws {
        try XCTSkipIf(ModelRouter.anyAvailable, "Exercises the no-AI path")
        let model = makeModel()
        await model.writeBriefing(demoInputs)
        XCTAssertEqual(model.cases.count, 5)
        XCTAssertNotNil(model.briefing)
    }
}

@MainActor
final class HoldingTests: XCTestCase {
    func testHolding() {
        let h = Holding(symbol: "aapl", name: "Apple", shares: 3, costBasis: 100, sector: .technology)
        XCTAssertEqual(h.symbol, "AAPL")
        XCTAssertEqual(h.sector, .technology)
        h.sector = .energy
        XCTAssertEqual(h.sectorRaw, "energy")
        h.sectorRaw = "garbage"
        XCTAssertEqual(h.sector, .broadMarket, "unknown stored value falls back")
        let input = h.input
        XCTAssertEqual(input.symbol, "AAPL"); XCTAssertEqual(input.shares, 3); XCTAssertEqual(input.costBasis, 100)
        XCTAssertEqual(DemoPortfolio.holdings.count, 5)
        XCTAssertNotNil(SharedStore.container)
    }
}

@MainActor
final class HoldingsEditorTests: XCTestCase {
    override func tearDown() { UserDefaults.standard.removeObject(forKey: AppModel.demoKey) }

    func fetch(_ c: ModelContainer) -> [Holding] {
        ((try? c.mainContext.fetch(FetchDescriptor<Holding>())) ?? []).sorted { $0.symbol < $1.symbol }
    }

    func testParseAmount() {
        XCTAssertEqual(HoldingsEditor.parseAmount("12.5"), 12.5)
        XCTAssertEqual(HoldingsEditor.parseAmount(" 12,5 "), 12.5)
        XCTAssertNil(HoldingsEditor.parseAmount("0"))
        XCTAssertNil(HoldingsEditor.parseAmount("-3"))
        XCTAssertNil(HoldingsEditor.parseAmount(""))
        XCTAssertNil(HoldingsEditor.parseAmount("abc"))
    }

    func testUpsert() throws {
        let c = try makeContainer()
        HoldingsEditor.upsert(symbol: "aapl", name: "Apple", shares: 1, costBasis: nil, sector: .technology, existing: [], in: c.mainContext)
        XCTAssertEqual(fetch(c).map(\.symbol), ["AAPL"])
        HoldingsEditor.upsert(symbol: "AAPL", name: "Apple", shares: 7, costBasis: 150, sector: .broadMarket, existing: fetch(c), in: c.mainContext)
        let all = fetch(c)
        XCTAssertEqual(all.count, 1, "updated, not duplicated")
        XCTAssertEqual(all[0].shares, 7); XCTAssertEqual(all[0].costBasis, 150); XCTAssertEqual(all[0].sector, .broadMarket)
    }

    func testImportAddsUpdatesAndReplaces() throws {
        let c = try makeContainer()
        let model = makeModel(demo: true)
        HoldingsEditor.upsert(symbol: "AAPL", name: "Apple", shares: 1, costBasis: 10, sector: .technology, existing: [], in: c.mainContext)
        HoldingsEditor.upsert(symbol: "MSFT", name: "Microsoft", shares: 1, costBasis: nil, sector: .technology, existing: fetch(c), in: c.mainContext)
        let rows = PortfolioImporter.parse("AAPL 5\nVOO 238").rows

        HoldingsEditor.importRows(rows, replace: false, existing: fetch(c), in: c.mainContext, model: model)
        XCTAssertEqual(fetch(c).map(\.symbol), ["AAPL", "MSFT", "VOO"])
        XCTAssertEqual(fetch(c).first { $0.symbol == "AAPL" }?.shares, 5)
        XCTAssertEqual(fetch(c).first { $0.symbol == "AAPL" }?.costBasis, 10, "cost basis kept")
        XCTAssertEqual(fetch(c).first { $0.symbol == "VOO" }?.name, "VOO", "name filled in later")
        XCTAssertEqual(fetch(c).first { $0.symbol == "VOO" }?.sector, .broadMarket)
        XCTAssertFalse(model.demoMode, "importing real holdings switches to live data")

        HoldingsEditor.importRows(rows, replace: true, existing: fetch(c), in: c.mainContext, model: model)
        XCTAssertEqual(fetch(c).map(\.symbol), ["AAPL", "VOO"], "MSFT removed when replacing")
    }

    func testSeedDemo() throws {
        let c = try makeContainer()
        let model = makeModel(demo: false)
        HoldingsEditor.seedDemo(in: c.mainContext, model: model)
        XCTAssertEqual(fetch(c).count, 5)
        XCTAssertTrue(model.demoMode)
        HoldingsEditor.seedDemo(in: c.mainContext, model: model)
        XCTAssertEqual(fetch(c).count, 5, "doesn't seed a non-empty portfolio")
    }

    func testFillInNamesAndSortBySurprise() async throws {
        let c = try makeContainer()
        let rows = PortfolioImporter.parse("MSFT 1\nNVDA 1\nZZZ 1").rows
        HoldingsEditor.importRows(rows, replace: false, existing: [], in: c.mainContext, model: makeModel())
        let cases = ["MSFT": try await demoCase("MSFT"), "NVDA": try await demoCase("NVDA")]
        HoldingsEditor.fillInNames(fetch(c), cases: cases)
        XCTAssertEqual(fetch(c).map(\.name), ["Microsoft Corporation", "NVIDIA Corporation", "ZZZ"])
        let sorted = HoldingsEditor.sortedBySurprise(fetch(c), cases: cases).map(\.symbol)
        XCTAssertEqual(sorted.first, "NVDA", "biggest surprise first")
        XCTAssertEqual(sorted.last, "ZZZ", "no data last")
    }

    func testDeleteAndDeleteAll() async throws {
        let c = try makeContainer()
        let model = makeModel()
        HoldingsEditor.seedDemo(in: c.mainContext, model: model)
        await model.refresh(fetch(c).map(\.input))
        HoldingsEditor.delete(fetch(c).filter { $0.symbol == "AAPL" }, in: c.mainContext, model: model)
        XCTAssertFalse(fetch(c).contains { $0.symbol == "AAPL" })
        XCTAssertNil(model.cases["AAPL"])
        HoldingsEditor.deleteAll(in: c.mainContext, model: model)
        XCTAssertTrue(fetch(c).isEmpty)
        XCTAssertTrue(model.cases.isEmpty)
    }
}
