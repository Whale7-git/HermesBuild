import XCTest

/// Regression for the pushed Settings page's direct sheet-dismiss action.
/// Does not accept a successful native Back gesture as evidence for this UI:
/// the separate Bootstrap suite continues to test that legacy navigation.
final class HermesSettingsNavigationUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor func testPushedSettingsPageCanDismissWithoutNativeBack() {
        let app = HermesUITestHarness.launchAndConnect(
            verifySettingsDismissal: true)
        guard HermesUITestHarness.setupSucceeded else { return }
        XCTAssertTrue(HermesUITestHarness.settingsDirectDismissUsed,
                      "Settings child page must expose a hittable direct Done "
                      + "action; native Back is not a substitute")
        let drawer = app.buttons["打开会话侧栏"]
        XCTAssertTrue(drawer.exists && drawer.isHittable,
                      "Home must remain actionable after Settings Done + cold relaunch")
        print("HERMES_SETTINGS_DIRECT_DISMISS_PASS")
    }
}
