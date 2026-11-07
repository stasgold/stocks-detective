import SwiftUI
import Charts
import DetectiveKit

struct CaseDetailView: View {
    let symbol: String
    @Environment(AppModel.self) private var model
    @State private var showingInterrogation = false

    var body: some View {
        ScrollView {
            if let file = model.cases[symbol] {
                VStack(spacing: 16) {
                    header(file)
                    if let report = model.reports[symbol] {
                        verdictCard(report, investigating: model.investigating.contains(symbol))
                        whatHappened(report)
                        MoveBreakdownCard(facts: file.facts)
                        causesCard(report)
                        watchCard(report)
                    }
                    evidenceCard(file)
                    Button {
                        showingInterrogation = true
                    } label: {
                        Label("Interrogate the detective", systemImage: "bubble.left.and.text.bubble.right.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Disclaimer()
                }
                .padding()
            } else if let failure = model.failures[symbol] {
                ContentUnavailableView("Case went cold", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                ProgressView("Gathering evidence…").padding(.top, 80)
            }
        }
        .navigationTitle(symbol)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.ai.isAvailable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Re-investigate", systemImage: "arrow.clockwise") {
                        Task { await model.investigate(symbol) }
                    }
                    .disabled(model.investigating.contains(symbol))
                }
            }
        }
        .task {
            // Opening a case always gets the full AI investigation.
            if model.reports[symbol]?.author != .appleIntelligence, model.ai.isAvailable {
                await model.investigate(symbol)
            }
        }
        .sheet(isPresented: $showingInterrogation) {
            if let file = model.cases[symbol] {
                InterrogationView(file: file, report: model.reports[symbol], provider: model.provider)
            }
        }
    }

    private func header(_ file: CaseFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(file.companyName ?? file.symbol).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(file.series.lastPrice.currency).font(.largeTitle.bold().monospacedDigit())
                ChangePill(value: file.facts.dayChange)
                Spacer()
            }
            PriceChart(points: Array(file.series.points.suffix(90)))
                .frame(height: 160)
            HStack {
                stat("5 days", file.facts.weekChange)
                stat("1 month", file.facts.monthChange)
                stat("vs high", file.facts.distanceFrom52wHigh)
            }
        }
    }

    private func stat(_ label: String, _ v: Double) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(v.signedPercent).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.change(v))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func verdictCard(_ r: InvestigationReport, investigating: Bool) -> some View {
        Card(title: "The verdict", systemImage: "scalemass.fill") {
            HStack {
                VerdictBadge(verdict: r.verdict)
                Spacer()
                ConfidenceGauge(value: r.confidence)
            }
            Text(r.headline).font(.title3.weight(.semibold))
            Text(r.verdictReasoning).font(.body)
            HStack {
                AuthorBadge(author: r.author)
                Spacer()
                if investigating {
                    ProgressView().controlSize(.small)
                    Text("Apple Intelligence is investigating…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.color(for: r.verdict)).frame(width: 4).padding(.vertical, 12)
        }
    }

    private func whatHappened(_ r: InvestigationReport) -> some View {
        Card(title: "What happened", systemImage: "doc.text.magnifyingglass") {
            Text(r.whatHappened)
        }
    }

    private func causesCard(_ r: InvestigationReport) -> some View {
        Card(title: "Suspects", systemImage: "person.crop.rectangle.stack.fill") {
            ForEach(Array(r.causes.enumerated()), id: \.offset) { i, c in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(i + 1)")
                        .font(.headline.monospacedDigit())
                        .frame(width: 28, height: 28)
                        .background(Theme.accent.opacity(0.2), in: .circle)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.title).font(.headline)
                        Text(c.detail).font(.subheadline)
                        if let e = c.evidence {
                            Text("“\(e)”").font(.caption).italic().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func watchCard(_ r: InvestigationReport) -> some View {
        Card(title: "What to watch next", systemImage: "binoculars.fill") {
            ForEach(r.watchNext, id: \.self) { item in
                Label(item, systemImage: "eye")
                    .font(.subheadline)
            }
        }
    }

    private func evidenceCard(_ file: CaseFile) -> some View {
        Card(title: "Evidence locker", systemImage: "archivebox.fill") {
            if file.news.isEmpty {
                Text("No recent headlines found. A big move with no news is itself a clue: it can mean flows, rumors, or news that hasn't hit the wires yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(file.news) { n in
                EvidenceRow(item: n)
                if n.id != file.news.last?.id { Divider() }
            }
        }
    }
}

struct EvidenceRow: View {
    let item: ScoredArticle
    var body: some View {
        let content = HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.sentiment > 0.15 ? Theme.up : item.sentiment < -0.15 ? Theme.down : .gray)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.article.title).font(.subheadline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if !item.article.source.isEmpty { Text(item.article.source) }
                    if let d = item.article.published { Text(d, format: .relative(presentation: .named)) }
                    ForEach(item.catalysts.prefix(2), id: \.self) { t in
                        Text(t).padding(.horizontal, 5).background(.quaternary, in: .capsule)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        if let url = URL(string: item.article.link), !item.article.link.isEmpty {
            Link(destination: url) { content }
        } else {
            content
        }
    }
}

/// Splits today's move into "the market did it" vs "the company did it".
struct MoveBreakdownCard: View {
    let facts: MovementFacts

    var body: some View {
        Card(title: "Market or company?", systemImage: "chart.bar.xaxis") {
            Text(facts.character.label).font(.headline)
            GeometryReader { geo in
                let share = facts.explainedByMarket
                HStack(spacing: 2) {
                    Rectangle().fill(.gray.opacity(0.6)).frame(width: max(geo.size.width * share, share > 0 ? 4 : 0))
                    Rectangle().fill(Theme.accent)
                }
                .clipShape(.rect(cornerRadius: 6))
            }
            .frame(height: 14)
            HStack {
                Label("Sector/market \(Int(facts.explainedByMarket * 100))%", systemImage: "circle.fill")
                    .foregroundStyle(.gray)
                Spacer()
                Label("Company-specific \(Int((1 - facts.explainedByMarket) * 100))%", systemImage: "circle.fill")
                    .foregroundStyle(Theme.accent)
            }
            .font(.caption)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    metric("\(facts.benchmark) today", facts.benchmarkDayChange.signedPercent)
                    metric("S&P 500 today", facts.marketDayChange.signedPercent)
                }
                GridRow {
                    metric("Beta to sector", String(format: "%.2f", facts.beta))
                    metric("Expected from sector", facts.expectedMove.signedPercent)
                }
                GridRow {
                    metric("Size vs normal day", String(format: "%.1f×", abs(facts.zScore)))
                    metric("Volume vs average", String(format: "%.1f×", facts.volumeRatio))
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConfidenceGauge: View {
    let value: Int
    var body: some View {
        Gauge(value: Double(value), in: 0...100) {
            Text("Confidence")
        } currentValueLabel: {
            Text("\(value)")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(Theme.accent)
        .scaleEffect(0.8)
        .accessibilityLabel("Confidence \(value) percent")
    }
}

struct PriceChart: View {
    let points: [PricePoint]
    var body: some View {
        let closes = points.map(\.close)
        let up = (closes.last ?? 0) >= (closes.first ?? 0)
        let color = up ? Theme.up : Theme.down
        Chart(points, id: \.date) { p in
            AreaMark(x: .value("Date", p.date), yStart: .value("Low", closes.min() ?? 0), yEnd: .value("Close", p.close))
                .foregroundStyle(.linearGradient(colors: [color.opacity(0.3), color.opacity(0)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Date", p.date), y: .value("Close", p.close))
                .foregroundStyle(color)
        }
        .chartYScale(domain: (closes.min() ?? 0)...(closes.max() ?? 1))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
    }
}
