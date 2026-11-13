import XCTest
@testable import DetectiveKit

final class LocalizationTests: XCTestCase {
    static let languages = ["ar", "de", "es", "fr", "he", "hi", "id", "it", "ja", "ko", "nl", "pl",
                            "pt-BR", "ru", "th", "tr", "uk", "vi", "zh-Hans"]

    private func table(_ lang: String) throws -> [String: String] {
        // Read the file by path: Linux Foundation doesn't resolve region localizations like "pt-BR".
        let base = try XCTUnwrap(Bundle.module.resourceURL, "no resource bundle")
        let url = base.appendingPathComponent("\(lang).lproj/Localizable.strings")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(lang).lproj missing")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(lang) does not parse")
        return dict
    }

    func testEveryLanguageTranslatesEveryEngineString() throws {
        let english = try table("en")
        XCTAssertGreaterThan(english.count, 60)
        for lang in Self.languages {
            let t = try table(lang)
            XCTAssertEqual(Set(t.keys), Set(english.keys), "\(lang) keys differ from English")
            for (key, value) in t {
                XCTAssertFalse(value.isEmpty, "\(lang): empty translation for \(key)")
                // Same number of arguments, so String(format:) never reads garbage.
                let count = { (s: String) in s.components(separatedBy: "@").count }
                XCTAssertEqual(count(value), count(key), "\(lang): argument count differs for \(key)")
            }
        }
    }

    func testVerdictLabelsAreDistinctInEveryLanguage() throws {
        for lang in Self.languages {
            let t = try table(lang)
            let labels = Verdict.allCases.map { t[$0.englishLabel] ?? "" }
            XCTAssertEqual(Set(labels).count, Verdict.allCases.count, "\(lang): \(labels)")
        }
    }

    func testRuleBasedFormatsInEveryLanguage() throws {
        // Every engine format string must format cleanly with string arguments.
        for lang in Self.languages {
            for (key, value) in try table(lang) where key.contains("%@") {
                let args = Array(repeating: "X" as CVarArg, count: key.components(separatedBy: "%@").count - 1)
                let out = String(format: value, arguments: args)
                XCTAssertFalse(out.contains("%@"), "\(lang): unformatted placeholder in \(out)")
                XCTAssertTrue(out.contains("X"), "\(lang): arguments dropped in \(out)")
            }
        }
    }

    func testNumbersFollowTheLocale() {
        let us = Locale(identifier: "en_US"), de = Locale(identifier: "de_DE")
        XCTAssertEqual(NumberText.percent(12.6, locale: us), "12.6%")
        XCTAssertEqual(NumberText.percent(1.234, digits: 2, signed: true, locale: us), "+1.23%")
        XCTAssertEqual(NumberText.percent(-2, digits: 2, signed: true, locale: us), "-2.00%")
        XCTAssertTrue(NumberText.percent(12.6, locale: de).hasPrefix("12,6"))
        XCTAssertEqual(NumberText.number(1.25, digits: 2, locale: de), "1,25")
        XCTAssertEqual(NumberText.number(0.4, signed: true, locale: us), "+0.4")
    }

    func testPromptsStayInEnglish() {
        // The model's brief must not change with the user's language.
        XCTAssertEqual(MoveCharacter.marketDriven.englishLabel, "Market-driven")
        XCTAssertEqual(Verdict.noise.englishLabel, "Just noise")
    }
}
