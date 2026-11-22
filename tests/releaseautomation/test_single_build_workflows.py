from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def triggers(text):
    match = re.search(r"(?ms)^on:\s*\n(.*?)(?=^[A-Za-z][A-Za-z0-9_-]*:\s*$)", text)
    if match is None:
        raise AssertionError("workflow has no on trigger block")
    return {
        line.strip().removesuffix(":")
        for line in match.group(1).splitlines()
        if line.startswith("  ") and not line.startswith("    ")
    }


def jobs(text):
    match = re.search(r"(?ms)^jobs:\s*\n((?:  [A-Za-z0-9_-]+:\s*\n(?:    .*\n|      .*\n|        .*\n|          .*\n|            .*\n|              .*\n|                .*\n|                  .*\n|                    .*\n)*)+)", text)
    if match is None:
        raise AssertionError("workflow has no jobs block")
    return re.findall(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", match.group(1))


class SingleBuildWorkflowTests(unittest.TestCase):
    def test_candidate_workflow_builds_and_uploads_once(self):
        path = ROOT / ".github/workflows/hermesshell-single-build.yml"
        text = path.read_text()
        self.assertEqual(triggers(text), {"pull_request", "workflow_dispatch"})
        self.assertEqual(jobs(text), ["preflight", "source", "offline", "candidate"])
        self.assertEqual(text.count("bash scripts/github-build-ipa-main.sh"), 1)
        self.assertEqual(text.count("actions/upload-artifact@"), 2)
        self.assertEqual(text.count("name: hermes-candidate-diagnostics-"), 1)
        self.assertIn("HERMES_WORKFLOW_BLOB_SHA", text)
        self.assertIn("    needs: preflight", text)
        self.assertIn("needs.preflight.outputs.required == 'true'", text)
        self.assertNotIn("publish-candidate.py", text)
        self.assertNotIn("BARK_URL", text)
        self.assertNotIn("contents: write", text)

    def test_maintenance_pr_skips_mac_candidate(self):
        text = (ROOT / ".github/workflows/hermesshell-single-build.yml").read_text()
        preflight = text.split("  preflight:\n", 1)[1].split("\n  source:\n", 1)[0]
        self.assertIn("github.rest.pulls.listFiles", preflight)
        self.assertIn("file.filename === 'release.json'", preflight)
        self.assertIn("core.setOutput('required', 'false')", preflight)
        candidate = text.split("\n  candidate:\n", 1)[1]
        self.assertIn("needs: preflight", candidate)
        self.assertIn("needs.preflight.outputs.required == 'true'", candidate)

    def test_candidate_concurrency_cancels_stale_pr_builds(self):
        text = (ROOT / ".github/workflows/hermesshell-single-build.yml").read_text()
        concurrency = re.search(
            r"(?ms)^concurrency:\s*\n((?:  .*\n)+)",
            text,
        )
        self.assertIsNotNone(concurrency)
        block = concurrency.group(1)
        self.assertIn("github.event.pull_request.number || github.run_id", block)
        self.assertNotIn("github.sha", block)
        self.assertIn(
            "cancel-in-progress: ${{ github.event_name == 'pull_request' && github.run_attempt == 1 }}",
            block,
        )

    def test_diagnostics_are_whitelisted_and_do_not_change_candidate_contract(self):
        text = (ROOT / ".github/workflows/hermesshell-single-build.yml").read_text()
        diagnostics_report = text.split("Write candidate diagnostics report", 1)[1].split(
            "Upload candidate diagnostics", 1
        )[0]
        diagnostics = text.split("Upload candidate diagnostics", 1)[1]
        self.assertIn("HERMES_IDENTITY_RESULT", diagnostics_report)
        self.assertIn("HERMES_ENFORCE_RESULT", diagnostics_report)
        self.assertIn("HERMES_RECORD_RESULT", diagnostics_report)
        self.assertIn("hermes-candidate-diagnostics-export/*", diagnostics)
        self.assertNotIn("${{ runner.temp }}/hermes-candidate-diagnostics/*", diagnostics)
        self.assertNotIn("${{ runner.temp }}/*", diagnostics)
        candidate_upload = text.split("Upload immutable candidate", 1)[1].split(
            "Record candidate result", 1
        )[0]
        self.assertNotIn("hermes-candidate-diagnostics", candidate_upload)
        self.assertIn("${{ runner.temp }}/hermes-candidate-release/*", candidate_upload)
        self.assertIn("continue-on-error: true", diagnostics)
        self.assertIn("if: ${{ !cancelled() }}", diagnostics)
        self.assertIn("overwrite: false", diagnostics)
        self.assertIn("retention-days: 7", diagnostics)
        self.assertIn("id: enforce", text)
        self.assertIn("id: record", text)
        self.assertGreater(
            text.index("Record candidate result"),
            text.index("Upload immutable candidate"),
        )
        self.assertGreater(
            text.index("Write candidate diagnostics report"),
            text.index("Record candidate result"),
        )
        self.assertNotIn("if: ${{ always() }}", text)

    def test_simulator_shards_use_independent_runners_and_aggregate_status(self):
        workflow = (ROOT / ".github/workflows/simulator-probe.yml").read_text()
        self.assertIn("shard: [chat, experience]", workflow)
        self.assertIn("fail-fast: false", workflow)
        self.assertIn("name: simulator-${{ matrix.shard }}", workflow)
        self.assertIn("HermesLongTaskRecoveryUITests", workflow)
        self.assertIn("TEST_SHARD: ${{ matrix.shard }}", workflow)
        self.assertIn("name: Aggregate isolated UI shards", workflow)
        self.assertIn("needs: simulator", workflow)
        self.assertIn("context: 'hermes/simulator-all'", workflow)
        self.assertIn("if (!passed) core.setFailed", workflow)
        self.assertIn("hermes-ui-evidence-${{ github.run_id }}-${{ matrix.shard }}", workflow)

    def test_promotion_workflow_never_compiles(self):
        path = ROOT / ".github/workflows/hermesshell-single-promote.yml"
        text = path.read_text()
        self.assertEqual(triggers(text), {"push", "workflow_dispatch"})
        self.assertEqual(jobs(text), ["plan", "promote", "notify", "issue-sync", "ui-discovery"])
        self.assertNotIn("tests/run_container.sh", text)
        self.assertNotIn("tests/verify_source.py", text)
        self.assertIn("actions/artifacts/${ARTIFACT_ID}/zip", text)
        self.assertNotIn("uses: actions/download-artifact@", text)
        self.assertIn("publish-candidate.py", text)
        self.assertNotIn("github-build-ipa", text)
        self.assertNotIn("xcodegen", text)
        self.assertNotIn("xcodebuild", text)
        self.assertIn("Sync GitHub Issues with verified Release", text)

    def test_verified_automerge_is_gated_and_dispatches_without_rebuild(self):
        workflow = (ROOT / ".github/workflows/verified-release-automerge.yml").read_text()
        self.assertEqual(triggers(workflow), {"workflow_run", "pull_request_target"})
        self.assertNotIn("      - Hermes iOS Simulator UI regression", workflow)
        self.assertIn("const workflows = ['HermesBuild single-build candidate']", workflow)
        self.assertIn("types: [unlabeled, ready_for_review, reopened]", workflow)
        self.assertIn("github.event.pull_request.head.sha", workflow)
        self.assertIn("return abort('Privileged or non-product PR: intentional manual merge", workflow)
        self.assertNotIn("return blocked('PR touches non-product or privileged files", workflow)
        self.assertIn("path.startsWith('tests/')", workflow)
        self.assertIn("!path.startsWith('tests/releaseautomation/')", workflow)
        self.assertIn("!path.startsWith('tests/sourcegate/')", workflow)
        self.assertNotIn("path.startsWith('tests/run_container.sh')", workflow)
        runner = (ROOT / "tests/run_container.sh").read_text()
        self.assertIn("tests/model/*.swift", runner)
        self.assertNotIn("tests/model/AutomaticReconciliationTests.swift", runner)
        for required in ("github.event.workflow_run.conclusion == 'success'",
                         "head_sha: sha", "no-auto-release",
                         "latest.conclusion !== 'success'", "expected_sha",
                         "previous_sha", "createWorkflowDispatch", "merge_method: 'squash'"):
            self.assertIn(required, workflow)
        self.assertNotIn("actions/checkout@", workflow)
        self.assertNotIn("github-build-ipa", workflow)
        promote = (ROOT / ".github/workflows/hermesshell-single-promote.yml").read_text()
        self.assertIn("expected_sha:", promote)
        self.assertIn("name: Dispatch post-release simulator discovery", promote)
        self.assertIn('gh workflow run simulator-probe.yml --repo "$GITHUB_REPOSITORY" --ref main -f suite=all', promote)
        self.assertIn("previous_sha:", promote)
        plan = (ROOT / "scripts/release-plan.py").read_text()
        self.assertIn("before != parent", plan)

    def test_removed_legacy_build_entries_stay_absent(self):
        removed = (
            ".github/workflows/hermesshell-adaptive-release.yml",
            "scripts/build-on-9.ps1",
            "scripts/release-local.sh",
            "scripts/github-build-ipa.sh",
            "scripts/publish-release.py",
            "scripts/repro-check.sh",
            "scripts/github-publish-release.sh",
            "ci/ci-build.sh",
            "ci/ci-verify.sh",
            "ci/publish-direct-release.sh",
            "tests/run_native.sh",
            "tests/core/run.sh",
            "tests/discovery/run.sh",
            "tests/attachments/run.sh",
            "xtool.yml",
        )
        for relative in removed:
            with self.subTest(relative=relative):
                self.assertFalse((ROOT / relative).exists())

    def test_guidance_names_only_current_release_paths(self):
        guidance = "\n".join(
            (ROOT / path).read_text(encoding="utf-8")
            for path in (
                "README.md",
                "AGENTS.md",
                "docs/github-collaboration.md",
                "docs/backlog.md",
            )
        )
        for forbidden in (
            "HERMES_TEST_TARGET",
            "HERMES_BUILD_TARGET",
            "HERMES_BUILD_PROJECTS",
            "scripts/release-local.sh",
            "scripts/build-on-9.ps1",
            "scripts/github-build-ipa.sh",
            "hermesshell-adaptive-release.yml",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, guidance)
        self.assertIn("hermesshell-single-build.yml", guidance)
        self.assertIn("hermesshell-single-promote.yml", guidance)
        self.assertIn("without compiling again", guidance)
        self.assertIn("historical", guidance.lower())
        self.assertIn("not instructions", guidance.lower())

    def test_workflow_referenced_scripts_exist(self):
        workflow = (ROOT / ".github/workflows/hermesshell-single-build.yml").read_text()
        for relative in re.findall(r"scripts/[A-Za-z0-9._/-]+", workflow):
            with self.subTest(relative=relative):
                self.assertTrue((ROOT / relative).is_file(), relative)

    def test_job_env_does_not_use_runner_context(self):
        workflow = (ROOT / ".github/workflows/hermesshell-single-build.yml").read_text()
        candidate = workflow.split("\n  candidate:\n", 1)[1]
        before_steps = candidate.split("\n    steps:\n", 1)[0]
        self.assertNotIn("${{ runner.", before_steps)


if __name__ == "__main__":
    unittest.main()
