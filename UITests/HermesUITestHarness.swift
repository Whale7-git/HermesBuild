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
            // A NavigationLink in Form is a *row*. Tapping only the StaticText
            // can return without completing navigation during sheet animation.
            let linkCell = app.cells.containing(.staticText, identifier: "连接与账号").firstMatch
            let linkText = app.staticTexts["连接与账号"]
            let link = linkCell.waitForExistence(timeout: 10) ? linkCell : linkText
            XCTAssertTrue(link.waitForExistence(timeout: 10),
                          "Settings connection entry missing", file: file, line: line)
            link.tap()

            let add = app.buttons["添加实例"]
            if !add.waitForExistence(timeout: 5) {
                // Retry the navigation only when we are STILL on Settings,
                // not when the connection form is already present.
                if !app.navigationBars["连接与账号"].exists
                    && link.exists && link.isHittable {
                    link.tap()
                }
            }
            if !add.waitForExistence(timeout: 6) {
                // Form sections can be lazy on a small Simulator: materialize
                // the lower button by scrolling the actual settings collection.
                if app.collectionViews.firstMatch.exists {
                    app.collectionViews.firstMatch.swipeUp()
                }
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
            save.tap()
            let sheet = app.navigationBars["添加实例"]
            let closed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: sheet)
            let closeStatus = XCTWaiter.wait(for: [closed], timeout: 8)
            if closeStatus != .completed {
                // The Save error is a Form Section below the text fields. The
                // keyboard can keep it outside the visible accessibility tree.
                // Record static labels only: never dump secure fields or values.
                var labels: [String] = []
                func captureStaticLabels() {
                    for label in app.staticTexts.allElementsBoundByIndex.map(\.label) {
                        if !label.isEmpty && !labels.contains(label) {
                            labels.append(label)
                        }
                    }
                }
                captureStaticLabels()
                let form = app.collectionViews.firstMatch.exists
                    ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
                for _ in 0..<3 {
                    if form.exists { form.swipeUp() }
                    else { app.swipeUp() }
                    captureStaticLabels()
                }
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "gateway-instance-save-error"
                attachment.lifetime = .keepAlways
                XCTContext.runActivity(named: "Gateway save failure screenshot") {
                    $0.add(attachment)
                }
                let errors = labels.filter { label in
                    ["无法", "失败", "钥匙串", "请输入", "无效", "Keychain",
                     "error", "配置"].contains {
                        label.localizedCaseInsensitiveContains($0)
                    }
                }
                let report = errors.isEmpty ? labels : errors
                XCTFail("Gateway AddInstance remained open; form labels: \(Array(report.prefix(28)))",
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
