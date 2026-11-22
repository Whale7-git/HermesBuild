import XCTest

/// Real nested chat: native text selection must not steal the full-card
/// return gesture, while ordinary center-to-right swipes still open the drawer.
final class HermesChatSelectionGestureUITests: XCTestCase {
    @MainActor func testTextDragDoesNotRevealDrawer() async throws {
        // Use a short visible assistant paragraph. The previous test searched
        // the first paragraph of a 40-section reply, which was offscreen.
        var fixture = URLRequest(url: URL(string:
            "http://127.0.0.1:8765/__control/add-selection-text")!)
        fixture.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: fixture)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)
        let close = app.buttons["关闭会话列表"]
        let text = app.textViews.matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "UI 手势冲突测试文本")
        ).firstMatch
        let transcript = app.scrollViews.firstMatch
        for _ in 0..<12 {
            if text.exists && text.isHittable { break }
            if transcript.exists && transcript.isHittable { transcript.swipeUp() }
        }
        guard text.waitForExistence(timeout: 10), text.isHittable else {
            XCTFail("Native selection UITextView is not visible: fixture or element lookup failed")
            return // Do not synthesize a touch at an infinite coordinate.
        }
        XCTAssertFalse(close.isHittable, "Drawer is already visible before drag")

        let start = text.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        let end = text.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.5))
        start.press(forDuration: 1.1, thenDragTo: end)
        XCTAssertFalse(close.isHittable,
                       "Dragging a native text selection unexpectedly revealed the drawer")
    }

    @MainActor func testOrdinaryFullCardSwipeStillOpensDrawer() {
        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)
        let close = app.buttons["关闭会话列表"]
        XCTAssertFalse(close.isHittable, "Drawer is already visible before swipe")
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: 0.50))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.50))
        from.press(forDuration: 0.05, thenDragTo: to)
        XCTAssertTrue(close.waitForExistence(timeout: 8) && close.isHittable,
                      "Full-card swipe from the center must still open the session drawer")
    }
}
