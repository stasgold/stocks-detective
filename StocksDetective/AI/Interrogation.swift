import Foundation
import FoundationModels
import DetectiveKit

/// Tool: lets the model pull price history for any ticker (e.g. to compare with a peer).
struct PriceHistoryTool: Tool {
    let name = "getPriceHistory"
    let description = "Get recent daily closing prices and % changes for a stock ticker or ETF, to compare performance."
    let provider: any MarketDataProvider

    @Generable
    struct Arguments {
        @Guide(description: "Ticker symbol, e.g. AAPL or SPY")
        var symbol: String
        @Guide(description: "Number of trading days to look back", .range(2...60))
        var days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let r = try await provider.priceSeries(for: arguments.symbol.uppercased())
        let pts = r.series.points.suffix(arguments.days)
        guard let first = pts.first else { return "No data for \(arguments.symbol)." }
        let change = (r.series.lastPrice / first.close - 1) * 100
        let closes = pts.suffix(10).map { String(format: "%.2f", $0.close) }.joined(separator: ", ")
        return "\(r.series.symbol): last \(String(format: "%.2f", r.series.lastPrice)), today \(String(format: "%+.2f", r.series.dayChangePercent))%, \(String(format: "%+.2f", change))% over \(pts.count) days. Recent closes: \(closes)"
    }
}

/// Tool: lets the model look up fresh headlines for any ticker.
struct NewsLookupTool: Tool {
    let name = "getHeadlines"
    let description = "Get the latest news headlines for a stock ticker, ranked by relevance."
    let provider: any MarketDataProvider

    @Generable
    struct Arguments {
        @Guide(description: "Ticker symbol, e.g. NVDA")
        var symbol: String
    }

    func call(arguments: Arguments) async throws -> String {
        let s = arguments.symbol.uppercased()
        let ranked = NewsScorer.rank(try await provider.news(for: s), symbol: s, companyName: nil, limit: 5)
        if ranked.isEmpty { return "No recent headlines found for \(s)." }
        return ranked.map { "- \($0.article.title)" }.joined(separator: "\n")
    }
}

struct ChatMessage: Identifiable, Hashable {
    enum Role { case user, detective }
    let id = UUID()
    let role: Role
    let text: String
}

/// A follow-up conversation about one case. Keeps the session so the model remembers context.
@MainActor
@Observable
final class Interrogation {
    var messages: [ChatMessage] = []
    var isThinking = false
    private let session: LanguageModelSession?
    private let file: CaseFile

    init(file: CaseFile, report: InvestigationReport?, provider: any MarketDataProvider) {
        self.file = file
        if case .available = SystemLanguageModel.default.availability {
            let context = """
            \(DetectiveAI.instructions)
            You are now answering follow-up questions about this case. You may call tools to fetch prices or headlines for other tickers.
            Keep answers under 120 words.

            CASE BRIEF
            \(file.promptBrief())
            YOUR EARLIER VERDICT: \(report?.verdict.label ?? "none") - \(report?.verdictReasoning ?? "")
            """
            session = LanguageModelSession(tools: [PriceHistoryTool(provider: provider), NewsLookupTool(provider: provider)],
                                           instructions: context)
        } else {
            session = nil
        }
    }

    var suggestions: [String] {
        ["Is this a buying opportunity or a warning sign?",
         "How did \(file.facts.benchmark) and peers do today?",
         "What would change your verdict?"]
    }

    func ask(_ question: String) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isThinking else { return }
        messages.append(ChatMessage(role: .user, text: q))
        guard let session else {
            messages.append(ChatMessage(role: .detective, text: "Follow-up questions need Apple Intelligence. Turn it on in Settings › Apple Intelligence & Siri on a supported iPhone."))
            return
        }
        isThinking = true
        defer { isThinking = false }
        do {
            let response = try await session.respond(to: q)
            messages.append(ChatMessage(role: .detective, text: response.content))
        } catch {
            messages.append(ChatMessage(role: .detective, text: "I couldn't finish that line of inquiry (\(error.localizedDescription)). Try rephrasing."))
        }
    }
}
