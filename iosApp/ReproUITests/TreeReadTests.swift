import XCTest

/// Reads the app's accessibility tree once, the way any XCUITest-based tool does, and returns.
///
/// It attaches to the app that is already running instead of launching it, so the app is neither
/// relaunched nor terminated when the test ends: afterwards it sits idle with nothing reading its
/// tree, which is the state the reproduction measures.
final class TreeReadTests: XCTestCase {
    func testReadAccessibilityTreeOnce() throws {
        let bundleId = try XCTUnwrap(
            Bundle(for: Self.self).object(forInfoDictionaryKey: "ReproAppBundleIdentifier") as? String
        )
        let app = XCUIApplication(bundleIdentifier: bundleId)
        XCTAssertEqual(app.state, .runningForeground, "launch the app before running this test")

        // One query and one full snapshot: enough for Compose to build its accessibility tree.
        XCTAssertTrue(app.buttons["Tap"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Row 1"].exists)
        let snapshot = try app.snapshot()
        print("accessibility snapshot: \(snapshot.children.count) top-level children")
    }
}
