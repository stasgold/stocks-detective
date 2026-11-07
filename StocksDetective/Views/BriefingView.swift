import SwiftUI
import SwiftData
import DetectiveKit

/// The daily "morning meeting" with your analyst: one story for the whole portfolio.
struct BriefingView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Holding.addedAt) private var allHoldings: [Holding]
    private var holdings: [Holding] { allHoldings.filter { !$0.isDeleted } }

    private var inputs: [HoldingInput] { holdings.map(\.input) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if holdings.isEmpty {
                        ContentUnavailableView("No portfolio yet", systemImage: "newspaper",
                                               description: Text("Add holdings on the Portfolio tab to get a daily briefing."))
                    } else {
                        briefingCard
                        contributorsCard
                        Disclaimer()
                    }
                }
                .padding()
            }
            .navigationDestination(for: String.self) { CaseDetailView(symbol: $0) }
            .navigationTitle("Daily Briefing")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Rewrite", systemImage: "arrow.clockwise") {
                        Task { await model.writeBriefing(inputs) }
                    }
                    .disabled(model.isBriefing || holdings.isEmpty)
                }
            }
            .task(id: holdings.count) {
                if model.briefing == nil, !holdings.isEmpty { await model.writeBriefing(inputs) }
            }
        }
    }

    @ViewBuilder private var briefingCard: some View {
        Card(title: "Today's story", systemImage: "text.book.closed.fill") {
            if let b = model.briefing {
                Text(b.headline).font(.title2.weight(.bold))
                Text(b.summary)
                if !b.keyFindings.isEmpty {
                    Divider()
                    Text("Key findings").font(.headline)
                    ForEach(b.keyFindings, id: \.self) { Label($0, systemImage: "magnifyingglass").font(.subheadline) }
                }
                if !b.watchNext.isEmpty {
                    Divider()
                    Text("Watch next").font(.headline)
                    ForEach(b.watchNext, id: \.self) { Label($0, systemImage: "binoculars").font(.subheadline) }
                }
                HStack {
                    AuthorBadge(author: b.author)
                    Spacer()
                    Text(b.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    ProgressView()
                    Text("Your analyst is writing today's briefing…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var contributorsCard: some View {
        let snap = model.snapshot(for: inputs)
        let maxPnL = snap.lines.map { abs($0.dayPnL) }.max() ?? 1
        return Card(title: "Who moved your portfolio", systemImage: "chart.bar.fill") {
            ForEach(snap.topContributors) { line in
                NavigationLink(value: line.symbol) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(line.symbol).font(.headline)
                            Text(line.dayChange.signedPercent).font(.caption.monospacedDigit()).foregroundStyle(Theme.change(line.dayChange))
                            Spacer()
                            Text(line.dayPnL.signedCurrency).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.change(line.dayPnL))
                        }
                        GeometryReader { g in
                            Capsule().fill(Theme.change(line.dayPnL).opacity(0.7))
                                .frame(width: max(4, g.size.width * abs(line.dayPnL) / max(maxPnL, 0.01)))
                        }
                        .frame(height: 6)
                        if let r = model.reports[line.symbol] {
                            Text(r.headline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
