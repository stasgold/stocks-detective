import Foundation

public enum Verdict: String, Codable, Sendable, CaseIterable {
    case justified
    case overreaction
    case underreaction
    case unexplained
    case noise

    public var label: String {
        switch self {
        case .justified: "Justified"
        case .overreaction: "Overreaction"
        case .underreaction: "Underreaction"
        case .unexplained: "Unexplained"
        case .noise: "Just noise"
        }
    }
}

public struct Cause: Codable, Hashable, Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    public let detail: String
    /// Headline that supports this cause, if any.
    public let evidence: String?

    public init(title: String, detail: String, evidence: String? = nil) {
        self.title = title
        self.detail = detail
        self.evidence = evidence
    }
}

public enum ReportAuthor: String, Codable, Sendable {
    /// Apple Intelligence, on-device model.
    case appleIntelligence
    /// Apple Intelligence, Private Cloud Compute model.
    case privateCloud
    case ruleBased

    public var isAI: Bool { self != .ruleBased }
}

/// The detective's finished write-up for one holding.
public struct InvestigationReport: Codable, Hashable, Sendable {
    public let symbol: String
    public let headline: String
    public let whatHappened: String
    public let causes: [Cause]
    public let verdict: Verdict
    public let verdictReasoning: String
    public let watchNext: [String]
    /// 0...100
    public let confidence: Int
    public let author: ReportAuthor
    public let createdAt: Date

    public init(symbol: String, headline: String, whatHappened: String, causes: [Cause], verdict: Verdict,
                verdictReasoning: String, watchNext: [String], confidence: Int, author: ReportAuthor, createdAt: Date = Date()) {
        self.symbol = symbol
        self.headline = headline
        self.whatHappened = whatHappened
        self.causes = causes
        self.verdict = verdict
        self.verdictReasoning = verdictReasoning
        self.watchNext = watchNext
        self.confidence = min(max(confidence, 0), 100)
        self.author = author
        self.createdAt = createdAt
    }
}

/// Everything gathered about one holding before writing the report.
public struct CaseFile: Codable, Hashable, Sendable {
    public let symbol: String
    public let companyName: String?
    public let sector: Sector
    public let facts: MovementFacts
    public let news: [ScoredArticle]
    public let marketNews: [ScoredArticle]
    public let series: PriceSeries
    /// Last trading day's intraday prices (for the row sparkline), if available.
    public let intraday: ChartData?

    public init(symbol: String, companyName: String?, sector: Sector, facts: MovementFacts,
                news: [ScoredArticle], marketNews: [ScoredArticle], series: PriceSeries, intraday: ChartData? = nil) {
        self.symbol = symbol
        self.companyName = companyName
        self.sector = sector
        self.facts = facts
        self.news = news
        self.marketNews = marketNews
        self.series = series
        self.intraday = intraday
    }

    public var newsSentiment: Double {
        let relevant = news.filter { $0.relevance >= 0.4 }
        guard !relevant.isEmpty else { return 0 }
        return relevant.map { $0.sentiment * $0.relevance }.reduce(0, +) / Double(relevant.count)
    }

    /// Compact, number-dense brief for the on-device model. Kept short on purpose:
    /// the system model has a small context window.
    /// - Parameters: headlines / marketHeadlines: how much news to include. The on-device model
    ///   has a small context window; the cloud model can take much more.
    public func promptBrief(headlines: Int = 5, marketHeadlines: Int = 3) -> String {
        let f = facts
        var lines: [String] = []
        lines.append("STOCK: \(symbol)\(companyName.map { " (\($0))" } ?? ""), sector benchmark \(f.benchmark)")
        lines.append("TODAY: \(fmt(f.dayChange))%, 5-day \(fmt(f.weekChange))%, 1-month \(fmt(f.monthChange))%")
        lines.append("BENCHMARK \(f.benchmark) today: \(fmt(f.benchmarkDayChange))%; S&P 500 (SPY): \(fmt(f.marketDayChange))%")
        lines.append("BETA \(fmt(f.beta, 2)); expected move from sector \(fmt(f.expectedMove))%; stock-specific (excess) move \(fmt(f.excessMove))%")
        lines.append("TYPICAL daily move ±\(fmt(f.typicalDailyMove))%; today is \(fmt(abs(f.zScore), 1))x typical")
        lines.append("VOLUME \(fmt(f.volumeRatio, 1))x its 20-day average; \(fmt(f.distanceFrom52wHigh))% from recent high")
        lines.append("STATISTICAL READ: \(f.character.label)")
        lines.append("COMPANY HEADLINES (most relevant first):")
        if news.isEmpty { lines.append("- none found") }
        for n in news.prefix(headlines) {
            let tags = n.catalysts.isEmpty ? "" : " [\(n.catalysts.joined(separator: ", "))]"
            lines.append("- \(n.article.title)\(ageText(n.article.published))\(tags)")
        }
        if !marketNews.isEmpty {
            lines.append("MARKET HEADLINES:")
            for n in marketNews.prefix(marketHeadlines) { lines.append("- \(n.article.title)") }
        }
        return lines.joined(separator: "\n")
    }

    private func ageText(_ date: Date?) -> String {
        guard let date else { return "" }
        let h = Int(Date().timeIntervalSince(date) / 3600)
        return h < 1 ? " (just now)" : h < 48 ? " (\(h)h ago)" : " (\(h / 24)d ago)"
    }
}

func fmt(_ v: Double, _ digits: Int = 1) -> String {
    let s = String(format: "%.\(digits)f", v)
    return v > 0 && !s.hasPrefix("+") ? "+" + s : s
}
