import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "release_plan", ROOT / "scripts/release-plan.py"
)
planner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(planner)


class ReleasePlanTests(unittest.TestCase):
    def setUp(self):
        self.old = {"version": "2.28.0", "build": "174"}
        self.new = {"version": "2.29.0", "build": "175"}

    def test_new_main_identity_releases(self):
        self.assertEqual(
            planner.plan(self.new, self.old, "push", "refs/heads/main")["release"],
            "true",
        )

    def test_maintenance_and_note_changes_do_not_release(self):
        same = dict(self.old, _note="updated documentation")
        self.assertEqual(
            planner.plan(same, self.old, "push", "refs/heads/main")["release"],
            "false",
        )

    def test_build_only_increment_is_supported(self):
        current = {"version": "2.28.0", "build": "175"}
        self.assertEqual(
            planner.plan(current, self.old, "push", "refs/heads/main")["release"],
            "true",
        )

    def test_pull_request_manual_and_other_branch_never_publish(self):
        for event, ref in (
            ("pull_request", "refs/pull/14/merge"),
            ("workflow_dispatch", "refs/heads/main"),
            ("push", "refs/heads/topic"),
        ):
            with self.subTest(event=event, ref=ref):
                self.assertEqual(
                    planner.plan(self.new, None, event, ref)["release"], "false"
                )

    def test_missing_base_rollback_and_output_injection_fail_closed(self):
        invalid = (
            (self.new, None),
            ({"version": "2.27.0", "build": "175"}, self.old),
            ({"version": "2.29.0", "build": "174"}, self.old),
            ({"version": "2.29.0\nrelease=true", "build": "175"}, self.old),
        )
        for current, previous in invalid:
            with self.subTest(current=current, previous=previous):
                with self.assertRaises(ValueError):
                    planner.plan(current, previous, "push", "refs/heads/main")


if __name__ == "__main__":
    unittest.main()
