import XCTest

/// Diagnostic suite only. Unlike HermesAccessibilityUITests this probe
/// deliberately records (does not fail on) audit findings, so A/B/C/D can
/// be compared on the SAME simulator. Production chat audit stays strict.
final class HermesDynamicTypeProbeUITests: XCTestCase {
    func test01SwiftUITextControl() throws { try verify("swiftui") }
    func test02UIKitPlainControl() throws { try verify("uikit") }
    func test03UIKitAttributedControl() throws { try verify("attributed") }
    func test04TextualNativeProduction() throws { try verify("textual") }

    private func pointSize(_ element: XCUIElement) -> Double? {
        let value = element.value as? String ?? ""
        guard let range = value.range(of: "fontPt=") else { return nil }
        let tail = value[range.upperBound...]
        return Double(tail.prefix(while: { $0.isNumber || $0 == "." }))
    }

    private func verify(_ kind: String) throws {
        let app = XCUIApplication(bundleIdentifier: "com.whale7.hermes")
        app.launchArguments = ["-hermes-font-probe", "-hermes-probe-\(kind)"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        let text: XCUIElement = kind == "swiftui"
            ? app.staticTexts["probe-font"] : app.textViews["probe-font"]
        XCTAssertTrue(text.waitForExistence(timeout: 12),
                      "\(kind) control did not render an accessible text element")
        let beforeHeight = text.frame.height
        let beforePoint = pointSize(text)
        let toggle = app.buttons["probe-toggle"]
        XCTAssertTrue(toggle.exists && toggle.isHittable)
        toggle.tap()
        XCTAssertTrue(app.staticTexts["probe-scale-state"].waitForExistence(timeout: 8))
        let enlarged = app.staticTexts["probe-scale-state"]
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "PROBE LARGE"), object: enlarged)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed)
        let afterHeight = text.frame.height
        let afterPoint = pointSize(text)
        print("HERMES_FONT_PROBE kind=\(kind) beforePt=\(String(describing: beforePoint)) afterPt=\(String(describing: afterPoint)) beforeH=\(beforeHeight) afterH=\(afterHeight)")

        if kind == "swiftui" {
            XCTAssertGreaterThan(afterHeight, beforeHeight,
                                 "Even the SwiftUI control did not grow")
        } else {
            guard let b = beforePoint, let a = afterPoint else {
                XCTFail("Native font sample unavailable: kind=\(kind), value=\(String(describing: text.value))")
                return
            }
            XCTAssertGreaterThan(a, b, "Native glyphs did not grow for \(kind)")
        }

        // Recreate at default size before the system-controlled audit.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        var findings = 0
        try app.performAccessibilityAudit(for: [.dynamicType]) { issue in
            findings += 1
            print("HERMES_PROBE_AUDIT kind=\(kind) issue=\(issue.detailedDescription) element=\(issue.element?.label ?? "<none>") frame=\(String(describing: issue.element?.frame))")
            // Only this diagnostic comparison suite collects issues; the
            // existing full-chat Dynamic Type audit still FAILS on issues.
            return true
        }
        print("HERMES_PROBE_RESULT kind=\(kind) dynamicTypeFindings=\(findings)")
    }
}
