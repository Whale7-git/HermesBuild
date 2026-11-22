import XCTest

final class HermesGoldUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Distinguish a real accepted POST from optimistic local bubbles before
    /// diagnosing SSE rendering or manual-reading scroll. This endpoint is
    /// loopback-only and never retries the original chat submission.
    @MainActor private func acceptedRunPOSTCount() async throws -> Int {
        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:8765/__control/log")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "Mock request ledger must be readable")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let requests = try XCTUnwrap(root["requests"] as? [[String: Any]])
        return requests.filter {
            ($0["method"] as? String) == "POST" && ($0["path"] as? String) == "/v1/runs"
        }.count
    }

    @MainActor private func waitForSingleAcceptedPOST() async throws {
        for attempt in 0..<30 {
            let count = try await acceptedRunPOSTCount()
            if count == 1 { return }
            XCTAssertLessThanOrEqual(count, 1, "Client replayed the accepted chat POST")
            if attempt < 29 { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        XCTFail("No accepted /v1/runs POST after send tap; cannot attribute missing text or scroll jump to SSE")
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
        // Isolate SSE expectations from image and selection fixtures injected
        // by prior UI suites. All tests run against the same loopback process.
        var reset = URLRequest(url: URL(string:
            "http://127.0.0.1:8765/__control/reset")!)
        reset.httpMethod = "POST"
        let (_, initialResponse) = try await URLSession.shared.data(for: reset)
        XCTAssertEqual((initialResponse as? HTTPURLResponse)?.statusCode, 200,
                       "Mock gateway reset failed before SSE test")
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
        try await waitForSingleAcceptedPOST()
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
    /// Gold 4: a short manual downward pan during live SSE output must leave
    /// the current reading anchor alone when additional reply text arrives.
    @MainActor func test04StreamingManualReadingKeepsAnchor() async throws {
        func control(_ path: String, body: String = "{}") async throws {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:8765" + path)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }
        try await control("/__control/reset")
        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)
        try await control("/__control/stream-interval", body: #"{"delay_ms":1200}"#)
        let editor = app.textViews.matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "消息输入框")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("UI streamed reading anchor")
        let send = app.buttons["发送消息"]
        XCTAssertTrue(send.waitForExistence(timeout: 12) && send.isEnabled)
        send.tap()
        try await waitForSingleAcceptedPOST()
        let user = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "UI streamed reading anchor")).firstMatch
        XCTAssertTrue(user.waitForExistence(timeout: 12),
                      "Sent question must be present before the manual pan")
        XCTAssertTrue(user.isHittable,
                      "Question was already outside viewport before manual pan: frame=\\(user.frame)")
        let transcript = app.scrollViews.firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.38))
        let end = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.52))
        start.press(forDuration: 0.25, thenDragTo: end)
        // Let UIKit deceleration settle before measuring. A new SSE delta
        // arrives during the next interval, while the reader is detached.
        try await Task.sleep(nanoseconds: 650_000_000)
        if !user.exists || !user.isHittable {
            print("HERMES_MANUAL_ANCHOR postPan frame=\\(user.frame)"
                  + " transcript=\\(transcript.frame)"
                  + " acceptedPOSTs=\\(try await acceptedRunPOSTCount())")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "manual-pan-question-not-visible"
            screenshot.lifetime = .keepAlways
            XCTContext.runActivity(named: "Post-pan viewport evidence") { $0.add(screenshot) }
        }
        XCTAssertTrue(user.exists && user.isHittable,
                      "Manual pan should retain the original question in view")
        let before = user.frame.midY
        try await Task.sleep(nanoseconds: 2_300_000_000)
        XCTAssertTrue(user.exists && user.isHittable,
                      "Streaming layout update should not evict the reading anchor")
        let after = user.frame.midY
        XCTAssertLessThan(abs(after - before), 28,
                          "New reply text moved the visible question during manual reading")
        // Observing the transcript must never cause the client to replay POST.
        let finalPOSTCount = try await acceptedRunPOSTCount()
        XCTAssertEqual(finalPOSTCount, 1,
                       "Streaming gestures must not submit another chat request")
    }

}
