import XCTest

/// Intentionally separate from the three gold tests. Existing accessibility
/// defects are recorded as product bugs rather than silently skipped.
final class HermesAccessibilityUITests: XCTestCase {
    func testHomeAudit() throws {
        let app = HermesUITestHarness.launchAndConnect()
        try app.performAccessibilityAudit(for: [
            .hitRegion, .contrast, .textClipped, .sufficientElementDescription
        ])
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
        try app.performAccessibilityAudit(for: [.dynamicType, .trait, .textClipped])
    }
}
