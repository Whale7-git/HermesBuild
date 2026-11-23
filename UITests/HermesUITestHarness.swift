import XCTest

/// Talks to the real Hermes setup screens and the isolated loopback Gateway.
/// Does not insert credentials, bypass authentication or mutate production code.
enum HermesUITestHarness {
    static let gateway = "http://127.0.0.1:8765"
    static let sessionTitle = "UI 验收会话"

    static func launchAndConnect(file: StaticString = #filePath,
                                 line: UInt = #line,
                                 extraLaunchArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.whale7.hermes")
        app.launchArguments = extraLaunchArguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20),
                      "Hermes did not launch", file: file, line: line)

        let setup = app.buttons["配置连接"]
        if setup.waitForExistence(timeout: 3) {
            setup.tap()
            // A NavigationLink in Form is a *row*. Tapping only the StaticText
            // can return without completing navigation during sheet animation.
            let linkCell = app.cells.containing(.staticText, identifier: "连接与账号").firstMatch
            let linkText = app.staticTexts["连接与账号"]
            let link = linkCell.waitForExistence(timeout: 10) ? linkCell : linkText
            XCTAssertTrue(link.waitForExistence(timeout: 10),
                          "Settings connection entry missing", file: file, line: line)
            let add = app.buttons["添加实例"]
            let connectionPage = app.navigationBars["连接与账号"]

            // Settings is a presented NavigationStack. A tap on its text can
            // be accepted while a transition is still settling, without
            // actually pushing the destination. Recheck the destination and
            // retry its *real* row, never assume the tap navigated.
            for _ in 0..<3 {
                if add.exists && add.isHittable { break }
                if !connectionPage.exists {
                    let target = (linkCell.exists && linkCell.isHittable)
                        ? linkCell : linkText
                    if target.exists && target.isHittable { target.tap() }
                } else {
                    // The destination may lazy-load its bottom action.
                    let form = app.collectionViews.firstMatch
                    if form.exists && form.isHittable { form.swipeUp() }
                }
                if add.waitForExistence(timeout: 4) && add.isHittable { break }
            }
            guard add.waitForExistence(timeout: 6) && add.isHittable else {
                let image = XCTAttachment(screenshot: app.screenshot())
                image.name = "connection-settings-navigation-failed"
                image.lifetime = .keepAlways
                XCTContext.runActivity(named: "Connection settings navigation") {
                    $0.add(image)
                }
                let onConnectionPage = app.navigationBars["连接与账号"].exists
                XCTFail("Add-instance action not hittable; connection page: "
                        + "\(onConnectionPage)",
                        file: file, line: line)
                return app
            }
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
            XCTAssertTrue(save.isEnabled && save.isHittable,
                          "Gateway Save action must be tappable before submit",
                          file: file, line: line)
            save.tap()
            let sheet = app.navigationBars["添加实例"]
            let home = app.buttons["打开会话侧栏"]
            // SwiftUI can keep the dismissed sheet in the accessibility tree:
            // navigationBars.exists == true is not evidence of a failed save.
            // Require the *connected* home to be fully interactive instead.
            let connected = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    let sheetStillInteractive = sheet.exists && sheet.isHittable
                    return !sheetStillInteractive && home.exists && home.isHittable
                }, object: app)
            let closeStatus = XCTWaiter.wait(for: [connected], timeout: 20)
            if closeStatus != .completed {
                // Capture the *current* onboarding/sheet state before scrolling.
                // Do not print secrets or secure-text-field values.
                let sheetVisible = sheet.exists && sheet.isHittable
                let state = "sheetExists=\(sheet.exists) "
                    + "sheetInteractive=\(sheetVisible) "
                    + "connectedHomeExists=\(home.exists) "
                    + "connectedHomeInteractive=\(home.exists && home.isHittable) "
                    + "setupPrompt=\(app.buttons["配置连接"].exists) "
                    + "keyFieldExists=\(key.exists)"
                // Never enumerate the entire SwiftUI accessibility tree here.
                // allElementsBoundByIndex resolves virtualized descendants by
                // unstable snapshot indices; a stale index can throw an XCTest
                // snapshot exception and hide the original connection failure.
                // Read only stable, explicitly named controls below.
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "gateway-save-current-screen"
                screenshot.lifetime = .keepAlways
                XCTContext.runActivity(named: "Gateway Save / connected-home state") {
                    $0.add(screenshot)
                }
                if sheetVisible {
                    let form = app.collectionViews.firstMatch.exists
                        ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
                    for _ in 0..<2 {
                        if form.exists { form.swipeUp() }
                        // Scrolling is diagnostic only; do not query virtualized labels.
                    }
                }
                XCTFail("Gateway setup did not reach connected home; \(state)",
                        file: file, line: line)
                return app
            }
            // After the real Gateway/Keychain save has succeeded, perform
            // a cold relaunch. This verifies persisted credentials and also
            // prevents a presented Settings sheet from obscuring the home UI.
            // This is not a test backdoor: the app must initialize normally.
            app.terminate()
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20),
                          "Hermes failed to relaunch after saving Gateway",
                          file: file, line: line)
        }
        let sidebar = app.buttons["打开会话侧栏"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 20),
                      "Connected home is missing the drawer action", file: file, line: line)
        XCTAssertTrue(sidebar.isHittable,
                      "Drawer action exists but is occluded; verify Settings was dismissed",
                      file: file, line: line)
        return app
    }

    static func openSession(_ app: XCUIApplication,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        let drawer = app.buttons["打开会话侧栏"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 10) && drawer.isHittable,
                      "Home drawer button is not actionable", file: file, line: line)
        drawer.tap()

        // The drawer view is always mounted behind the chat card. Merely
        // finding a Session row is NOT evidence that the drawer is open.
        let close = app.buttons["关闭会话列表"]
        let opened = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: close)
        guard XCTWaiter.wait(for: [opened], timeout: 8) == .completed else {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "drawer-not-open-or-occluded"
            screenshot.lifetime = .keepAlways
            XCTContext.runActivity(named: "Drawer did not become interactive") {
                $0.add(screenshot)
            }
            XCTFail("Drawer button tap did not reveal hittable close control; "
                    + "sidebar frame=\(drawer.frame), close frame=\(close.frame)",
                    file: file, line: line)
            return
        }

        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[cd] %@", sessionTitle)).firstMatch
        let title = app.staticTexts[sessionTitle]
        let target = row.waitForExistence(timeout: 12) ? row : title
        XCTAssertTrue(target.waitForExistence(timeout: 12),
                      "Mock session is not present in the opened drawer", file: file, line: line)
        XCTAssertTrue(target.isHittable,
                      "Session exists but is occluded: \(target.frame)",
                      file: file, line: line)
        target.tap()
        XCTAssertTrue(app.textViews.matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "消息输入框"))
            .firstMatch.waitForExistence(timeout: 20),
            "Opening a session must show the native message editor",
            file: file, line: line)
    }
}
