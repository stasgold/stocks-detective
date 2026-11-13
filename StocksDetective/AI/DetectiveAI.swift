import Foundation
import FoundationModels
import DetectiveKit

// MARK: - Structured output the on-device model must fill in

@Generable
enum AIVerdict {
    case justified
    case overreaction
    case underreaction
    case unexplained
    case noise
}

@Generable
struct AICause {
    @Guide(description: "Short name of the cause, 2-5 words, e.g. 'Weak China iPhone demand'")
    var title: String
    @Guide(description: "One sentence on how this cause moved the stock")
    var detail: String
    @Guide(description: "The exact headline from the brief that supports this cause, or an empty string if it comes from the price data")
    var evidence: String
}

@Generable
struct AIReport {
    @Guide(description: "One punchy sentence of at most 12 words naming the main reason for the move")
    var headline: String
    @Guide(description: "2-3 plain-English sentences explaining what happened, citing the key numbers")
    var whatHappened: String
    @Guide(description: "The most likely causes, most important first", .maximumCount(3))
    var causes: [AICause]
    @Guide(description: "Is the size of the move justified by the evidence?")
    var verdict: AIVerdict
    @Guide(description: "2 sentences explaining the verdict, comparing move size, volume and news")
    var verdictReasoning: String
    @Guide(description: "Specific, checkable things to watch in the coming days", .count(3))
    var watchNext: [String]
    @Guide(description: "How confident the investigation is, 0-100", .range(0...100))
    var confidence: Int
}

@Generable
struct AIBriefing {
    @Guide(description: "One sentence headline for the whole portfolio today")
    var headline: String
    @Guide(description: "3-4 sentences: what drove the portfolio today and whether it is a market or stock story")
    var summary: String
    @Guide(description: "Key findings, one per notable holding", .maximumCount(4))
    var keyFindings: [String]
    @Guide(description: "Things to watch across the portfolio next", .count(3))
    var watchNext: [String]
}

struct PortfolioBriefing: Hashable {
    let headline: String
    let summary: String
    let keyFindings: [String]
    let watchNext: [String]
    let author: ReportAuthor
    let createdAt = Date()
}

// MARK: - The detective

/// Wraps Apple's on-device Foundation Models. Falls back to the rule-based detective
/// whenever Apple Intelligence isn't available, so the app always explains moves.
@MainActor
final class DetectiveAI {
    static var instructions: String { """
    You are Stocks Detective, a sharp, calm financial analyst investigating why a stock moved.
    Rules:
    - Use ONLY the numbers and headlines in the brief. Never invent news, numbers or events.
    - First decide if the move is market-wide (compare with the benchmark and beta) or company-specific.
    - Match the move to the headlines. If a stock-specific move has no supporting headline, say so and use verdict 'unexplained'.
    - 'noise' means the move is within the stock's typical daily range.
    - 'overreaction' means the move is larger than the evidence supports; 'underreaction' means smaller.
    - Write for a smart non-expert. Be concrete and brief.
    - Do not tell the user to buy or sell.
    \(responseLanguageRule)
    """ }

    /// Write in the user's language when the on-device model supports it; otherwise English.
    static var responseLanguageRule: String {
        let locale = Locale.current
        guard let code = locale.language.languageCode?.identifier, code != "en",
              SystemLanguageModel.default.supportsLocale(locale) else { return "- Write in English." }
        let name = Locale(identifier: "en").localizedString(forIdentifier: locale.language.minimalIdentifier) ?? code
        return "- Write every text field in \(name). Keep tickers, numbers and quoted headlines exactly as given."
    }

    enum Status: Equatable {
        case available
        case unavailable(String)
    }

