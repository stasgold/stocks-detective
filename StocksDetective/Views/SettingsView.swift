import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @AppStorage(BackgroundInvestigator.alertsKey) private var alertsEnabled = false
    @AppStorage(BackgroundInvestigator.sensitivityKey) private var sensitivity = 2.0
    @State private var confirmReset = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Detective") {
                    switch model.ai.status {
                    case .available:
                        Label("Apple Intelligence is on. Investigations run privately on this iPhone.", systemImage: "apple.intelligence")
                    case .unavailable(let reason):
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Alert me about unusual moves", isOn: $alertsEnabled)
                        .onChange(of: alertsEnabled) { _, on in
                            guard on else { return }
                            Task {
                                alertsEnabled = await BackgroundInvestigator.requestPermission()
                                BackgroundInvestigator.schedule()
                            }
                        }
                    if alertsEnabled {
                        VStack(alignment: .leading) {
                            Text("Alert when a move is \(String(format: "%.1f", sensitivity))× a normal day")
                            Slider(value: $sensitivity, in: 1.5...4, step: 0.5)
                        }
                    }
                } header: {
                    Text("Continuous investigation")
                } footer: {
                    Text("While the app is closed, the detective checks your portfolio in the background and notifies you only about stock-specific moves, not ordinary market swings.")
                }

                Section {
                    Toggle("Demo data", isOn: $model.demoMode)
                } footer: {
                    Text("Use built-in sample prices and headlines instead of live market data. Live data comes from Yahoo Finance and Google News and may be delayed.")
                }

                Section {
                    Button("Delete all holdings", role: .destructive) { confirmReset = true }
                }

                Section("About") {
                    Text("Stocks Detective doesn't just tell you a stock is down 3%. It explains what happened, which news caused it, whether the move is justified, and what to watch next.")
                        .font(.subheadline)
                    Text("Not investment advice.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete all holdings?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) {
                    // Delete one by one (not a batch delete) so open lists update safely.
                    for h in (try? context.fetch(FetchDescriptor<Holding>())) ?? [] {
                        context.delete(h)
                    }
                    try? context.save()
                    model.clearCaches()
                }
            }
        }
    }
}
