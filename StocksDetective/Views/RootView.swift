import SwiftUI
import SwiftData

enum AppTab: String {
    case portfolio, briefing, settings
}

/// Launch arguments used by the automated Simulator smoke test (and handy for debugging):
///   -seedDemoPortfolio YES   load the demo holdings
///   -openCase NVDA           open a case file
///   -openTab briefing|settings|import
enum LaunchOptions {
    static var seedDemo: Bool { UserDefaults.standard.bool(forKey: "seedDemoPortfolio") }
    static var openCase: String? { UserDefaults.standard.string(forKey: "openCase") }
    static var openTab: String? { UserDefaults.standard.string(forKey: "openTab") }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @State private var tab: AppTab = AppTab(rawValue: LaunchOptions.openTab ?? "") ?? .portfolio

    var body: some View {
        TabView(selection: $tab) {
            Tab("Portfolio", systemImage: "briefcase.fill", value: AppTab.portfolio) {
                PortfolioView()
            }
            Tab("Briefing", systemImage: "newspaper.fill", value: AppTab.briefing) {
                BriefingView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
        .onAppear(perform: seedIfRequested)
    }

    private func seedIfRequested() {
        guard LaunchOptions.seedDemo else { return }
        HoldingsEditor.seedDemo(in: context, model: model)
    }
}
