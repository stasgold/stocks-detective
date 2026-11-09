import SwiftUI
import SwiftData
import DetectiveKit

struct PortfolioView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \Holding.addedAt) private var allHoldings: [Holding]
    private var holdings: [Holding] { allHoldings.filter { !$0.isDeleted } }
    @State private var showingAdd = false
    @State private var showingImport = LaunchOptions.openTab == "import"
    @State private var path: [String] = LaunchOptions.openCase.map { [$0] } ?? []

    private var inputs: [HoldingInput] { holdings.map(\.input) }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if holdings.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Stocks Detective")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add a holding", systemImage: "plus") { showingAdd = true }
                        Button("Import from paste", systemImage: "doc.on.clipboard") { showingImport = true }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddHoldingView()
            }
            .sheet(isPresented: $showingImport) {
                ImportPortfolioView()
            }
            .navigationDestination(for: String.self) { symbol in
                CaseDetailView(symbol: symbol)
            }
            .task(id: "\(model.generation)|" + holdings.map(\.symbol).joined(separator: ",")) {
                await model.refresh(inputs)
                fillInNames()
            }
        }
    }

    private var list: some View {
        List {
            Section {
                PortfolioHeader(snapshot: model.snapshot(for: inputs), isRefreshing: model.isRefreshing, lastRefresh: model.lastRefresh)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section("Open cases") {
                ForEach(sortedHoldings) { h in
                    NavigationLink(value: h.symbol) {
                        HoldingRow(holding: h, file: model.cases[h.symbol], report: model.reports[h.symbol],
                                   isInvestigating: model.investigating.contains(h.symbol), failure: model.failures[h.symbol])
                    }
                }
                .onDelete(perform: delete)
            }
            Disclaimer().listRowBackground(Color.clear)
        }
        .refreshable {
            await model.refresh(inputs)
            fillInNames()
        }
    }

    /// Most surprising moves first: that's where the story is.
    private var sortedHoldings: [Holding] { HoldingsEditor.sortedBySurprise(holdings, cases: model.cases) }

    /// Imported holdings start with just a ticker; use the company name once we have it.
    private func fillInNames() { HoldingsEditor.fillInNames(holdings, cases: model.cases) }

    private func delete(_ offsets: IndexSet) {
        let list = sortedHoldings
        HoldingsEditor.delete(offsets.map { list[$0] }, in: context, model: model)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No cases yet", systemImage: "magnifyingglass")
        } description: {
            Text("Add your holdings. The detective will explain every move: what happened, which news caused it, whether it's justified, and what to watch next.")
        } actions: {
            Button("Add a holding") { showingAdd = true }
                .buttonStyle(.borderedProminent)
            Button("Import from paste") { showingImport = true }
                .buttonStyle(.bordered)
            Button("Try the demo portfolio") {
                HoldingsEditor.seedDemo(in: context, model: model)
            }
        }
    }
}

struct PortfolioHeader: View {
    let snapshot: PortfolioSnapshot
    let isRefreshing: Bool
    let lastRefresh: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Portfolio value").font(.subheadline).foregroundStyle(.secondary)
            Text(snapshot.totalValue.currency)
                .font(.largeTitle.bold().monospacedDigit())
                .contentTransition(.numericText())
            HStack {
                Text("\(snapshot.dayPnL.signedCurrency) (\(snapshot.dayChangePercent.signedPercent)) today")
                    .foregroundStyle(Theme.change(snapshot.dayPnL))
                    .font(.headline.monospacedDigit())
                Spacer()
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else if let lastRefresh {
                    Text(lastRefresh, style: .time).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !snapshot.suspects.isEmpty {
                Label("\(snapshot.suspects.count) unusual move\(snapshot.suspects.count == 1 ? "" : "s") under investigation", systemImage: "exclamationmark.magnifyingglass")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 4)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .padding(.vertical, 4)
    }
}

struct HoldingRow: View {
    let holding: Holding
    let file: CaseFile?
    let report: InvestigationReport?
    let isInvestigating: Bool
    let failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(holding.symbol).font(.headline)
                    Text(holding.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let file {
                    DaySparkline(file: file)
                        .frame(width: 60, height: 28)
                    ChangePill(value: file.facts.dayChange)
                } else if failure == nil {
                    ProgressView()
                }
            }
            // The point of the app: the "why", right in the list.
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            } else if let report {
                Text(report.headline)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    VerdictBadge(verdict: report.verdict, compact: true)
                    if isInvestigating {
                        Label("Investigating…", systemImage: "apple.intelligence")
                            .font(.caption2).foregroundStyle(.secondary)
                            .symbolEffect(.pulse)
                    } else if report.author.isAI {
                        Image(systemName: "apple.intelligence").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
