"""Pure verification selection and report-contract tests (no Apple SDK needed)."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

PATH = Path(__file__).resolve().parents[2] / "scripts" / "verify_ios_simulator.py"
SPEC = importlib.util.spec_from_file_location("verify_ios_simulator", PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SimulatorPlanTests(unittest.TestCase):
    def test_targeted_gold_cases_have_no_duplicate_invocations(self):
        self.assertEqual(MODULE.cases_for_suite("gold2"),
                         ["HermesGoldUITests.test02SendStreamAndComplete"])
        self.assertEqual(MODULE.cases_for_suite("gold4"),
                         ["HermesGoldUITests.test04StreamingManualReadingKeepsAnchor"])

    def test_every_scenario_runs_at_most_once(self):
        for suite in MODULE.SUITES:
            cases = MODULE.cases_for_suite(suite)
            self.assertEqual(len(cases), len(set(cases)))
            for case in cases:
                self.assertRegex(case, MODULE.SAFE_CASE)

    def test_bootstrap_isolated_and_gold_gated(self):
        self.assertEqual(MODULE.cases_for_suite("bootstrap"), [MODULE.BOOTSTRAP])
        self.assertEqual(MODULE.cases_for_suite("gold1"), [MODULE.GOLD[0]])
        self.assertEqual(MODULE.cases_for_suite("gold3"), [MODULE.GOLD[2]])
        self.assertEqual(MODULE.cases_for_suite("gold")[0], MODULE.GOLD[0])
        self.assertEqual(len(MODULE.cases_for_suite("gold")), 4)
        self.assertNotIn(MODULE.BOOTSTRAP, MODULE.cases_for_suite("gold"))
        self.assertEqual(MODULE.cases_for_suite("all")[0], MODULE.GOLD[0])
        self.assertIn(MODULE.GOLD[3], MODULE.cases_for_suite("all"))

    def test_setup_failure_blocks_product_without_hiding_bootstrap_failure(self):
        diagnostic = ["Test Case 'HermesUITests' failed",
                      "test.swift:32: error: SETUP_BLOCKED stage=setup.return_settings_root"]
        self.assertEqual(MODULE.classify_case(1, diagnostic, MODULE.BOOTSTRAP),
                         ("FAIL", "setup.return_settings_root"))
        self.assertEqual(MODULE.classify_case(1, diagnostic, MODULE.GOLD[1]),
                         ("BLOCKED", "setup.return_settings_root"))

    def test_product_assertion_and_infra_remain_distinct(self):
        self.assertEqual(MODULE.classify_case(1,
                         ["Test Case 'HermesUITests' failed"], MODULE.GOLD[3]),
                         ("FAIL", "product.assertion"))
        self.assertEqual(MODULE.classify_case(70,
                         ["xcodebuild failed to boot simulator"], MODULE.GOLD[3]),
                         ("INFRA_ERROR", "infra.xcodebuild"))
        self.assertEqual(MODULE.classify_case(0, [], MODULE.BOOTSTRAP),
                         ("PASS", None))

    def test_settings_direct_dismiss_is_manual_suite_not_product_gate(self):
        self.assertEqual(MODULE.cases_for_suite("settings"), [MODULE.SETTINGS])
        self.assertNotIn(MODULE.SETTINGS, MODULE.cases_for_suite("gold"))
        self.assertNotIn(MODULE.SETTINGS, MODULE.cases_for_suite("all"))
        self.assertIn("HermesSettingsNavigationUITests",
                      MODULE.SETTINGS)

    def test_zero_exit_without_requested_test_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as root:
            log = Path(root) / "xcodebuild.log"
            testcase = MODULE.BOOTSTRAP
            self.assertFalse(MODULE.observed_selected_pass(log, testcase))
            log.write_text("** TEST SUCCEEDED **\n", encoding="utf-8")
            self.assertFalse(MODULE.observed_selected_pass(log, testcase))
            log.write_text(
                "Test Case '-[HermesUITests.HermesBootstrapUITests "
                "testGatewaySetupPersistsAcrossRelaunch]' passed (8.321 seconds).\n",
                encoding="utf-8")
            self.assertTrue(MODULE.observed_selected_pass(log, testcase))

    def test_unknown_suite_is_rejected(self):
        with self.assertRaises(ValueError):
            MODULE.cases_for_suite("unknown")

    def test_long_gold4_trace_retains_failed_assertion_stage(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "ui.log"
            log.write_text(
                "test.swift:305: error: Gold4 SSE_ANCHOR_DRIFT 338pt "
                + "rowContent=" + "0" * 1600 + "\n",
                encoding="utf-8")
            lines = MODULE.diagnostic_lines(log)
            self.assertEqual(len(lines), 1)
            self.assertIn("Gold4 SSE_ANCHOR_DRIFT", lines[0])
            self.assertIn("[truncated]", lines[0])

    def test_gold4_asserts_stable_uikit_row_not_a11y_first_match(self):
        source = (Path(__file__).resolve().parents[2] /
                  "UITests" / "HermesGoldUITests.swift").read_text()
        self.assertIn('traceFrame("userFrame", in: postStreamTrace)', source)
        self.assertIn("Gold4 SSE_ROW_VISIBLE failed", source)
        self.assertIn("Gold4 SSE_ANCHOR_DRIFT", source)

    def test_gateway_setup_dismisses_child_and_parent_sheets(self):
        source = (Path(__file__).resolve().parents[2] /
                  "UITests" / "HermesUITestHarness.swift").read_text()
        self.assertIn('app.navigationBars["连接与账号"]', source)
        self.assertIn('connectionPage.buttons.firstMatch', source)
        self.assertIn("stage=setup.native_back_probe", source)
        self.assertIn("setup.native_back_coordinate_tapped", source)
        self.assertIn("setup.edge_back_attempted", source)
        self.assertIn('app.navigationBars["设置"]', source)
        self.assertNotIn('for title in ["设置", "返回", "Back"]', source)
        self.assertIn("done.tap()", source)
        self.assertIn('stage: "setup.return_settings_root"', source)
        self.assertIn('stage: "setup.dismiss_settings"', source)
        self.assertIn("recordSetupFailure", source)
        self.assertNotIn("for label in app.staticTexts.allElementsBoundByIndex", source)
        self.assertIn("setupSucceeded = homeReady", source)
        self.assertIn("waitForRootToOwnHitTesting", source)
        self.assertIn('stage=setup.root_wait', source)
        bootstrap = (Path(__file__).resolve().parents[2] /
                     "UITests" / "HermesBootstrapUITests.swift").read_text()
        self.assertIn("guard HermesUITestHarness.setupSucceeded else { return }",
                      bootstrap)
        self.assertIn("launchAndConnect(verifySettingsDismissal: true)", bootstrap)
        self.assertIn("verifySettingsDismissal: Bool = false", source)
        self.assertIn("if verifySettingsDismissal {", source)
        self.assertIn("stage=setup.product_cold_restart", source)
        gold = (Path(__file__).resolve().parents[2] /
                "UITests" / "HermesGoldUITests.swift").read_text()
        self.assertEqual(gold.count("guard HermesUITestHarness.setupSucceeded else { return }"), 4)
        self.assertNotIn("verifySettingsDismissal: true", gold)

    def test_pushed_settings_direct_dismiss_has_explicit_ui_contract(self):
        root = Path(__file__).resolve().parents[2]
        settings = (root / "Sources" / "HermesShell" /
                    "LoginSettings.swift").read_text()
        harness = (root / "UITests" / "HermesUITestHarness.swift").read_text()
        regression = (root / "UITests" /
                      "HermesSettingsNavigationUITests.swift").read_text()
        self.assertIn('.accessibilityIdentifier("HermesSettingsDismiss")',
                      settings)
        self.assertGreaterEqual(
            settings.count('.accessibilityIdentifier("HermesSettingsDismiss")'), 2)
        self.assertIn('connectionPage.buttons["HermesSettingsDismiss"]',
                      harness)
        self.assertIn("settingsDirectDismissUsed = true", harness)
        self.assertIn('stage: "setup.direct_settings_dismiss"', harness)
        # XCTest may report an isHittable toolbar Button whose synthesized
        # activation point is (-1,-1), as in archived Run #45203535332.
        # Coordinate fallback targets the actual Done frame, not a hidden
        # model mutation or the native Back-button route.
        self.assertIn("stage=setup.done_hitpoint_fallback", harness)
        self.assertIn("windowFrame.contains(buttonCenter)", harness)
        self.assertIn("app.coordinate(withNormalizedOffset: CGVector(", harness)
        # Run #45213964498 crashed querying the obscured drawer's AX
        # hit point ("line.3.horizontal") before it could tap Settings Done.
        # An underlying home button is never a safe hit-test target while
        # either Settings navigation bar still owns the modal.
        self.assertIn("guard settingsSheetGone(8) else", harness)
        self.assertIn("!connectionPage.exists && !settingsRoot.exists", harness)
        direct_section = harness.split(
            'let directDone = connectionPage.buttons["HermesSettingsDismiss"]',
            1)[1].split("settingsDirectDismissUsed = true", 1)[0]
        self.assertNotIn("home.exists && home.isHittable", direct_section)
        self.assertNotIn("homeInteractive=", direct_section)
        self.assertIn("settingsDirectDismissUsed = true", harness)
        self.assertIn("settingsDirectDismissUsed", regression)
        self.assertIn("verifySettingsDismissal: true", regression)

    def test_gateway_api_key_is_not_treated_as_password_autofill(self):
        root = Path(__file__).resolve().parents[2]
        add_instance = (root / "Sources" / "HermesShell" /
                        "AddInstanceView.swift").read_text()
        marker = 'SecureField(editingID == nil ? "API_SERVER_KEY"'
        self.assertIn(marker, add_instance)
        gateway_field = add_instance.split(marker, 1)[1].split(
            '// No WebUI fallback', 1)[0]
        self.assertIn(".textContentType(nil)", gateway_field)
        self.assertNotIn(".textContentType(.password)", gateway_field)
        login_settings = (root / "Sources" / "HermesShell" /
                          "LoginSettings.swift").read_text()
        self.assertIn(".textContentType(isGateway ? nil : .password)",
                      login_settings)

    def test_settings_declines_real_ios_password_autofill_interruption(self):
        root = Path(__file__).resolve().parents[2]
        harness = (root / "UITests" / "HermesUITestHarness.swift").read_text()
        settings = (root / "UITests" /
                    "HermesSettingsNavigationUITests.swift").read_text()
        # Archived run #45217356011 contains a 60s simulator screen recording.
        # After saving AddInstance, the OS displays Passwords "Save Password?"
        # with actual "Not Now"/"Save" choices, obscuring Settings Done.
        self.assertIn("declineOptionalPasswordSavePrompt", harness)
        self.assertIn('XCUIApplication(bundleIdentifier: "com.apple.springboard")',
                      harness)
        self.assertIn('XCUIApplication(bundleIdentifier: "com.apple.Passwords")',
                      harness)
        self.assertIn('host.buttons["Not Now"]', harness)
        self.assertIn("stage=setup.system_password_declined", harness)
        self.assertIn('stage: "setup.system_password_prompt"', harness)
        self.assertIn("guard declineOptionalPasswordSavePrompt(app)", harness)
        self.assertIn("addUIInterruptionMonitor", settings)
        self.assertIn('alert.buttons["Not Now"]', settings)
        self.assertNotIn('alert.buttons["Save"]', settings)
        self.assertNotIn('host.buttons["Save"]', harness)

    def test_diagnostics_redact_token_and_url(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "ui.log"
            log.write_text(
                "test: error: Bearer token123 https://private.example/sensitive\n",
                encoding="utf-8")
            lines = MODULE.diagnostic_lines(log)
            self.assertEqual(len(lines), 1)
            self.assertNotIn("token123", lines[0])
            self.assertNotIn("private.example", lines[0])


if __name__ == "__main__":
    unittest.main()
