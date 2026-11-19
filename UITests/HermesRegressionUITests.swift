import XCTest

/// build215/216 regression matrix. Intentionally opt-in until its assertions
/// have real Simulator evidence. A red test identifies a product regression;
/// it must not be made green by weakening the UI check.
final class HermesRegressionUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func control(_ path: String, json: [String: Any]) {
        let endpoint = URL(string: HermesUITestHarness.gateway + path)!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try! JSONSerialization.data(withJSONObject: json)
        let done = expectation(description: "Fixture control endpoint " + path)
        var status = -1
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 8)
        XCTAssertEqual(status, 200, "Mock control channel must be operational")
    }

    private func find(_ app: XCUIApplication, button label: String,
                      scroll: XCUIElement, attempts: Int = 16) -> XCUIElement {
        let element = app.buttons[label].firstMatch
        for _ in 0..<attempts where !element.exists {
            scroll.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing UI action: " + label)
        return element
    }

    /// build215: the modal must intercept taps and restore the same source row
    /// geometry after leaving the gallery.
    func testGalleryNavigationOverlayAndReturnAnchor() {
        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app, title: "UI 图片验收")
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let cover = find(app, button: "查看全部5张图片，从第4张开始", scroll: scroll)
        let source = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "UI 图集测试：5 张图片")).firstMatch
        XCTAssertTrue(source.exists, "Gallery must have a source reply")
        let before = source.frame.midY
        cover.tap()
        XCTAssertFalse(cover.isHittable,
                       "The gallery overlay must block taps into the transcript")
        let next = app.buttons["下一张图片"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        let fifth = app.staticTexts["第 5 张，共 5 张图片"]
        XCTAssertTrue(fifth.waitForExistence(timeout: 10),
                      "The gallery did not switch from image 4 to image 5")
        let done = app.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 8), "Gallery lacks an exit")
        done.tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 10))
        XCTAssertEqual(source.frame.midY, before, accuracy: 3.0,
                       "Closing a media overlay moved the reader's source row")
        XCTAssertTrue(cover.isHittable)
    }

    /// build216: the inline long-answer affordance must keep its identity
    /// after collapsing the displayed preview.
    func testLongReaderShortcutSurvivesCollapse() {
        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)
        let scroll = app.scrollViews.firstMatch
        let shortcut = find(app, button: "专注阅读这条长回复", scroll: scroll)
        XCTAssertTrue(shortcut.isHittable)
        let more = app.buttons["本条回复的更多操作"].firstMatch
        XCTAssertTrue(more.exists)
        more.tap()
        let collapse = app.buttons["收起全文"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        collapse.tap()
        XCTAssertTrue(shortcut.waitForExistence(timeout: 10),
                      "Reader shortcut vanished when long answer was collapsed")
    }

    /// A running turn must not move the Stop hit target when the first
    /// character is typed into the still-editable composer.
    func testStopLocationStableWhenTypingDuringRun() {
        control("/__control/stream", json: ["frame_delay_ms": 3500])
        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)
        let editor = app.textViews.matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "消息输入框")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("Start a slow UI response")
        let send = app.buttons["发送消息"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        send.tap()
        let stop = app.buttons["停止生成"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10),
                      "Running turn failed to show Stop")
        let before = stop.frame
        editor.tap()
        editor.typeText("Another instruction")
        XCTAssertTrue(stop.exists, "Typing hid the running Stop action")
        XCTAssertEqual(stop.frame.midX, before.midX, accuracy: 1.5,
                       "Typing while running shifted the Stop hit region")
        XCTAssertEqual(stop.frame.height, before.height, accuracy: 1,
                       "Stop target height must not resize")
    }

    /// Forced backend errors must become readable UI feedback rather than
    /// exposing raw transport JSON. A failing case is a product bug, not a
    /// reason to special-case the mock or weaken the assertion.
    private func expectReadableError(_ code: Int, phrase: String) {
        control("/__control/stub", json: [
            "method": "POST", "path": "/v1/runs", "status": code,
            "body": ["error": ["message": phrase]]
        ])
        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)
        let editor = app.textViews.matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "消息输入框")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("Trigger scripted error")
        let send = app.buttons["发送消息"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        send.tap()
        let message = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[cd] %@", phrase)).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 14),
                      "HTTP \(code) produced no readable user-facing feedback")
        XCTAssertFalse(message.label.contains("\"error\""),
                       "The app displayed raw JSON instead of a localized message")
    }

    func test413ProducesHumanReadableMessage() {
        expectReadableError(413, phrase: "消息过大，请缩短后重试")
    }

    func test429ProducesHumanReadableMessage() {
        expectReadableError(429, phrase: "请求过于频繁，请稍后重试")
    }

    func test500ProducesHumanReadableMessage() {
        expectReadableError(500, phrase: "服务器暂时不可用")
    }
}
