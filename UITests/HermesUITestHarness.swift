import XCTest

/// Talks to the real Hermes setup screens and the isolated loopback Gateway.
/// Does not insert credentials, bypass authentication or mutate production code.
enum HermesUITestHarness {
    static let gateway = "http://127.0.0.1:8765"
    static let sessionTitle = "UI 验收会话"

    static func launchAndConnect(file: StaticString = #filePath,
                                 line: UInt = #line) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.whale7.hermes")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20),
                      "Hermes did not launch", file: file, line: line)

        let setup = app.buttons["配置连接"]
        if setup.waitForExistence(timeout: 3) {
            setup.tap()
            let link = app.staticTexts["连接与账号"]
            XCTAssertTrue(link.waitForExistence(timeout: 10),
                          "Settings connection entry missing", file: file, line: line)
            link.tap()
            let add = app.buttons["添加实例"]
            XCTAssertTrue(add.waitForExistence(timeout: 10),
                          "Add-instance entry missing", file: file, line: line)
            add.tap()
            let name = app.textFields["实例名称"]
            let address = app.textFields["https://网关地址:8642"]
            let key = app.secureTextFields["API_SERVER_KEY"]
            XCTAssertTrue(name.waitForExistence(timeout: 8) &&
                          address.exists && key.exists,
                          "Gateway instance form missing", file: file, line: line)
            name.tap()
            name.typeText("UI Mock")
            address.tap()
            address.typeText(gateway)
            key.tap()
            key.typeText("ui-only-disposable-key")
            let save = app.buttons["添加"]
            XCTAssertTrue(save.exists, "Add-instance submit missing", file: file, line: line)
            save.tap()
            let sheet = app.navigationBars["添加实例"]
            let closed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: sheet)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 25), .completed,
                           "Gateway connection did not validate and save",
                           file: file, line: line)
            let connection = app.navigationBars["连接与账号"]
            if connection.exists {
                let back = connection.buttons.firstMatch
                if back.exists { back.tap() }
            }
            let done = app.buttons["完成"]
            if done.waitForExistence(timeout: 8) { done.tap() }
        }
        XCTAssertTrue(app.buttons["打开会话侧栏"].waitForExistence(timeout: 20),
                      "Connected home is missing session navigation", file: file, line: line)
        return app
    }

    static func openSession(_ app: XCUIApplication,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        let drawer = app.buttons["打开会话侧栏"]
        if drawer.waitForExistence(timeout: 6) { drawer.tap() }
        let row = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[cd] %@", sessionTitle)).firstMatch
        let title = app.staticTexts[sessionTitle]
        let target = row.waitForExistence(timeout: 12) ? row : title
        XCTAssertTrue(target.waitForExistence(timeout: 12),
                      "Mock session must be visible in the actual session list",
                      file: file, line: line)
        target.tap()
        XCTAssertTrue(app.textViews.matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "消息输入框"))
            .firstMatch.waitForExistence(timeout: 20),
            "Opening a session must show the native message editor",
            file: file, line: line)
    }
}
