import XCTest

/// Talks to the real Hermes setup screens and the isolated loopback Gateway.
/// Does not insert credentials, bypass authentication or mutate production code.
enum HermesUITestHarness {
    static let gateway = "http://127.0.0.1:8765"
    static let sessionTitle = "UI 验收会话"

    /// Preserve a screenshot at the first failed setup transition. The
    /// message contains only booleans and known page names; never dump
    /// text-field values, credentials, or the entire accessibility tree.
    static func recordSetupFailure(_ app: XCUIApplication, stage: String,
                                   details: String,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "bootstrap-" + stage
        evidence.lifetime = .keepAlways
        XCTContext.runActivity(named: "Bootstrap state " + stage) {
            $0.add(evidence)
        }
        XCTFail("SETUP_BLOCKED stage=\(stage); \(details)",
                file: file, line: line)
    }

    static func launchAndConnect(file: StaticString = #filePath,
                                 line: UInt = #line,
                                 extraLaunchArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.whale7.hermes")
        app.launchArguments = extraLaunchArguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20),
                      "SETUP_BLOCKED stage=setup.launch; Hermes did not launch", file: file, line: line)

        let setup = app.buttons["配置连接"]
        if setup.waitForExistence(timeout: 3) {
            setup.tap()
            // A NavigationLink in Form is a *row*. Tapping only the StaticText
            // can return without completing navigation during sheet animation.
            let linkCell = app.cells.containing(.staticText, identifier: "连接与账号").firstMatch
            let linkText = app.staticTexts["连接与账号"]
            let link = linkCell.waitForExistence(timeout: 10) ? linkCell : linkText
            XCTAssertTrue(link.waitForExistence(timeout: 10),
                          "SETUP_BLOCKED stage=setup.settings_entry; connection entry missing", file: file, line: line)
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
                XCTFail("SETUP_BLOCKED stage=setup.open_add_instance; connection page: "
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
                          "SETUP_BLOCKED stage=setup.add_form; Gateway form missing", file: file, line: line)
            name.tap()
            name.typeText("UI Mock")
            address.tap()
            address.typeText(gateway)
            key.tap()
            key.typeText("ui-only-disposable-key")
            let save = app.buttons["添加"]
            XCTAssertTrue(save.exists, "SETUP_BLOCKED stage=setup.save_button; submit missing", file: file, line: line)
            XCTAssertTrue(save.isEnabled && save.isHittable,
                          "SETUP_BLOCKED stage=setup.save_button; submit not actionable",
                          file: file, line: line)
            save.tap()
            let addSheet = app.navigationBars["添加实例"]
            let settingsRoot = app.navigationBars["设置"]
            let home = app.buttons["打开会话侧栏"]

            // A successful AddInstance submit dismisses its child sheet but
            // leaves SettingsView on the pushed "连接与账号" navigation page.
            // "完成" is declared on the Settings root page, so looking for it
            // in the pushed navigation bar can NEVER complete this journey.
            let childGone = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in !addSheet.exists }, object: app)
            if XCTWaiter.wait(for: [childGone], timeout: 20) != .completed {
                let keychainFailure = app.staticTexts.containing(
                    NSPredicate(format: "label CONTAINS %@", "钥匙串操作失败")).firstMatch
                let saveFailure = app.staticTexts.containing(
                    NSPredicate(format: "label CONTAINS %@", "无法安全保存实例")).firstMatch
                let addressFailure = app.staticTexts.containing(
                    NSPredicate(format: "label CONTAINS %@", "请输入有效的实例地址")).firstMatch
                recordSetupFailure(app, stage: "setup.save_child",
                    details: "childVisible=\(addSheet.exists) "
                           + "keychainFailure=\(keychainFailure.exists) "
                           + "saveFailure=\(saveFailure.exists) "
                           + "addressFailure=\(addressFailure.exists)",
                    file: file, line: line)
                return app
            }
            print("HERMES_BOOTSTRAP stage=setup.child_dismissed")
            // The home can occasionally be revealed directly by a changed
            // presentation flow. In that case never perform an extra back tap.
            if !(home.exists && home.isHittable) {
                if connectionPage.waitForExistence(timeout: 8) {
                    print("HERMES_BOOTSTRAP stage=setup.connection_page")
                    var returned = false
                    // The system-provided native NavigationStack back control
                    // is normally labelled with the previous screen's title.
                    // Do not use firstMatch on all buttons: that can tap Add,
                    // remove, or other unrelated actions on a changing Form.
                    for title in ["设置", "返回", "Back"] {
                        let back = connectionPage.buttons[title]
                        if back.exists && back.isHittable {
                            back.tap()
                            returned = true
                            break
                        }
                    }
                    if !returned {
                        // Native edge-back gesture remains a legitimate user
                        // navigation path when iOS changes the back AX label.
                        let from = app.coordinate(withNormalizedOffset:
                            CGVector(dx: 0.015, dy: 0.35))
                        let to = app.coordinate(withNormalizedOffset:
                            CGVector(dx: 0.78, dy: 0.35))
                        from.press(forDuration: 0.12, thenDragTo: to)
                    }
                    if !settingsRoot.waitForExistence(timeout: 10) {
                        recordSetupFailure(app, stage: "setup.return_settings_root",
                            details: "connectionPage=\(connectionPage.exists)"
                                   + " settingsRoot=\(settingsRoot.exists)"
                                   + " home=\(home.exists && home.isHittable)",
                            file: file, line: line)
                        return app
                    }
                    print("HERMES_BOOTSTRAP stage=setup.settings_root")
                } else if !settingsRoot.exists {
                    recordSetupFailure(app, stage: "setup.unknown_parent",
                        details: "childGone=true connectionPage=false"
                               + " root=false home=\(home.exists && home.isHittable)"
                               + " login=\(app.navigationBars["登录"].exists)",
                        file: file, line: line)
                    return app
                }
                // Require the root page itself; the toolbar is not guaranteed
                // to exist when its defining NavigationStack page is covered.
                let done = settingsRoot.buttons["完成"]
                guard done.waitForExistence(timeout: 8) && done.isHittable else {
                    recordSetupFailure(app, stage: "setup.dismiss_settings",
                        details: "root=\(settingsRoot.exists)"
                               + " done=\(done.exists)"
                               + " doneHittable=\(done.exists && done.isHittable)",
                        file: file, line: line)
                    return app
                }
                done.tap()
                print("HERMES_BOOTSTRAP stage=setup.settings_dismissed")
            }
            XCTAssertTrue(home.waitForExistence(timeout: 15) && home.isHittable,
                          "SETUP_BLOCKED stage=setup.home_ready; parent overlay still covers home",
                          file: file, line: line)
            // After the real Gateway/Keychain save has succeeded, perform
            // a cold relaunch. This verifies persisted credentials and also
            // prevents a presented Settings sheet from obscuring the home UI.
            // This is not a test backdoor: the app must initialize normally.
            app.terminate()
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20),
                          "SETUP_BLOCKED stage=setup.cold_relaunch; Hermes did not relaunch",
                          file: file, line: line)
        }
        let sidebar = app.buttons["打开会话侧栏"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 20),
                      "SETUP_BLOCKED stage=setup.persisted_home; drawer missing after relaunch", file: file, line: line)
        XCTAssertTrue(sidebar.isHittable,
                      "SETUP_BLOCKED stage=setup.persisted_home; drawer occluded after relaunch",
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
