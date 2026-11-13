import SwiftUI
import Charts
import DetectiveKit

/// Yahoo Finance–style price chart: range picker, period change, previous-close line,
/// volume bars and press-and-drag inspection of any bar.
struct StockChartView: View {
    let symbol: String
    @Environment(AppModel.self) private var model

    @State private var range: ChartRange = .day
    @State private var charts: [ChartRange: ChartData] = [:]
    @State private var failed: Set<ChartRange> = []
    @State private var selectedIndex: Int?

    private var data: ChartData? { charts[range] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            ZStack {
                if let data, data.bars.count > 1 {
                    VStack(spacing: 4) {
                        priceChart(data)
                            .frame(height: 210)
                        volumeChart(data)
                            .frame(height: 44)
                    }
                } else if failed.contains(range) {
                    ContentUnavailableView("Chart unavailable", systemImage: "chart.xyaxis.line",
                                           description: Text("Couldn't load \(range.rawValue) prices."))
                        .frame(height: 258)
                } else {
                    ProgressView().frame(height: 258).frame(maxWidth: .infinity)
                }
            }
            rangePicker
        }
        .task(id: "\(model.generation)|\(range.rawValue)") { await load(range) }
        .onChange(of: model.generation) { charts = [:]; failed = [] }
    }

    // MARK: - Pieces

    /// Period change, or the inspected bar's details while dragging.
    @ViewBuilder private var summary: some View {
        if let data, let i = selectedIndex, data.bars.indices.contains(i) {
            let bar = data.bars[i]
            let base = data.baseline ?? bar.close
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                GridRow {
                    Text(Self.tooltipDate(bar.date, range: range)).font(.caption.weight(.semibold))
                    Text("Close").foregroundStyle(.secondary)
                    Text(bar.close.formatted(.number.precision(.fractionLength(2)))).monospacedDigit()
                    Text((bar.close / base - 1) * 100 >= 0 ? "▲" : "▼").foregroundStyle(Theme.change(bar.close - base))
                }
                GridRow {
                    Text(bar.volume > 0 ? "Vol \(bar.volume.formatted(.number.notation(.compactName)))" : "").foregroundStyle(.secondary)
                    Text("Open").foregroundStyle(.secondary)
                    Text(bar.open.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "–").monospacedDigit()
                    Text("")
                }
                GridRow {
                    Text("")
                    Text("High / Low").foregroundStyle(.secondary)
                    Text("\(bar.high.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "–") / \(bar.low.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "–")").monospacedDigit()
                    Text("")
                }
            }
            .font(.caption)
            .frame(height: 44, alignment: .topLeading)
        } else {
            HStack(spacing: 8) {
                if let pct = data?.changePercent, let change = data?.change {
                    Text("\(change >= 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(2)))) (\(pct.signedPercent))")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.change(pct))
                    Text(range.periodLabel).font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text(" ").font(.subheadline)
                }
                Spacer()
            }
            .frame(height: 44, alignment: .topLeading)
        }
    }

    private func priceChart(_ data: ChartData) -> some View {
        let up = (data.changePercent ?? 0) >= 0
        let color = up ? Theme.up : Theme.down
        let domain = data.priceDomain
        let bars = Array(data.bars.enumerated())
        return Chart {
            ForEach(bars, id: \.offset) { i, bar in
                AreaMark(x: .value("i", i), yStart: .value("Base", domain.lowerBound), yEnd: .value("Close", bar.close))
                    .foregroundStyle(.linearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("i", i), y: .value("Close", bar.close))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
            if let base = data.baseline {
                RuleMark(y: .value("Previous close", base))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let i = selectedIndex, data.bars.indices.contains(i) {
                RuleMark(x: .value("i", i))
                    .foregroundStyle(.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("i", i), y: .value("Close", data.bars[i].close))
                    .foregroundStyle(.primary)
                    .symbolSize(40)
            }
        }
        .chartYScale(domain: domain)
        .chartXScale(domain: 0...max(data.xSlots - 1, 1))
        // Price labels sit inside the plot (like Yahoo), so the price and volume charts
        // share the same full width and their bars line up.
        .chartYAxis {
            AxisMarks(preset: .inset, position: .trailing, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.25))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v.formatted(.number.precision(.fractionLength(v < 10 ? 2 : 0))))
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 3)
                            .background(.background.opacity(0.6), in: .rect(cornerRadius: 3))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: Self.labelIndices(count: data.bars.count)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel {
                    if let i = value.as(Int.self), data.bars.indices.contains(i) {
                        Text(Self.axisDate(data.bars[i].date, range: range))
                    }
                }
            }
        }
        .chartXSelection(value: $selectedIndex)
        .sensoryFeedback(.selection, trigger: selectedIndex)
    }

    private func volumeChart(_ data: ChartData) -> some View {
        let bars = Array(data.bars.enumerated())
        return Chart(bars, id: \.offset) { i, bar in
            BarMark(x: .value("i", i), y: .value("Volume", bar.volume))
                .foregroundStyle(i == selectedIndex ? Color.primary.opacity(0.8) : Color.gray.opacity(0.55))
        }
        .chartXScale(domain: 0...max(data.xSlots - 1, 1))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityHidden(true)
    }

    private var rangePicker: some View {
        HStack(spacing: 0) {
            ForEach(ChartRange.allCases) { r in
                Button {
                    selectedIndex = nil
                    range = r
                } label: {
                    Text(r.rawValue)
                        .font(.footnote.weight(r == range ? .bold : .medium))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .foregroundStyle(r == range ? Color.white : Color.primary)
                        .background(r == range ? Theme.accent.opacity(0.9) : Color.clear, in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(r == range ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }

    // MARK: - Loading & formatting

    private func load(_ r: ChartRange) async {
        if charts[r] != nil { return }
        do {
            let c = try await model.provider.chart(for: symbol, range: r)
            charts[r] = c
            failed.remove(r)
        } catch {
            if !Task.isCancelled { failed.insert(r) }
        }
    }

    static func labelIndices(count: Int) -> [Int] {
        guard count > 4 else { return Array(0..<count) }
        let step = Double(count - 1) / 4
        return (0..<4).map { Int((Double($0) * step + step / 2).rounded()) }
    }

    static func axisDate(_ d: Date, range: ChartRange) -> String {
        switch range {
        case .day: d.formatted(.dateTime.hour().minute())
        case .fiveDays: d.formatted(.dateTime.weekday(.abbreviated))
        case .month, .sixMonths, .ytd: d.formatted(.dateTime.month(.abbreviated).day())
        case .year: d.formatted(.dateTime.month(.abbreviated))
        case .fiveYears, .all: d.formatted(.dateTime.year())
        }
    }

    static func tooltipDate(_ d: Date, range: ChartRange) -> String {
        range.isIntraday
            ? d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            : d.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
