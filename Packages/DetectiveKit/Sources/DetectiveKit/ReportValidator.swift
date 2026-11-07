import Foundation

/// Sanity checks for AI-written text. The on-device model occasionally gets the direction or
/// size of a move wrong ("falls 7.4%" for a stock that rose 5%); we never show that.
public enum ReportValidator {
    static let downWords: Set<String> = ["fall", "falls", "fell", "falling", "drop", "drops", "dropped", "plunge", "plunges",
                                         "sink", "sinks", "slide", "slides", "slump", "slumps", "tumble", "tumbles", "decline",
                                         "declines", "down", "lower", "slips", "sell-off", "selloff", "loses", "sinking"]
    static let upWords: Set<String> = ["rise", "rises", "rose", "rising", "jump", "jumps", "surge", "surges", "soar", "soars",
                                       "rally", "rallies", "climb", "climbs", "gain", "gains", "up", "higher", "pops",
                                       "rebound", "rebounds", "advances", "spikes"]

    /// True if the text contradicts the facts about today's move.
    public static func contradicts(_ text: String, facts: MovementFacts) -> Bool {
        let tokens = Set(text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty })
        let saysDown = !tokens.isDisjoint(with: downWords)
        let saysUp = !tokens.isDisjoint(with: upWords)
        if facts.dayChange >= 0.5 && saysDown && !saysUp { return true }
        if facts.dayChange <= -0.5 && saysUp && !saysDown { return true }

        // Every percentage quoted must match one of the numbers the model was given.
        let known = [facts.dayChange, facts.weekChange, facts.monthChange, facts.benchmarkDayChange,
                     facts.marketDayChange, facts.expectedMove, facts.excessMove, facts.typicalDailyMove,
                     facts.distanceFrom52wHigh].map(abs)
        for pct in percentages(in: text) where !known.contains(where: { abs($0 - pct) <= 0.15 + $0 * 0.03 }) {
            return true
        }
        return false
    }

    static func percentages(in text: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s?%"#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            Double(ns.substring(with: $0.range(at: 1)))
        }
    }
}
