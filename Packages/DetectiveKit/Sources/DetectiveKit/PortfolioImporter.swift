import Foundation

/// Turns pasted text from a broker, spreadsheet or notes into holdings.
///
/// Handles column layouts like
///     SYM   QTY   PRICE($)   DAY%
///     VOO   238   675.99     +0.30%
/// as well as CSV ("AAPL,10,150.5"), tab-separated, and "AAPL 10" lines.
/// The first token on a line must look like a ticker and the next number is the share count.
/// Header and summary lines are skipped.
public enum PortfolioImporter {
    public struct Row: Hashable, Sendable, Identifiable {
        public var id: String { symbol }
        public let symbol: String
        public let shares: Double
        /// Price shown in the pasted text, if any (for preview only; not a cost basis).
        public let price: Double?
    }

    public struct Result: Sendable {
        public let rows: [Row]
        /// Lines that looked like data but couldn't be read.
        public let skipped: [String]
    }

    static let headerWords: Set<String> = [
        "SYM", "SYMBOL", "TICKER", "STOCK", "NAME", "QTY", "QUANTITY", "SHARES", "TOTAL", "CASH",
        "HOLDINGS", "PORTFOLIO", "PRICE", "VALUE", "USD", "ACCOUNT", "POSITIONS", "SUMMARY"
    ]

    static func isTicker(_ s: String) -> Bool {
        guard !headerWords.contains(s) else { return false }
        return s.range(of: #"^[A-Z][A-Z0-9]{0,5}([.\-][A-Z]{1,2})?$"#, options: .regularExpression) != nil
    }

    /// Parses "1,534", "675.99", "$12.5", "+6.33%". Returns nil for percentages so they
    /// are never mistaken for quantities.
    static func number(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("%") { return nil }
        s = s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: "₪", with: "")
            .replacingOccurrences(of: "€", with: "").replacingOccurrences(of: "£", with: "")
        // A comma followed by exactly 3 digits is a thousands separator; otherwise a decimal comma.
        if s.range(of: #"^[+-]?\d{1,3}(,\d{3})+(\.\d+)?$"#, options: .regularExpression) != nil {
            s = s.replacingOccurrences(of: ",", with: "")
        } else {
            s = s.replacingOccurrences(of: ",", with: ".")
        }
        return Double(s)
    }

    static func tokens(_ line: String) -> [String] {
        let separators = CharacterSet(charactersIn: "\t;|")
        var parts = line.components(separatedBy: separators).flatMap { $0.split(separator: " ").map(String.init) }
        // Plain CSV: "AAPL,10,150.5" arrives as one token.
        if parts.count == 1, parts[0].contains(",") {
            parts = parts[0].split(separator: ",").map(String.init)
        }
        return parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }.filter { !$0.isEmpty }
    }

    public static func parse(_ text: String) -> Result {
        var rows: [String: Row] = [:]
        var order: [String] = []
        var skipped: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = tokens(line)
            guard let first = parts.first?.uppercased().replacingOccurrences(of: "$", with: "") else { continue }
            guard isTicker(first) else { continue }
            let numbers = parts.dropFirst().compactMap(number)
            guard let shares = numbers.first, shares > 0 else {
                if parts.count > 1 && !headerWords.contains(parts[1].uppercased()) { skipped.append(line) }
                continue
            }
            let row = Row(symbol: first, shares: shares, price: numbers.dropFirst().first)
            if let existing = rows[first] {
                // Same ticker in several accounts: add the shares up.
                rows[first] = Row(symbol: first, shares: existing.shares + shares, price: existing.price ?? row.price)
            } else {
                rows[first] = row
                order.append(first)
            }
        }
        return Result(rows: order.compactMap { rows[$0] }, skipped: skipped)
    }
}
