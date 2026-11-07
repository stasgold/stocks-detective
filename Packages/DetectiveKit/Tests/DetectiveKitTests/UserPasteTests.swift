import XCTest
@testable import DetectiveKit

final class UserPasteTests: XCTestCase {
    /// Exactly what was pasted before the build 4 crash, including the leading sentence and smart quotes.
    func testPasteFromCrashReport() {
        let text = "Add import portfolio that will populate the stocks on paste of \u{201C}\nHOLDINGS\nSYM        QTY    PRICE($)    DAY%  DAY P&L(\u{20AA})\nVOO        238      675.99  +0.30%       1,534\nTSM        160      375.44  +6.33%      11,401\nIVV         66      738.68  +0.34%         520\nLLY         34     1354.00  -0.79%      -1,164\nNVDA       210      186.64  +2.78%       3,376\nAMZN       150      259.30  -0.35%        -435\nASML        25     1424.75  +5.02%       5,430\nMSFT        64      530.61  -0.99%      -1,086\nGOOGL       28      284.78  +0.78%         197\nSPY          9      735.29  +0.31%          66\u{201D}"
        let r = PortfolioImporter.parse(text)
        print(r.rows.map { "\($0.symbol)=\($0.shares)" }, "skipped:", r.skipped)
        XCTAssertEqual(r.rows.count, 10)
        XCTAssertEqual(r.rows.last?.shares, 9)
    }
}
