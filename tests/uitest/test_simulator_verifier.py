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
        self.assertEqual(MODULE.cases_for_suite("gold")[0], MODULE.BOOTSTRAP)
        self.assertEqual(len(MODULE.cases_for_suite("gold")), 5)
        self.assertEqual(MODULE.cases_for_suite("all")[0], MODULE.BOOTSTRAP)
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
        self.assertIn('connectionPage.buttons[title]', source)
        self.assertIn('["设置", "返回", "Back"]', source)
        self.assertIn('app.navigationBars["设置"]', source)
        self.assertIn("done.tap()", source)
        self.assertIn('stage: "setup.return_settings_root"', source)
        self.assertIn('stage: "setup.dismiss_settings"', source)
        self.assertIn("recordSetupFailure", source)
        self.assertNotIn("for label in app.staticTexts.allElementsBoundByIndex", source)

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
