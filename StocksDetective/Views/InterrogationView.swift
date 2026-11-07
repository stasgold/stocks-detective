import SwiftUI
import DetectiveKit

struct InterrogationView: View {
    @State private var interrogation: Interrogation
    @State private var draft = ""
    @Environment(\.dismiss) private var dismiss
    let symbol: String

    init(file: CaseFile, report: InvestigationReport?, provider: any MarketDataProvider) {
        _interrogation = State(initialValue: Interrogation(file: file, report: report, provider: provider))
        symbol = file.symbol
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text("Ask follow-up questions about \(symbol). The detective can pull prices and headlines for other tickers to compare.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if interrogation.messages.isEmpty {
                            ForEach(interrogation.suggestions, id: \.self) { s in
                                Button(s) { send(s) }
                                    .buttonStyle(.bordered)
                            }
                        }
                        ForEach(interrogation.messages) { m in
                            Bubble(message: m).id(m.id)
                        }
                        if interrogation.isThinking {
                            Label("Investigating…", systemImage: "apple.intelligence")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .symbolEffect(.pulse)
                                .id("thinking")
                        }
                    }
                    .padding()
                }
                .onChange(of: interrogation.messages.count) {
                    withAnimation { proxy.scrollTo(interrogation.messages.last?.id, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField("Ask the detective…", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .onSubmit { send(draft) }
                    Button("Send", systemImage: "arrow.up.circle.fill") { send(draft) }
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || interrogation.isThinking)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Interrogation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func send(_ text: String) {
        draft = ""
        Task { await interrogation.ask(text) }
    }
}

private struct Bubble: View {
    let message: ChatMessage
    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .padding(12)
                .foregroundStyle(message.role == .user ? Color.black : Color.primary)
                .background(message.role == .user ? Theme.accent : Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
            if message.role == .detective { Spacer(minLength: 40) }
        }
    }
}
