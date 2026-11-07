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
    static func loadHoldings() -> [HoldingInput] {
        let context = ModelContext(SharedStore.container)
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

        for h in holdings {
            guard let file = try? await builder.buildCase(for: h) else { continue }
            let f = file.facts
            guard abs(f.zScore) >= threshold, f.character != .marketDriven, f.character != .noise else { continue }
            // One alert per symbol per day.
            let key = "alerted-\(h.symbol)-\(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)"
            guard !defaults.bool(forKey: key) else { continue }
            defaults.set(true, forKey: key)
            let report = await investigate(file)
            await notify(report: report, facts: f)
        }
    }

    @MainActor
    static func investigate(_ file: CaseFile) async -> InvestigationReport {
        await DetectiveAI().investigate(file)
    }

    static func notify(report: InvestigationReport, facts: MovementFacts) async {
        let content = UNMutableNotificationContent()
        content.title = "\(report.symbol) \(String(format: "%+.1f%%", facts.dayChange)) · \(report.verdict.label)"
        content.body = report.headline + " — tap to open the case."
        content.sound = .default
        content.userInfo = ["symbol": report.symbol]
        let request = UNNotificationRequest(identifier: "case-\(report.symbol)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
