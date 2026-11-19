import XCTest
@testable import OpenUsage

final class TotalSpendPaletteTests: XCTestCase {
    func testAccountCardsUseTheirProviderFamilyColor() {
        for family in ["claude", "codex"] {
            XCTAssertEqual(TotalSpendPalette.color(for: "\(family)@12345678"), TotalSpendPalette.color(for: family))
        }
    }
}
