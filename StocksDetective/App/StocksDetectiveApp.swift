import SwiftUI
import SwiftData

@main
struct StocksDetectiveApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .onAppear { model.ai.prewarm() }
        }
        .modelContainer(SharedStore.container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundInvestigator.schedule() }
        }
        .backgroundTask(.appRefresh(BackgroundInvestigator.taskID)) {
            await BackgroundInvestigator.run()
        }
    }
}

enum SharedStore {
    static let container: ModelContainer = {
        do {
            // UI tests start from a clean, throwaway store.
            let inMemory = UserDefaults.standard.bool(forKey: "inMemoryStore")
            return try ModelContainer(for: Holding.self, configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
        } catch {
            fatalError("Could not open the portfolio store: \(error)")
        }
    }()
}
