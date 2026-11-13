import Foundation

/// Looks up a user-facing string in this package's `Localizable.strings`.
/// The English text is the key, so a missing translation shows English.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .module, comment: "")
}

extension ScoredArticle {
    /// Catalyst tags in the user's language ("earnings" → "Ergebnisse").
    public var localizedCatalysts: [String] { catalysts.map(NewsScorer.localizedTag) }
}

extension NewsScorer {
    public static func localizedTag(_ tag: String) -> String { L(tag) }
}

extension String {
    /// First letter uppercased, the rest untouched (works for any script).
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).localizedUppercase + dropFirst()
    }
}

/// Numbers for people (locale-aware: "12.6%", "12,6 %", "%12,6"). Prompts for the model use `fmt` instead.
public enum NumberText {
    public static func percent(_ value: Double, digits: Int = 1, signed: Bool = false, locale: Locale = .current) -> String {
        let f = formatter(.percent, digits: digits, signed: signed, locale: locale)
        return f.string(from: NSNumber(value: value / 100)) ?? String(format: "%.\(digits)f%%", value)
    }

    public static func number(_ value: Double, digits: Int = 1, signed: Bool = false, locale: Locale = .current) -> String {
        let f = formatter(.decimal, digits: digits, signed: signed, locale: locale)
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    static func formatter(_ style: NumberFormatter.Style, digits: Int, signed: Bool, locale: Locale) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = style
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        if signed { f.positivePrefix = f.plusSign + (f.positivePrefix ?? "") }
        return f
    }
}
