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
        guard !isRefreshing, !holdings.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // One independent task per holding, collected in order. (A task group here crashed
        // Release builds: the group was freed while fetches were still finishing.)
        let builder = self.builder
        let jobs: [(String, Task<CaseFile, Error>)] = holdings.map { h in
            (h.symbol, Task.detached(priority: .userInitiated) { try await builder.buildCase(for: h) })
        }
        for (symbol, job) in jobs {
            do {
                let file = try await job.value
                cases[symbol] = file
                failures[symbol] = nil
                if reports[symbol]?.author != .appleIntelligence || reports[symbol].map({ Date().timeIntervalSince($0.createdAt) > 1800 }) == true {
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
        for file in suspects where reports[file.symbol]?.author != .appleIntelligence {
            await investigate(file.symbol)
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

    func remove(_ symbol: String) {
        cases[symbol] = nil
        reports[symbol] = nil
        failures[symbol] = nil
    }
}
