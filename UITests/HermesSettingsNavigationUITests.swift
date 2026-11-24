import XCTest

/// Settings is verified as three independent scenarios instead of one long
/// journey.
///
/// Run #45232747405 is the reason. That single case had already printed
/// `setup.system_password_declined acknowledged=true` (t=84.4s),
/// `setup.direct_settings_dismissed` (t=92.4s) and
/// `setup.settings_navigation_verified` (t=93.7s) when the shared 300s
/// subprocess bound killed xcodebuild during the cold relaunch, turning a
/// budget mismatch into an opaque `infra.xctest_timeout`. Splitting the
/// contract means a failure names the scenario that actually failed, and
/// each scenario carries its own in-test allowance.
///
/// 1. minimal navigation — no instance, no SecureField, no Passwords prompt
/// 2. system password    — real Gateway key save, prompt must be declined
/// 3. full save + cold   — persisted credential and authenticated GET
final class HermesSettingsNavigationUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// XCUITest can expose the iOS Passwords save prompt as an interruption
    /// instead of as part of SpringBoard's element tree.
    private func monitorPasswordInterruption() {
        addUIInterruptionMonitor(withDescription: "iOS Save Password") { alert in
            let notNow = alert.buttons["Not Now"]
            guard notNow.exists else { return false }
            notNow.tap()
            HermesUITestHarness.noteSystemPasswordPromptDeclinedViaMonitor()
            return true
        }
    }

    /// Scenario 1. Deliberately creates no instance and never focuses the
    /// API-key SecureField, so no system credential prompt can exist. This
    /// isolates the RootView `needsLogin || showSettings` sheet binding plus
    /// the shipped "完成" toolbar action on a pushed page.
    @MainActor func test01SettingsSheetDismissesWithoutCredentials() {
        executionTimeAllowance = 180
        monitorPasswordInterruption()
        _ = HermesUITestHarness.launchForSettingsNavigationOnly()
    }

    /// Scenario 2. Saves a real Gateway key through the shipping form and
    /// proves the optional OS save-password prompt never keeps covering the
    /// Settings toolbar. An absent prompt is a pass; a prompt that stays is
    /// not.
    @MainActor func test02GatewayKeySavePasswordPromptIsDeclined() {
        executionTimeAllowance = 240
        monitorPasswordInterruption()
        _ = HermesUITestHarness.launchAndConnect(verifySettingsDismissal: true,
                                                 passwordProbeOnly: true)
        guard HermesUITestHarness.passwordProbeReached else { return }
        let observed = HermesUITestHarness.systemPasswordPromptObserved
        print("HERMES_SETTINGS_PASSWORD_PROMPT observed=\(observed)")
        if observed {
            XCTAssertTrue(HermesUITestHarness.systemPasswordPromptDeclined,
                          "The iOS Passwords save prompt appeared and was never "
                          + "declined; a covered Settings toolbar must not be "
                          + "tapped blind")
        } else {
            print("HERMES_SETTINGS_PASSWORD_PROMPT absent=optional")
        }
    }

    /// Scenario 3. The full journey: real save, optional system prompt,
    /// direct Settings dismissal, cold relaunch and an authenticated
    /// GET /api/sessions against the loopback Gateway.
    @MainActor func test03FullSetupSurvivesColdRelaunch() {
        executionTimeAllowance = 300
        monitorPasswordInterruption()
        let app = HermesUITestHarness.launchAndConnect(
            verifySettingsDismissal: true)
        guard HermesUITestHarness.setupSucceeded else { return }
        XCTAssertTrue(HermesUITestHarness.settingsDirectDismissUsed,
                      "Settings child page must expose a hittable direct Done "
                      + "action; native Back is not a substitute")
        let drawer = app.buttons["打开会话侧栏"]
        XCTAssertTrue(drawer.exists && drawer.isHittable,
                      "Home must remain actionable after Settings Done + cold relaunch")
        XCTAssertTrue(HermesUITestHarness.authenticatedSessionGetObserved(),
                      "Cold relaunch must issue an authenticated GET /api/sessions")
        print("HERMES_SETTINGS_DIRECT_DISMISS_PASS")
    }
}
