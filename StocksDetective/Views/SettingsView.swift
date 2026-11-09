import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @AppStorage(BackgroundInvestigator.alertsKey) private var alertsEnabled = false
    @AppStorage(BackgroundInvestigator.sensitivityKey) private var sensitivity = 2.0
    @State private var confirmReset = false
    @AppStorage(ModelRouter.engineKey) private var engine: AIEngine = .onDevice

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                if ModelRouter.cloudState == .notInThisBuild {
                    Section("Apple Intelligence") {
                        switch model.ai.status {
                        case .available:
                            Label("Runs entirely on this iPhone. Works offline.", systemImage: "iphone")
                        case .unavailable(let reason):
                            Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        }
                    }
                } else {
                Section {
                    Picker("Model", selection: $engine) {
                        ForEach(AIEngine.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: engine) { model.clearReports() }

                    switch engine {
                    case .onDevice:
                        switch model.ai.status {
                        case .available:
                            Label("Runs entirely on this iPhone. Works offline.", systemImage: "iphone")
                        case .unavailable(let reason):
                            Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        }
                    case .privateCloud:
                        cloudStatus
                    }
                } header: {
                    Text("Apple Intelligence")
                } footer: {
                    Text(engine == .onDevice
                         ? "On-device: private, offline, fast; reads the top 5 headlines per stock."
                         : "Private Cloud: Apple's larger model on Private Cloud Compute. Reads up to 10 headlines per stock and your whole portfolio for the briefing. Needs internet; your data isn't stored or visible to Apple. Has a daily limit tied to your iCloud account. Falls back to on-device automatically.")
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
                    // One by one (not a batch delete) so open lists update safely.
                    HoldingsEditor.deleteAll(in: context, model: model)
                }
            }
        }
    }

    @ViewBuilder private var cloudStatus: some View {
        switch ModelRouter.cloudState {
        case .ready:
            Label("Private Cloud is ready.", systemImage: "lock.icloud")
        case .nearLimit:
            Label("Close to today's Private Cloud limit.", systemImage: "gauge.with.needle")
                .foregroundStyle(.orange)
            Button("Get a higher limit") { ModelRouter.showLimitIncrease() }
        case .limitReached:
            Label("Today's Private Cloud limit is used up. Using on-device until it resets.", systemImage: "gauge.with.needle.fill")
                .foregroundStyle(.orange)
            Button("Get a higher limit") { ModelRouter.showLimitIncrease() }
        case .unavailable:
            Label("Private Cloud isn't available right now (needs an Apple Intelligence iPhone with it turned on). Using on-device.", systemImage: "exclamationmark.icloud")
                .foregroundStyle(.secondary)
        case .needsNewerIOS:
            Label("Private Cloud needs iOS 27 or later. Using on-device.", systemImage: "exclamationmark.icloud")
                .foregroundStyle(.secondary)
        case .notInThisBuild:
            Label("Private Cloud isn't included in this build. Using on-device.", systemImage: "exclamationmark.icloud")
                .foregroundStyle(.secondary)
        }
    }
}
