import Foundation
import Observation
import DetectiveKit

@MainActor
@Observable
final class AppModel {
    var cases: [String: CaseFile] = [:]
    var reports: [String: InvestigationReport] = [:]
    var failures: [String: String] = [:]
    var investigating: Set<String> = []
    var briefing: PortfolioBriefing?
    var isBriefing = false
    var isRefreshing = false
    var lastRefresh: Date?
    /// Bumped whenever cached data is thrown away (data source switched, portfolio reset),
    /// so screens know to fetch again and late results from the old source are ignored.
    private(set) var generation = 0
    private var refreshingGeneration: Int?
    private var queuedRefresh: [HoldingInput]?

    var demoMode: Bool {
        didSet {
            UserDefaults.standard.set(demoMode, forKey: Self.demoKey)
            rebuildProvider()
        }
    }

    let ai = DetectiveAI()
    private(set) var provider: any MarketDataProvider
    private var builder: CaseBuilder

    nonisolated static let demoKey = "demoMode"

    init() {
        let demo = UserDefaults.standard.bool(forKey: Self.demoKey)
        demoMode = demo
        let p: any MarketDataProvider = demo ? DemoMarketData() : YahooMarketData()
        provider = p
        builder = CaseBuilder(provider: p)
    }

    private func rebuildProvider() {
        provider = demoMode ? DemoMarketData() : YahooMarketData()
        builder = CaseBuilder(provider: provider)
        clearCaches()
    }

    func clearCaches() {
        generation += 1
        cases = [:]
        reports = [:]
        failures = [:]
        briefing = nil
    }

    func snapshot(for holdings: [HoldingInput]) -> PortfolioSnapshot {
        PortfolioSnapshot(cases: holdings.compactMap { cases[$0.symbol] }, holdings: holdings)
    }

    /// Gather fresh evidence for every holding, write instant rule-based reports,
    /// then let Apple Intelligence re-investigate the most suspicious moves.
    func refresh(_ holdings: [HoldingInput]) async {
        guard !holdings.isEmpty else { return }
        let gen = generation
        if refreshingGeneration == gen {
            // Already fetching from this source; run again afterwards with the latest list
            // so holdings added mid-refresh (e.g. by an import) aren't skipped.
            queuedRefresh = holdings
            return
        }
        refreshingGeneration = gen
        isRefreshing = true
        defer {
            if refreshingGeneration == gen {
                refreshingGeneration = nil
                isRefreshing = false
            }
        }

        // One independent task per holding, collected in order. (A task group here crashed
        // Release builds: the group was freed while fetches were still finishing.)
        let builder = self.builder
        let jobs: [(String, Task<CaseFile, Error>)] = holdings.map { h in
            (h.symbol, Task.detached(priority: .userInitiated) { try await builder.buildCase(for: h) })
        }
        for (symbol, job) in jobs {
            let outcome = await job.result
            guard gen == generation else { return } // data source changed meanwhile
            do {
                let file = try outcome.get()
                cases[symbol] = file
                failures[symbol] = nil
                if reports[symbol]?.author.isAI != true || reports[symbol].map({ Date().timeIntervalSince($0.createdAt) > 1800 }) == true {
                    reports[symbol] = RuleBasedDetective.investigate(file)
                }
            } catch {
                failures[symbol] = error.localizedDescription
            }
        }
        lastRefresh = Date()

        // On-device model runs one request at a time; investigate the biggest surprises first.
        let suspects = holdings.compactMap { cases[$0.symbol] }
            .filter { $0.facts.isSignificant }
            .sorted { abs($0.facts.zScore) > abs($1.facts.zScore) }
            .prefix(3)
        for file in suspects where reports[file.symbol]?.author.isAI != true {
            guard gen == generation else { return }
            await investigate(file.symbol)
        }

        // Holdings added while we were busy (e.g. by an import): fetch the ones still missing.
        if let queued = queuedRefresh, gen == generation {
            queuedRefresh = nil
            if queued.contains(where: { cases[$0.symbol] == nil && failures[$0.symbol] == nil }) {
                refreshingGeneration = nil
                isRefreshing = false
                await refresh(queued)
            }
        }
    }

    func investigate(_ symbol: String) async {
        guard let file = cases[symbol], !investigating.contains(symbol) else { return }
        investigating.insert(symbol)
        defer { investigating.remove(symbol) }
        reports[symbol] = await ai.investigate(file)
    }

    func writeBriefing(_ holdings: [HoldingInput]) async {
        guard !isBriefing else { return }
        if cases.isEmpty { await refresh(holdings) }
        isBriefing = true
        defer { isBriefing = false }
        let files = holdings.compactMap { cases[$0.symbol] }
        briefing = await ai.brief(snapshot: snapshot(for: holdings), cases: files, reports: reports)
    }

    /// Drop AI write-ups (e.g. after switching model) so cases are re-investigated; keep the data.
    func clearReports() {
        for (symbol, file) in cases { reports[symbol] = RuleBasedDetective.investigate(file) }
        briefing = nil
    }

    func remove(_ symbol: String) {
        cases[symbol] = nil
        reports[symbol] = nil
        failures[symbol] = nil
    }
}
