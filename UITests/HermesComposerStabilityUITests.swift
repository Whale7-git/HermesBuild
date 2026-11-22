import XCTest

/// Assert native editor geometry, not merely its existence. These checks
/// catch the UIKit intrinsic-size / SwiftUI layout feedback that made typing
/// shift the entire composer after a line wrap.
final class HermesComposerStabilityUITests: XCTestCase {
    @MainActor func testWrappedDraftSettlesWithoutHeightOscillation() {
        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)

        let editor = app.textViews.matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "消息输入框")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        let focused = app.textViews.matching(
            NSPredicate(format: "hasKeyboardFocus == 1")).firstMatch
        XCTAssertTrue(focused.exists, "Native editor did not own keyboard focus")
        let initial = editor.frame
        XCTAssertGreaterThan(initial.height, 20)

        // One uninterrupted edit: no Return-key submission, quote, or mock
        // network status is involved. Text wrapping must use real UIKit width.
        editor.typeText(String(repeating: "Layout stability typing ", count: 9))
        let expanded = editor.frame
        XCTAssertGreaterThan(expanded.height, initial.height,
                             "Long draft should grow the native editor")
        XCTAssertLessThan(expanded.height, 240,
                          "Editor height must remain capped while text scrolls")

        // An already-settled editor must not independently expand/shrink after
        // the asynchronous coordinator publication. A normal pixel-rounding
        // tolerance is allowed.
        Thread.sleep(forTimeInterval: 0.45)
        let settled = editor.frame
        XCTAssertLessThanOrEqual(abs(settled.height - expanded.height), 2.0,
                                 "Composer height changed without any text edit")
        XCTAssertTrue(focused.exists,
                      "Layout update unexpectedly dismissed the keyboard")
    }
}
