import Foundation

/// A deterministic analyst used when Apple Intelligence isn't available
/// (older device, feature disabled, model still downloading) and as a sanity anchor.
public enum RuleBasedDetective {
    public static func investigate(_ file: CaseFile) -> InvestigationReport {
        let f = file.facts
        let dir = f.dayChange >= 0 ? "rose" : "fell"
        let move = String(format: "%.1f%%", abs(f.dayChange))
        let top = file.news.first(where: { $0.relevance >= 0.5 })
        let sentiment = file.newsSentiment

        var causes: [Cause] = []
        if f.character == .marketDriven || f.character == .amplified {
            causes.append(Cause(
                title: "Sector & market move",
                detail: "\(f.benchmark) moved \(fmt(f.benchmarkDayChange))%. With a beta of \(String(format: "%.2f", f.beta)), that alone predicts about \(fmt(f.expectedMove))% for \(file.symbol).",
                evidence: file.marketNews.first?.article.title))
        }
        if let top, f.character != .marketDriven {
            let tag = top.catalysts.first.map { $0.capitalized } ?? "Company news"
            causes.append(Cause(title: tag, detail: "The most relevant headline points to a company-specific catalyst.", evidence: top.article.title))
        }
        if f.volumeRatio >= 1.8 {
            causes.append(Cause(title: "Heavy trading", detail: "Volume was \(String(format: "%.1f", f.volumeRatio))x normal, so this move had real conviction behind it."))
        }
        if causes.isEmpty {
            causes.append(Cause(title: "No clear catalyst", detail: "Neither the market nor the headlines explain this move well."))
        }

        let verdict: Verdict
        let reasoning: String
        switch f.character {
        case .noise:
            verdict = .noise
            reasoning = "A \(move) move is within \(file.symbol)'s typical daily range of ±\(String(format: "%.1f", f.typicalDailyMove))%. Nothing to act on."
        case .marketDriven:
            verdict = .justified
            reasoning = "The stock is moving in line with its sector. This is about the market, not the company."
        case .amplified, .stockSpecific:
            let newsAgrees = top != nil && sentiment * f.dayChange > 0
            let newsDisagrees = top != nil && sentiment * f.dayChange < 0 && abs(sentiment) > 0.2
            if top == nil {
                verdict = .unexplained
                reasoning = "A \(String(format: "%.1f", abs(f.zScore)))x-typical move with no clear headline. Could be flows, a rumor, or news not yet reported. Treat with caution."
            } else if newsDisagrees {
                verdict = .unexplained
                reasoning = "Headlines lean the opposite way to the price. The market may be reacting to something else, or pricing in a second-order effect."
            } else if newsAgrees && abs(f.zScore) > 3.5 && f.volumeRatio < 1.3 {
                verdict = .overreaction
                reasoning = "The news supports the direction, but a \(String(format: "%.1f", abs(f.zScore)))x-typical move on light volume looks stretched."
            } else if newsAgrees && abs(f.zScore) < 1.5 && f.volumeRatio > 2 {
                verdict = .underreaction
                reasoning = "Heavy volume and supportive news, but the price has barely moved. The market may still be digesting it."
            } else {
                verdict = .justified
                reasoning = "The move lines up with the news, its size is plausible for this stock, and volume confirms it."
            }
        }

        var watch: [String] = []
        if let tag = top?.catalysts.first {
            switch tag {
            case "earnings", "guidance": watch.append("Follow-up analyst estimate revisions over the next few days")
            case "analyst": watch.append("Whether other analysts follow with similar rating changes")
            case "legal/regulatory": watch.append("Official statements from regulators or the company")
            case "macro": watch.append("Next macro data release and Fed commentary")
            default: watch.append("Company response or follow-up coverage of: \(top!.article.title)")
            }
        }
        if f.volumeRatio >= 1.8 { watch.append("Whether volume stays elevated tomorrow (conviction) or fades (one-off)") }
        if f.distanceFrom52wHigh < -20 { watch.append("Support levels: the stock is \(String(format: "%.0f", abs(f.distanceFrom52wHigh)))% below its recent high") }
        watch.append("How \(f.benchmark) trades next session versus \(file.symbol)")

        let confidence: Int = {
            var c = 45
            if top != nil { c += 20 }
            if f.character == .marketDriven || f.character == .noise { c += 15 }
            if verdict == .unexplained { c -= 15 }
            return c
        }()

        return InvestigationReport(
            symbol: file.symbol,
            headline: "\(file.symbol) \(dir) \(move): \(f.character.label.lowercased())",
            whatHappened: "\(file.symbol) \(dir) \(move) while \(f.benchmark) moved \(fmt(f.benchmarkDayChange))% and the S&P 500 moved \(fmt(f.marketDayChange))%. About \(Int(f.explainedByMarket * 100))% of the move is explained by the sector; the rest (\(fmt(f.excessMove))%) is specific to \(file.symbol).",
            causes: causes,
            verdict: verdict,
            verdictReasoning: reasoning,
            watchNext: Array(watch.prefix(3)),
            confidence: confidence,
            author: .ruleBased
        )
    }
}
