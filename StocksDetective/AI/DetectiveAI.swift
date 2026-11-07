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
    static let instructions = """
    You are Stocks Detective, a sharp, calm financial analyst investigating why a stock moved.
    Rules:
    - Use ONLY the numbers and headlines in the brief. Never invent news, numbers or events.
    - First decide if the move is market-wide (compare with the benchmark and beta) or company-specific.
    - Match the move to the headlines. If a stock-specific move has no supporting headline, say so and use verdict 'unexplained'.
    - 'noise' means the move is within the stock's typical daily range.
    - 'overreaction' means the move is larger than the evidence supports; 'underreaction' means smaller.
    - Write for a smart non-expert. Be concrete and brief.
    - Do not tell the user to buy or sell.
    """

    enum Status: Equatable {
        case available
        case unavailable(String)
    }

    var status: Status {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable("This device doesn't support Apple Intelligence. Using the built-in rule-based analyst.")
            case .appleIntelligenceNotEnabled:
                return .unavailable("Turn on Apple Intelligence in Settings to get AI investigations.")
            case .modelNotReady:
                return .unavailable("Apple Intelligence is still downloading. Using the rule-based analyst for now.")
            @unknown default:
                return .unavailable("Apple Intelligence is unavailable right now.")
            }
        }
    }

    var isAvailable: Bool { status == .available }

    func prewarm() {
        guard isAvailable else { return }
        LanguageModelSession(instructions: Self.instructions).prewarm()
    }

    func investigate(_ file: CaseFile) async -> InvestigationReport {
        let fallback = RuleBasedDetective.investigate(file)
        guard isAvailable else { return fallback }
        let session = LanguageModelSession(instructions: Self.instructions)
        let prompt = """
        Investigate this move. The statistical pre-read suggests '\(fallback.verdict.rawValue)'; overrule it only if the headlines clearly say otherwise.

        \(file.promptBrief())
        """
        do {
            let response = try await session.respond(
                to: prompt,
                generating: AIReport.self,
                options: GenerationOptions(temperature: 0.3)
            )
            return Self.convert(response.content, symbol: file.symbol, facts: file.facts, fallback: fallback)
        } catch {
            return fallback
        }
    }

    func brief(snapshot: PortfolioSnapshot, cases: [CaseFile], reports: [String: InvestigationReport]) async -> PortfolioBriefing {
        let fallback = Self.ruleBasedBriefing(snapshot: snapshot, reports: reports)
        guard isAvailable, !cases.isEmpty else { return fallback }
        let session = LanguageModelSession(instructions: Self.instructions)
        let prompt = """
        Write today's portfolio briefing. Focus on the holdings that moved the portfolio most and explain why.

        \(snapshot.promptBrief(cases: cases))
        """
        do {
            let r = try await session.respond(to: prompt, generating: AIBriefing.self, options: GenerationOptions(temperature: 0.4))
            let b = r.content
            return PortfolioBriefing(headline: b.headline, summary: b.summary, keyFindings: b.keyFindings,
                                     watchNext: b.watchNext, author: .appleIntelligence)
        } catch {
            return fallback
        }
    }

    static func convert(_ r: AIReport, symbol: String, facts: MovementFacts, fallback: InvestigationReport) -> InvestigationReport {
        let verdict: Verdict = switch r.verdict {
        case .justified: .justified
        case .overreaction: .overreaction
        case .underreaction: .underreaction
        case .unexplained: .unexplained
        case .noise: .noise
        }
        return InvestigationReport(
            symbol: symbol,
            // Keep the model's writing, but never a headline or summary that misstates the move.
            headline: ReportValidator.contradicts(r.headline, facts: facts) ? fallback.headline : r.headline,
            whatHappened: ReportValidator.contradicts(r.whatHappened, facts: facts) ? fallback.whatHappened : r.whatHappened,
            causes: r.causes.map { Cause(title: $0.title, detail: $0.detail, evidence: $0.evidence.isEmpty ? nil : $0.evidence) },
            verdict: verdict,
            verdictReasoning: r.verdictReasoning,
            watchNext: r.watchNext,
            confidence: r.confidence,
            author: .appleIntelligence
        )
    }

    static func ruleBasedBriefing(snapshot: PortfolioSnapshot, reports: [String: InvestigationReport]) -> PortfolioBriefing {
        let pct = String(format: "%+.2f%%", snapshot.dayChangePercent)
        let top = snapshot.topContributors.prefix(3)
        let names = top.map(\.symbol).joined(separator: ", ")
        let marketDriven = snapshot.lines.filter { $0.character == .marketDriven || $0.character == .noise }.count
        let story = marketDriven * 2 >= snapshot.lines.count ? "mostly a market story" : "driven by company-specific news"
        return PortfolioBriefing(
            headline: "Portfolio \(pct) today, led by \(names.isEmpty ? "no single holding" : names)",
            summary: "Your portfolio moved \(pct) (\(String(format: "%+.0f", snapshot.dayPnL)) USD). Today was \(story). \(snapshot.suspects.count) holding(s) moved more than usual on their own and are worth a closer look.",
            keyFindings: top.compactMap { reports[$0.symbol]?.headline },
            watchNext: Array(top.compactMap { reports[$0.symbol]?.watchNext.first }.prefix(3)),
            author: .ruleBased
        )
    }
}
