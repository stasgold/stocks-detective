import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Portfolio", systemImage: "briefcase.fill") {
                PortfolioView()
            }
            Tab("Briefing", systemImage: "newspaper.fill") {
                BriefingView()
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
    }
}
