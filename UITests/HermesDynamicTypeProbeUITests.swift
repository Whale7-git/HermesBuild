import XCTest

/// Diagnostic suite only. Unlike HermesAccessibilityUITests this probe
/// deliberately records (does not fail on) audit findings, so A/B/C/D can
/// be compared on the SAME simulator. Production chat audit stays strict.
final class HermesDynamicTypeProbeUITests: XCTestCase {
    func test01SwiftUITextControl() throws { try verify("swiftui") }
    func test02UIKitPlainControl() throws { try verify("uikit") }
    func test03UIKitAttributedControl() throws { try verify("attributed") }
    func test04TextualNativeProduction() throws { try verify("textual") }

    /// The regression that the standalone A/B/C/D probes cannot exercise:
    /// actual native Markdown inside the nested UIHostingController transcript.
    /// A fresh launch with different preferred content size is a measurable,
    /// UIKit-driven fixture independent of SwiftUI's test-only toggle.
    func test05ChatNativeGlyphsGrowWithSystemSize() throws {
        let app = HermesUITestHarness.launchAndConnect(extraLaunchArguments: [
            "-hermes-chat-font-probe",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ])
        HermesUITestHarness.openSession(app)

        func sample() -> Double {
            let text = app.textViews.matching(
                NSPredicate(format: "label CONTAINS[cd] %@", "本段只用于 iOS 模拟器")
            ).firstMatch
            let scroll = app.scrollViews.firstMatch
            for _ in 0..<30 {
                if text.exists && text.isHittable { break }
                if scroll.exists { scroll.swipeUp() }
            }
            XCTAssertTrue(text.waitForExistence(timeout: 10),
                          "Real chat did not expose native Markdown text")
            let value = pointSize(text)
            XCTAssertNotNil(value, "Real chat native font sample unavailable")
            return value ?? -1
        }

        let normal = sample()
        app.terminate()
        app.launchArguments = [
            "-hermes-chat-font-probe",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        HermesUITestHarness.openSession(app)
        let accessibility = sample()
        print("HERMES_REAL_CHAT_FONT normalPt=\(normal) accessibilityPt=\(accessibility)")
        XCTAssertGreaterThan(accessibility, normal,
                             "Real chat native glyphs did not grow with system text size")
    }

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
