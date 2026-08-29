import XCTest
@testable import FineDisplayKit

final class PreferencesAndVersionTests: XCTestCase {
    private var prefs: Preferences!
    private let suite = "co.nousworks.finedisplay.tests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        prefs = Preferences(defaults: UserDefaults(suiteName: suite))
    }

    func testVersionComparison() {
        XCTAssertTrue(FineDisplayInfo.isNewer("1.2.1", than: "1.2.0"))
        XCTAssertTrue(FineDisplayInfo.isNewer("v1.10.0", than: "1.9.9"), "numeric, not lexicographic")
        XCTAssertTrue(FineDisplayInfo.isNewer("2.0", than: "1.9.9"), "shorter version padded with zeros")
        XCTAssertFalse(FineDisplayInfo.isNewer("1.2.0", than: "1.2.0"))
        XCTAssertFalse(FineDisplayInfo.isNewer("v1.1.1", than: "1.2.0"))
    }

    func testSyncFlagRoundtrip() {
        XCTAssertFalse(prefs.syncEnabled(for: "AAA"))
        prefs.setSyncEnabled(true, for: "AAA")
        XCTAssertTrue(prefs.syncEnabled(for: "AAA"))
        prefs.setSyncEnabled(false, for: "AAA")
        XCTAssertFalse(prefs.syncEnabled(for: "AAA"))
    }

    func testOriginsRoundtrip() {
        prefs.displayOrigins = ["AAA": [2056, 0], "BBB": [0, 0]]
        XCTAssertEqual(prefs.displayOrigins["AAA"], [2056, 0])
    }

    func testForgetClearsEverything() {
        prefs.setSyncEnabled(true, for: "AAA")
        prefs.saveBrightness(40, for: "AAA")
        prefs.displayOrigins = ["AAA": [1, 2]]
        prefs.forget("AAA")
        XCTAssertFalse(prefs.syncEnabled(for: "AAA"))
        XCTAssertNil(prefs.savedBrightness(for: "AAA"))
        XCTAssertNil(prefs.displayOrigins["AAA"])
    }
}
