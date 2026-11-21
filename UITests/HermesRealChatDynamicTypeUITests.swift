import XCTest

/// Permanent regression for Dynamic Type in production's nested
/// UIHostingController transcript. The isolated Textual fixture passed while
/// actual chat failed, because the hosted row copied an outdated environment.
final class HermesRealChatDynamicTypeUITests: XCTestCase {
    func testChatNativeGlyphsGrowWithSystemSize() throws {
        let app = HermesUITestHarness.launchAndConnect(extraLaunchArguments: [
            "-hermes-chat-font-probe",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ])
        HermesUITestHarness.openSession(app)

        func pointSize(_ element: XCUIElement) -> Double? {
            guard let value = element.value as? String,
                  let range = value.range(of: "fontPt=") else { return nil }
            let number = value[range.upperBound...]
            return Double(number.prefix(while: { $0.isNumber || $0 == "." }))
        }

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
            XCTAssertNotNil(value, "Native Markdown font sample missing")
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
                             "Native Markdown glyphs failed to grow across system font categories")
    }
}
