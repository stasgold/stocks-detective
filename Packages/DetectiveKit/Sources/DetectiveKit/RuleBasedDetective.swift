import Foundation

/// A deterministic analyst used when Apple Intelligence isn't available
/// (older device, feature disabled, model still downloading) and as a sanity anchor.
public enum RuleBasedDetective {
    public static func investigate(_ file: CaseFile) -> InvestigationReport {
        let f = file.facts
        let rose = f.dayChange >= 0
        let move = NumberText.percent(abs(f.dayChange))
        let top = file.news.first(where: { $0.relevance >= 0.5 })
        let sentiment = file.newsSentiment

        var causes: [Cause] = []
        if f.character == .marketDriven || f.character == .amplified {
            causes.append(Cause(
                title: L("Sector & market move"),
                detail: String(format: L("%@ moved %@%%. With a beta of %@, that alone predicts about %@%% for %@."),
                               f.benchmark, num(f.benchmarkDayChange), NumberText.number(f.beta, digits: 2), num(f.expectedMove), file.symbol),
                evidence: file.marketNews.first?.article.title))
        }
        if let top, f.character != .marketDriven {
            let tag = top.catalysts.first.map { NewsScorer.localizedTag($0).capitalizedFirst } ?? L("Company news")
            causes.append(Cause(title: tag, detail: L("The most relevant headline points to a company-specific catalyst."), evidence: top.article.title))
        }
        if f.volumeRatio >= 1.8 {
            causes.append(Cause(title: L("Heavy trading"), detail: String(format: L("Volume was %@x normal, so this move had real conviction behind it."), NumberText.number(f.volumeRatio))))
        }
        if causes.isEmpty {
            causes.append(Cause(title: L("No clear catalyst"), detail: L("Neither the market nor the headlines explain this move well.")))
        }

        let verdict: Verdict
        let reasoning: String
        switch f.character {
        case .noise:
            verdict = .noise
            reasoning = String(format: L("A %@ move is within %@'s typical daily range of ±%@%%. Nothing to act on."), move, file.symbol, NumberText.number(f.typicalDailyMove))
        case .marketDriven:
            verdict = .justified
            reasoning = L("The stock is moving in line with its sector. This is about the market, not the company.")
        case .amplified, .stockSpecific:
            let newsAgrees = top != nil && sentiment * f.dayChange > 0
            let newsDisagrees = top != nil && sentiment * f.dayChange < 0 && abs(sentiment) > 0.2
            if top == nil {
                verdict = .unexplained
                reasoning = String(format: L("A %@x-typical move with no clear headline. Could be flows, a rumor, or news not yet reported. Treat with caution."), NumberText.number(abs(f.zScore)))
            } else if newsDisagrees {
                verdict = .unexplained
                reasoning = L("Headlines lean the opposite way to the price. The market may be reacting to something else, or pricing in a second-order effect.")
            } else if newsAgrees && abs(f.zScore) > 3.5 && f.volumeRatio < 1.3 {
                verdict = .overreaction
                reasoning = String(format: L("The news supports the direction, but a %@x-typical move on light volume looks stretched."), NumberText.number(abs(f.zScore)))
            } else if newsAgrees && abs(f.zScore) < 1.5 && f.volumeRatio > 2 {
                verdict = .underreaction
                reasoning = L("Heavy volume and supportive news, but the price has barely moved. The market may still be digesting it.")
            } else {
                verdict = .justified
                reasoning = L("The move lines up with the news, its size is plausible for this stock, and volume confirms it.")
            }
        }

        var watch: [String] = []
        if let tag = top?.catalysts.first {
            switch tag {
            case "earnings", "guidance": watch.append(L("Follow-up analyst estimate revisions over the next few days"))
            case "analyst": watch.append(L("Whether other analysts follow with similar rating changes"))
            case "legal/regulatory": watch.append(L("Official statements from regulators or the company"))
            case "macro": watch.append(L("Next macro data release and Fed commentary"))
            default: watch.append(String(format: L("Company response or follow-up coverage of: %@"), top!.article.title))
            }
        }
        if f.volumeRatio >= 1.8 { watch.append(L("Whether volume stays elevated tomorrow (conviction) or fades (one-off)")) }
        if f.distanceFrom52wHigh < -20 { watch.append(String(format: L("Support levels: the stock is %@%% below its recent high"), NumberText.number(abs(f.distanceFrom52wHigh), digits: 0))) }
        watch.append(String(format: L("How %@ trades next session versus %@"), f.benchmark, file.symbol))

        let confidence: Int = {
            var c = 45
            if top != nil { c += 20 }
            if f.character == .marketDriven || f.character == .noise { c += 15 }
            if verdict == .unexplained { c -= 15 }
            return c
        }()

        return InvestigationReport(
            symbol: file.symbol,
            headline: String(format: L(rose ? "%@ rose %@: %@" : "%@ fell %@: %@"), file.symbol, move, f.character.label.localizedLowercase),
            whatHappened: String(format: L(rose
                ? "%@ rose %@ while %@ moved %@%% and the S&P 500 moved %@%%. About %@%% of the move is explained by the sector; the rest (%@%%) is specific to %@."
                : "%@ fell %@ while %@ moved %@%% and the S&P 500 moved %@%%. About %@%% of the move is explained by the sector; the rest (%@%%) is specific to %@."),
                file.symbol, move, f.benchmark, num(f.benchmarkDayChange), num(f.marketDayChange),
                NumberText.number(f.explainedByMarket * 100, digits: 0), num(f.excessMove), file.symbol),
            causes: causes,
            verdict: verdict,
            verdictReasoning: reasoning,
            watchNext: Array(watch.prefix(3)),
            confidence: confidence,
            author: .ruleBased
        )
    }
}

/// Signed one-decimal number for user-facing text ("+1.2" / "+1,2").
private func num(_ v: Double) -> String { NumberText.number(v, signed: true) }
