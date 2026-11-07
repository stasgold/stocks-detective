import SwiftUI
import Charts
import DetectiveKit

enum Theme {
    static let accent = Color(red: 0.95, green: 0.70, blue: 0.25) // detective amber
    static let up = Color(red: 0.20, green: 0.75, blue: 0.45)
    static let down = Color(red: 0.92, green: 0.30, blue: 0.30)

    static func change(_ v: Double) -> Color { v >= 0 ? up : down }

    static func color(for verdict: Verdict) -> Color {
        switch verdict {
        case .justified: .blue
        case .overreaction: .orange
        case .underreaction: .purple
        case .unexplained: .red
        case .noise: .gray
        }
    }

    static func icon(for verdict: Verdict) -> String {
        switch verdict {
        case .justified: "checkmark.seal.fill"
        case .overreaction: "flame.fill"
        case .underreaction: "tortoise.fill"
        case .unexplained: "questionmark.diamond.fill"
        case .noise: "waveform.path"
        }
    }
}

extension Double {
    var signedPercent: String { String(format: "%+.2f%%", self) }
    var currency: String { formatted(.currency(code: "USD")) }
    var signedCurrency: String { (self >= 0 ? "+" : "") + formatted(.currency(code: "USD")) }
}

struct ChangePill: View {
    let value: Double
    var body: some View {
        Text(value.signedPercent)
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.change(value), in: .rect(cornerRadius: 6))
    }
}

struct VerdictBadge: View {
    let verdict: Verdict
    var compact = false
    var body: some View {
        Label(verdict.label, systemImage: Theme.icon(for: verdict))
            .font(compact ? .caption2.weight(.semibold) : .subheadline.weight(.semibold))
            .padding(.horizontal, compact ? 6 : 10)
            .padding(.vertical, compact ? 3 : 5)
            .foregroundStyle(Theme.color(for: verdict))
            .background(Theme.color(for: verdict).opacity(0.15), in: .capsule)
    }
}

struct AuthorBadge: View {
    let author: ReportAuthor
    var body: some View {
        switch author {
        case .appleIntelligence:
            Label("Apple Intelligence · on-device", systemImage: "apple.intelligence")
                .font(.caption).foregroundStyle(.secondary)
        case .ruleBased:
            Label("Quick read · rule-based", systemImage: "function")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct Sparkline: View {
    let points: [PricePoint]
    var body: some View {
        let closes = points.map(\.close)
        let up = (closes.last ?? 0) >= (closes.first ?? 0)
        Chart(Array(points.enumerated()), id: \.offset) { i, p in
            LineMark(x: .value("Day", i), y: .value("Close", p.close))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(up ? Theme.up : Theme.down)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: (closes.min() ?? 0)...(closes.max() ?? 1))
    }
}

struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title.uppercased(), systemImage: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.accent)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}

struct Disclaimer: View {
    var body: some View {
        Text("Stocks Detective explains market moves for education. It is not investment advice. AI can make mistakes; check the evidence.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical)
    }
}
