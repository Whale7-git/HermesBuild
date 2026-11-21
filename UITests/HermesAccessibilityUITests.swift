import XCTest

/// Intentionally separate from the three gold tests. Existing accessibility
/// defects are recorded as product bugs rather than silently skipped.
final class HermesAccessibilityUITests: XCTestCase {
    func testHomeAudit() throws {
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

    func testSessionListAudit() throws {
        let app = HermesUITestHarness.launchAndConnect()
        app.buttons["打开会话侧栏"].tap()
        try app.performAccessibilityAudit(for: [
            .hitRegion, .elementDetection, .sufficientElementDescription
        ])
    }

    func testChatAudit() throws {
        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)
        // The drawer stays mounted behind the card; wait for the transition.
        let close = app.buttons["关闭会话列表"]
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed,
                       "Drawer never settled closed before chat audit")
        try app.performAccessibilityAudit(for: [.dynamicType, .trait, .textClipped]) { issue in
            // Keep all issues failing; record precise unsupported size ranges
            // and element geometry for remediation on the next iteration.
            let element = issue.element
            print("HERMES_A11Y_CHAT type=\(issue.auditType) issue=\(issue.detailedDescription)"
                  + " label=\(element?.label ?? "<none>")"
                  + " frame=\(String(describing: element?.frame))")
            return false
        }
    }
}
