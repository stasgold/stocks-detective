import Foundation

/// Sanity checks for AI-written text. The on-device model occasionally gets the direction or
/// size of a move wrong ("falls 7.4%" for a stock that rose 5%); we never show that.
public enum ReportValidator {
    // Word stems, so every tense counts: slump/slumps/slumped/slumping.
    static let downStems = ["fall", "fell", "drop", "plung", "sink", "sank", "sunk", "slid", "slump", "tumbl", "declin",
                            "lower", "slip", "sell-off", "selloff", "lose", "losing", "lost", "crash", "plummet", "retreat", "skid"]
    static let upStems = ["rise", "rising", "rose", "risen", "jump", "surg", "soar", "rall", "climb", "gain", "higher",
                          "rebound", "advanc", "spik", "rocket", "leap", "lept"]
    // Short words matched exactly (so "update" isn't "up" and "downgrade" isn't "down").
    static let downExact: Set<String> = ["down", "dip", "dips", "dipped"]
    static let upExact: Set<String> = ["up", "pop", "pops", "popped"]

    static func says(_ tokens: Set<String>, stems: [String], exact: Set<String>) -> Bool {
        !tokens.isDisjoint(with: exact) || tokens.contains { t in stems.contains { t.hasPrefix($0) } }
    }

    /// True if the text contradicts the facts about today's move.
    public static func contradicts(_ text: String, facts: MovementFacts) -> Bool {
        let tokens = Set(text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty })
        let saysDown = says(tokens, stems: downStems, exact: downExact)
        let saysUp = says(tokens, stems: upStems, exact: upExact)
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
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)\s?%"#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            // "3,4 %" (European decimal comma) reads as 3.4.
            Double(ns.substring(with: $0.range(at: 1)).replacingOccurrences(of: ",", with: "."))
        }
    }
}
