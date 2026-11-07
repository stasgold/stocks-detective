import Foundation

/// The detective's read on a single headline.
public struct ScoredArticle: Codable, Hashable, Sendable, Identifiable {
    public var id: String { article.id }
    public let article: NewsArticle
    /// -1 (very negative) ... +1 (very positive)
    public let sentiment: Double
    /// 0...1, how likely this headline is about a price-moving event.
    public let relevance: Double
    /// Short tags such as "earnings", "guidance", "analyst".
    public let catalysts: [String]
}

/// Fast, deterministic headline triage. Runs before the on-device model so the model only
/// sees the handful of headlines that matter (its context window is small).
public enum NewsScorer {
    static let positive: [String] = [
        "beat", "beats", "surge", "soar", "jump", "rally", "record", "upgrade", "raises", "raised",
        "strong", "growth", "outperform", "buyback", "approval", "approved", "wins", "partnership",
        "tops", "exceeds", "bullish", "higher", "gain", "boost", "expands", "breakthrough"
    ]
    static let negative: [String] = [
        "miss", "misses", "plunge", "tumble", "slump", "fall", "falls", "drop", "drops", "sink",
        "downgrade", "cut", "cuts", "lawsuit", "probe", "investigation", "recall", "weak", "warns",
        "warning", "layoffs", "lower", "loss", "bearish", "decline", "slows", "delay", "fine",
        "antitrust", "tariff", "ban", "halt", "fraud", "resign", "underperform", "sell-off", "selloff"
    ]
    static let catalystKeywords: [(tag: String, words: [String])] = [
        ("earnings", ["earnings", "quarter", "q1", "q2", "q3", "q4", "eps", "revenue", "results"]),
        ("guidance", ["guidance", "outlook", "forecast", "raises", "cuts forecast"]),
        ("analyst", ["upgrade", "downgrade", "price target", "analyst", "rating", "initiates"]),
        ("legal/regulatory", ["lawsuit", "probe", "sec", "ftc", "doj", "antitrust", "regulator", "court", "fine", "ban"]),
        ("product", ["launch", "unveil", "product", "release", "approval", "fda", "trial"]),
        ("deal", ["acquire", "acquisition", "merger", "deal", "stake", "buyout", "partnership"]),
        ("management", ["ceo", "cfo", "resign", "steps down", "appoint", "executive"]),
        ("macro", ["fed", "rates", "inflation", "jobs report", "cpi", "tariff", "recession", "treasury", "yields"]),
        ("capital", ["buyback", "dividend", "offering", "split", "debt"]),
    ]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty }
    }

    public static func score(_ article: NewsArticle, symbol: String, companyName: String?, now: Date = Date()) -> ScoredArticle {
        let text = "\(article.title) \(article.summary)"
        let lower = text.lowercased()
        let tokens = words(text)
        let pos = tokens.filter { positive.contains($0) }.count
        let neg = tokens.filter { negative.contains($0) }.count
        let total = pos + neg
        let sentiment = total == 0 ? 0 : Double(pos - neg) / Double(total)

        let tags = catalystKeywords.filter { entry in
            entry.words.contains { word in
                word.contains(" ") ? lower.contains(word) : tokens.contains(word)
            }
        }.map(\.tag)

        var relevance = 0.2
        if lower.contains(symbol.lowercased()) { relevance += 0.25 }
        if let name = companyName?.lowercased(), !name.isEmpty,
           let first = name.split(separator: " ").first, lower.contains(first) { relevance += 0.25 }
        relevance += min(Double(tags.count) * 0.15, 0.3)
        if total > 0 { relevance += 0.1 }
        if let published = article.published {
            let hours = now.timeIntervalSince(published) / 3600
            if hours > 72 { relevance -= 0.25 } else if hours < 24 { relevance += 0.1 }
        }
        return ScoredArticle(article: article, sentiment: sentiment, relevance: min(max(relevance, 0), 1), catalysts: tags)
    }

    public static func rank(_ articles: [NewsArticle], symbol: String, companyName: String?, limit: Int = 6, now: Date = Date()) -> [ScoredArticle] {
        var seen = Set<String>()
        let unique = articles.filter { seen.insert($0.title.lowercased()).inserted }
        return unique
            .map { score($0, symbol: symbol, companyName: companyName, now: now) }
            .sorted { $0.relevance > $1.relevance }
            .prefix(limit)
            .map { $0 }
    }
}