    var status: Status {
        if ModelRouter.disabledForTesting { return .unavailable(String(localized: "Apple Intelligence is turned off for testing.")) }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(String(localized: "This device doesn't support Apple Intelligence. Using the built-in rule-based analyst."))
            case .appleIntelligenceNotEnabled:
                return .unavailable(String(localized: "Turn on Apple Intelligence in Settings to get AI investigations."))
            case .modelNotReady:
                return .unavailable(String(localized: "Apple Intelligence is still downloading. Using the rule-based analyst for now."))
            @unknown default:
                return .unavailable(String(localized: "Apple Intelligence is unavailable right now."))
            }
        }
    }

    /// Any Apple Intelligence model (on-device, or Private Cloud if chosen) can answer.
    var isAvailable: Bool { ModelRouter.anyAvailable }

    func prewarm() {
        guard ModelRouter.onDeviceAvailable else { return }
        LanguageModelSession(instructions: Self.instructions).prewarm()
    }

    func investigate(_ file: CaseFile) async -> InvestigationReport {
        let fallback = RuleBasedDetective.investigate(file)
        let result = await ModelRouter.run(instructions: Self.instructions) { session, author in
            // The cloud model has a 32K context, so give it the full evidence locker.
            let brief = author == .privateCloud
                ? file.promptBrief(headlines: 10, marketHeadlines: 6)
                : file.promptBrief()
            let prompt = """
            Investigate this move. The statistical pre-read suggests '\(fallback.verdict.rawValue)'; overrule it only if the headlines clearly say otherwise.

            \(brief)
            """
            return try await session.respond(to: prompt, generating: AIReport.self, options: GenerationOptions(temperature: 0.3)).content
        }
        guard let result else { return fallback }
        let (report, author) = result
        return Self.convert(report, symbol: file.symbol, facts: file.facts, fallback: fallback, author: author)
    }

    func brief(snapshot: PortfolioSnapshot, cases: [CaseFile], reports: [String: InvestigationReport]) async -> PortfolioBriefing {
        let fallback = Self.ruleBasedBriefing(snapshot: snapshot, reports: reports)
        guard !cases.isEmpty else { return fallback }
        let result = await ModelRouter.run(instructions: Self.instructions) { session, author in
            let prompt = """
            Write today's portfolio briefing. Focus on the holdings that moved the portfolio most and explain why.

            \(snapshot.promptBrief(cases: cases, holdings: author == .privateCloud ? 25 : 6))
            """
            return try await session.respond(to: prompt, generating: AIBriefing.self, options: GenerationOptions(temperature: 0.4)).content
        }
        guard let result else { return fallback }
        let (b, author) = result
        return PortfolioBriefing(headline: b.headline, summary: b.summary, keyFindings: b.keyFindings,
                                 watchNext: b.watchNext, author: author)
    }

    static func convert(_ r: AIReport, symbol: String, facts: MovementFacts, fallback: InvestigationReport, author: ReportAuthor) -> InvestigationReport {
        makeReport(symbol: symbol, headline: r.headline, whatHappened: r.whatHappened,
                   causes: r.causes.map { (title: $0.title, detail: $0.detail, evidence: $0.evidence) },
                   verdict: verdict(from: r.verdict), verdictReasoning: r.verdictReasoning, watchNext: r.watchNext,
                   confidence: r.confidence, facts: facts, fallback: fallback, author: author)
    }

    static func verdict(from v: AIVerdict) -> Verdict {
        switch v {
        case .justified: .justified
        case .overreaction: .overreaction
        case .underreaction: .underreaction
        case .unexplained: .unexplained
        case .noise: .noise
        }
    }

    /// Assembles a report from the model's fields, replacing any headline or summary
    /// that misstates the move with the rule-based version.
    static func makeReport(symbol: String, headline: String, whatHappened: String,
                           causes: [(title: String, detail: String, evidence: String)], verdict: Verdict,
                           verdictReasoning: String, watchNext: [String], confidence: Int,
                           facts: MovementFacts, fallback: InvestigationReport, author: ReportAuthor) -> InvestigationReport {
        InvestigationReport(
            symbol: symbol,
            headline: ReportValidator.contradicts(headline, facts: facts) ? fallback.headline : headline,
            whatHappened: ReportValidator.contradicts(whatHappened, facts: facts) ? fallback.whatHappened : whatHappened,
            causes: causes.map { Cause(title: $0.title, detail: $0.detail, evidence: $0.evidence.isEmpty ? nil : $0.evidence) },
            verdict: verdict,
            verdictReasoning: verdictReasoning,
            watchNext: watchNext,
            confidence: confidence,
            author: author
        )
    }

    static func ruleBasedBriefing(snapshot: PortfolioSnapshot, reports: [String: InvestigationReport]) -> PortfolioBriefing {
        let pct = NumberText.percent(snapshot.dayChangePercent, digits: 2, signed: true)
        let top = snapshot.topContributors.prefix(3)
        let names = top.map(\.symbol).joined(separator: ", ")
        let marketDriven = snapshot.lines.filter { $0.character == .marketDriven || $0.character == .noise }.count
        let pnl = NumberText.number(snapshot.dayPnL, digits: 0, signed: true)
        let story = marketDriven * 2 >= snapshot.lines.count
            ? String(localized: "Today was mostly a market story.")
            : String(localized: "Today was driven by company-specific news.")
        let suspects = snapshot.suspects.count
        return PortfolioBriefing(
            headline: names.isEmpty
                ? String(localized: "Portfolio \(pct) today, led by no single holding")
                : String(localized: "Portfolio \(pct) today, led by \(names)"),
            summary: String(localized: "Your portfolio moved \(pct) (\(pnl) USD).") + " " + story + " "
                + String(localized: "\(suspects) holdings moved more than usual on their own and are worth a closer look."),
            keyFindings: top.compactMap { reports[$0.symbol]?.headline },
            watchNext: uniqueWatchItems(top.compactMap { reports[$0.symbol]?.watchNext }),
            author: .ruleBased
        )
    }

    /// Up to 3 distinct "watch next" items, taking each holding's first item before anyone's second.
    static func uniqueWatchItems(_ lists: [[String]], limit: Int = 3) -> [String] {
        var out: [String] = []
        for i in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where i < list.count && !out.contains(list[i]) {
                out.append(list[i])
                if out.count == limit { return out }
            }
        }
        return out
    }
}
