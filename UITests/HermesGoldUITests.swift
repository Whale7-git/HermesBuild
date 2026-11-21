import XCTest

final class HermesGoldUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Gold 1: the real session row must open a functioning chat composer.
    func test01ConnectionAndSessionList() {
        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)
    }

    /// Gold 2: UI sends a single message and observes scripted SSE completion.
    // Network setup is async but XCUIApplication gestures must remain on
    // XCTest's main actor; otherwise launch throws NSInternalInconsistencyException.
    @MainActor func test02SendStreamAndComplete() async throws {
        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)
        // Make the terminal SSE arrive before the mock persists its answer.
        var config = URLRequest(url: URL(string:
            "http://127.0.0.1:8765/__control/finalization-lag")!)
        config.httpMethod = "POST"
        config.setValue("application/json", forHTTPHeaderField: "Content-Type")
        config.httpBody = Data(#"{"delay_ms":350}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: config)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let editor = app.textViews.matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "消息输入框")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        let focused = app.textViews.matching(
            NSPredicate(format: "hasKeyboardFocus == 1")).firstMatch
        if !focused.exists {
            // A history layout update can move the editor immediately after tap.
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(focused.waitForExistence(timeout: 7),
                      "Chat editor did not gain focus after two real taps")
        editor.typeText("UI test: one message")
        let send = app.buttons["发送消息"]
        XCTAssertTrue(send.waitForExistence(timeout: 15), "Send control missing")
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let text = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "第二段回复已送达")).firstMatch
        // The transcript virtualizes long histories; a completed reply can
        // exist beyond the viewport even after the one SSE GET succeeded.
        // Still require the exact rendered reply, not just a network request.
        if !text.waitForExistence(timeout: 12) {
            let transcript = app.scrollViews.firstMatch
            XCTAssertTrue(transcript.waitForExistence(timeout: 5),
                          "Chat transcript missing after sending")
            for _ in 0..<24 {
                if text.exists { break }
                transcript.swipeUp()
            }
        }
        if !text.exists {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "sse-reply-not-visible-after-scroll"
            screenshot.lifetime = .keepAlways
            XCTContext.runActivity(named: "Failed SSE visible transcript") {
                $0.add(screenshot)
            }
        }
        XCTAssertTrue(text.exists,
                      "SSE reply absent after waiting and scrolling through transcript")
        XCTAssertTrue(app.buttons["发送消息"].waitForExistence(timeout: 30),
                      "Finished Run did not restore the idle Send state")
    }

    /// Gold 3: contentOffset must change in a real rendered long-answer reader.
    @MainActor func test03ReaderProgressAdvancesOnSwipe() async throws {
        // Test-specific image and text fixtures added by earlier UI suites
        // must not displace the long-answer reader from its deterministic
        // baseline. Reset the isolated loopback server before this test.
        var reset = URLRequest(url: URL(string:
            "http://127.0.0.1:8765/__control/reset")!)
        reset.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: reset)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "Mock gateway baseline reset failed")
        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)
        let thread = app.scrollViews.firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 10),
                      "Chat transcript has no UIScrollView")
        // Open the build216 direct long-answer shortcut, not an ellipsis menu.
        let read = app.buttons["专注阅读这条长回复"].firstMatch
        for _ in 0..<24 {
            if read.exists && read.isHittable { break }
            thread.swipeUp()
        }
        XCTAssertTrue(read.waitForExistence(timeout: 8) && read.isHittable,
                      "Completed long answer has no hittable reader shortcut")
        read.tap()
        XCTAssertTrue(app.navigationBars["阅读模式"].waitForExistence(timeout: 12),
                      "Reader sheet did not open")
        let progress = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "阅读进度 ")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10),
                      "Reader does not expose its progress")
        func percent() -> Int {
            Int(progress.label.filter { $0.isNumber }) ?? -1
        }
        let before = percent()
        XCTAssertGreaterThanOrEqual(before, 0)
        let reader = app.scrollViews.firstMatch
        XCTAssertTrue(reader.exists, "Reader has no UIScrollView")
        for _ in 0..<4 { reader.swipeUp() }
        XCTAssertGreaterThan(percent(), before,
                             "Four reader swipes did not increase reading progress")
    }
}
