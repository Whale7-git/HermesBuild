import XCTest

/// Regression: text selection belongs to the native UITextView, not the
/// root chat-card drawer gesture. This tests the real nested chat host.
final class HermesChatSelectionGestureUITests: XCTestCase {
    func testTextDragDoesNotRevealDrawer() {
        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)
        let closeDrawer = app.buttons["关闭会话列表"]
        let text = app.textViews.matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "本段只用于 iOS 模拟器")
        ).firstMatch
        let transcript = app.scrollViews.firstMatch
        for _ in 0..<30 {
            if text.exists && text.isHittable { break }
            if transcript.exists { transcript.swipeUp() }
        }
        XCTAssertTrue(text.waitForExistence(timeout: 10) && text.isHittable,
                      "Native chat text is not available for a selection gesture")
        XCTAssertFalse(closeDrawer.isHittable,
                       "Drawer is already open before the test drag")

        let start = text.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        let end = text.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        start.press(forDuration: 1, thenDragTo: end)

        XCTAssertFalse(closeDrawer.isHittable,
                       "Selecting text to the right unexpectedly revealed the drawer")
        XCTAssertTrue(app.buttons["打开会话侧栏"].exists,
                      "Chat navigation disappeared after native text selection")
    }
}
