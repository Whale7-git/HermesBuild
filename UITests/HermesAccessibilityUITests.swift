import XCTest

/// Intentionally separate from the three gold tests. Existing accessibility
/// defects are recorded as product bugs rather than silently skipped.
final class HermesAccessibilityUITests: XCTestCase {
    func test02HomeAudit() throws {
        let app = HermesUITestHarness.launchAndConnect()
        // Verify empty home, never an old persisted chat screen.
        let newChat = app.buttons["新建对话"]
        if newChat.exists && newChat.isHittable { newChat.tap() }
        XCTAssertTrue(app.buttons["输入新消息"].waitForExistence(timeout: 12),
                      "Home audit must inspect the empty conversation")
        try app.performAccessibilityAudit(for: [
            .hitRegion, .contrast, .textClipped, .sufficientElementDescription
        ]) { issue in
            // Diagnostics only: false keeps the audit failure active.
            let element = issue.element
            print("HERMES_A11Y_HOME type=\(issue.auditType) issue=\(issue.detailedDescription)"
                  + " label=\(element?.label ?? "<none>")"
                  + " frame=\(String(describing: element?.frame))")
            return false
        }
    }

    func test01SessionListAudit() throws {
        let auditedTypes: XCUIAccessibilityAuditType = [
            .hitRegion, .elementDetection, .sufficientElementDescription
        ]
        func openSettledDrawer() -> XCUIApplication {
            let app = HermesUITestHarness.launchAndConnect()
            let open = app.buttons["打开会话侧栏"]
            XCTAssertTrue(open.waitForExistence(timeout: 12) && open.isHittable,
                          "Cannot start session list audit without a real drawer button")
            open.tap()
            let close = app.buttons["关闭会话列表"]
            let settled = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND hittable == true"),
                object: close)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed,
                           "Cannot audit a drawer that never finished opening")
            return app
        }

        func runUnfilteredAudit(_ app: XCUIApplication) throws {
            try app.performAccessibilityAudit(for: auditedTypes) { issue in
                // Diagnoses actual accessibility findings; never suppress.
                let element = issue.element
                print("HERMES_A11Y_SESSION type=\(issue.auditType)"
                      + " issue=\(issue.detailedDescription)"
                      + " label=\(element?.label ?? "<none>")"
                      + " frame=\(String(describing: element?.frame))")
                return false
            }
        }
        let app = openSettledDrawer()
        do {
            try runUnfilteredAudit(app)
        } catch {
            let failure = error as NSError
            // XCTest's AX audit service sometimes fails before producing any
            // findings (Code -56, "Audit failed to complete in time"). That is
            // not an accessibility defect and is not proof of compliance.
            // Allow ONE fresh-app retry; every real audit finding still fails.
            guard failure.domain == "com.apple.xcode.xctest.accessibilityAudit",
                  failure.code == -56 else { throw error }
            app.terminate()
            let retry = openSettledDrawer()
            try runUnfilteredAudit(retry)
        }
    }

    func test03ChatAudit() throws {
        let auditedTypes: XCUIAccessibilityAuditType = [.dynamicType, .trait, .textClipped]

        func openSettledChat() -> XCUIApplication {
            let app = HermesUITestHarness.launchAndConnect()
            HermesUITestHarness.openSession(app)
            // A covered drawer remains mounted during the card transition.
            // Do not feed an animated hierarchy to the AX audit service.
            let close = app.buttons["关闭会话列表"]
            let settled = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hittable == false"), object: close)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed,
                           "Drawer never settled closed before chat audit")
            return app
        }

        func auditAll(_ app: XCUIApplication) throws {
            try app.performAccessibilityAudit(for: auditedTypes) { issue in
                // Actual findings still FAIL. A retry is allowed only for the
                // internal XCTest audit-service timeout, never AX violations.
                let element = issue.element
                print("HERMES_A11Y_CHAT type=\(issue.auditType) issue=\(issue.detailedDescription)"
                      + " label=\(element?.label ?? "<none>")"
                      + " frame=\(String(describing: element?.frame))")
                return false
            }
        }

        let app = openSettledChat()
        do {
            try auditAll(app)
        } catch {
            let failure = error as NSError
            guard failure.domain == "com.apple.xcode.xctest.accessibilityAudit",
                  failure.code == -56 else { throw error }
            // One fresh-app repeat of the identical full audit. A second
            // timeout or a real accessibility finding still fails the test.
            app.terminate()
            try auditAll(openSettledChat())
        }
    }
}
