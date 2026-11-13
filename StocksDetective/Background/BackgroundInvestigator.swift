import Foundation
import BackgroundTasks
import SwiftData
import UserNotifications
import DetectiveKit

/// Keeps investigating while the app is closed: refreshes the portfolio periodically and
/// sends a notification when a holding makes an unusual, stock-specific move.
enum BackgroundInvestigator {
    static let taskID = "com.stocksdetective.app.refresh"
    static let alertsKey = "alertsEnabled"
    static let sensitivityKey = "alertSensitivity" // z-score threshold

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    @MainActor
    static func loadHoldings(from container: ModelContainer = SharedStore.container) -> [HoldingInput] {
        let context = ModelContext(container)
        return ((try? context.fetch(FetchDescriptor<Holding>())) ?? []).map(\.input)
    }

    static func run() async {
        schedule() // keep the investigation going
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: alertsKey) else { return }
        let threshold = defaults.object(forKey: sensitivityKey) as? Double ?? 2.0
        let holdings = await loadHoldings()
        let provider: any MarketDataProvider = defaults.bool(forKey: AppModel.demoKey) ? DemoMarketData() : YahooMarketData()
        let builder = CaseBuilder(provider: provider)

        for file in await casesToAlert(holdings, builder: builder, threshold: threshold, defaults: defaults) {
            let report = await investigate(file)
            await notify(report: report, facts: file.facts)
        }
    }

    /// Unusual, stock-specific moves (market-wide swings and normal noise are skipped).
    static func shouldAlert(_ f: MovementFacts, threshold: Double) -> Bool {
        abs(f.zScore) >= threshold && f.character != .marketDriven && f.character != .noise
    }

    /// Key that limits alerts to one per symbol per day.
    static func alertKey(symbol: String, on date: Date = Date()) -> String {
        "alerted-\(symbol)-\(Calendar.current.startOfDay(for: date).timeIntervalSince1970)"
    }

    /// Cases worth a notification right now; marks each as alerted for today.
    static func casesToAlert(_ holdings: [HoldingInput], builder: CaseBuilder, threshold: Double,
                             defaults: UserDefaults, now: Date = Date()) async -> [CaseFile] {
        var out: [CaseFile] = []
        for h in holdings {
            guard let file = try? await builder.buildCase(for: h), shouldAlert(file.facts, threshold: threshold) else { continue }
            let key = alertKey(symbol: h.symbol, on: now)
            guard !defaults.bool(forKey: key) else { continue }
            defaults.set(true, forKey: key)
            out.append(file)
        }
        return out
    }

    static func notificationContent(report: InvestigationReport, facts: MovementFacts) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(report.symbol) \(NumberText.percent(facts.dayChange, signed: true)) · \(report.verdict.label)"
        content.body = String(localized: "\(report.headline) — tap to open the case.")
        content.sound = .default
        content.userInfo = ["symbol": report.symbol]
        return content
    }

    @MainActor
    static func investigate(_ file: CaseFile) async -> InvestigationReport {
        await DetectiveAI().investigate(file)
    }

    static func notify(report: InvestigationReport, facts: MovementFacts) async {
        let content = notificationContent(report: report, facts: facts)
        let request = UNNotificationRequest(identifier: "case-\(report.symbol)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
