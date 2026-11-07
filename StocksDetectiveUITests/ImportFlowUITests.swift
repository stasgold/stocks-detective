import XCTest

/// Reproduces the build 4 crash report: paste a broker table into Import and tap Import.
final class ImportFlowUITests: XCTestCase {
    static let paste = "Add import portfolio that will populate the stocks on paste of \u{201C}\nHOLDINGS\nSYM        QTY    PRICE($)    DAY%  DAY P&L(\u{20AA})\nVOO        238      675.99  +0.30%       1,534\nTSM        160      375.44  +6.33%      11,401\nIVV         66      738.68  +0.34%         520\nLLY         34     1354.00  -0.79%      -1,164\nNVDA       210      186.64  +2.78%       3,376\nAMZN       150      259.30  -0.35%        -435\nASML        25     1424.75  +5.02%       5,430\nMSFT        64      530.61  -0.99%      -1,086\nGOOGL       28      284.78  +0.78%         197\nSPY          9      735.29  +0.31%          66\u{201D}"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryStore", "YES", "-openTab", "import"] + extra
        app.launchEnvironment["IMPORT_TEXT"] = Self.paste
        app.launch()
        return app
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func importAndVerify(_ app: XCUIApplication) {
        let importButton = app.buttons["Import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 15), "Import screen didn't open")
        XCTAssertTrue(app.staticTexts["10 holdings found"].waitForExistence(timeout: 5) ||
                      app.staticTexts["10 HOLDINGS FOUND"].exists, "Preview didn't parse the paste")
        snapshot(app, "import-preview")
        importButton.tap()
        // Let the portfolio refresh with live data and the detective run.
        sleep(20)
        XCTAssertEqual(app.state, .runningForeground, "App crashed after tapping Import")
        snapshot(app, "after-import")
        let nvda = app.buttons.matching(NSPredicate(format: "label CONTAINS 'NVDA'")).firstMatch
        XCTAssertTrue(nvda.waitForExistence(timeout: 20), "Imported holdings not shown")
        nvda.tap()
        sleep(8)
        XCTAssertEqual(app.state, .runningForeground, "App crashed opening a case")
        snapshot(app, "case")
    }

    func testImportIntoEmptyPortfolio() {
        importAndVerify(launch([]))
    }

    func testImportReplacingDemoPortfolio() {
        importAndVerify(launch(["-seedDemoPortfolio", "YES"]))
    }
}
