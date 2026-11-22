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
        self.assertEqual(jobs(text), ["candidate"])
        self.assertEqual(text.count("bash scripts/github-build-ipa-main.sh"), 1)
        self.assertEqual(text.count("actions/upload-artifact@"), 2)
        self.assertIn("HERMES_WORKFLOW_BLOB_SHA", text)
        self.assertNotRegex(text, r"(?m)^    needs:")
        self.assertNotIn("tests/run_container.sh", text)
        self.assertNotIn("tests/verify_source.py", text)
        self.assertNotIn("publish-candidate.py", text)
        self.assertNotIn("BARK_URL", text)
        self.assertNotIn("contents: write", text)

    def test_nonblocking_diagnostics_four_shards(self):
        diagnostics = (ROOT / ".github/workflows/hermes-offline-diagnostics.yml").read_text()
        self.assertEqual(triggers(diagnostics), {"pull_request", "workflow_dispatch"})
        self.assertEqual(jobs(diagnostics), ["source", "offline_shards", "offline"])
        self.assertIn("shard: [core, recovery, interface, media]", diagnostics)
        self.assertIn("fail-fast: false", diagnostics)
        self.assertIn("HERMES_TEST_SHARD: ${{ matrix.shard }}", diagnostics)
        self.assertIn("needs: [source, offline_shards]", diagnostics)
        self.assertIn('test "$SOURCE_RESULT" = success', diagnostics)
        self.assertIn('test "$SHARDS_RESULT" = success', diagnostics)
        # Failure is visible in this separate workflow, never in candidate.
        candidate = (ROOT / ".github/workflows/hermesshell-single-build.yml").read_text()
        self.assertNotIn("needs: offline_shards", candidate)
        self.assertNotIn("hermes-offline-diagnostics.yml", candidate)

    def test_offline_shard_partition_is_exhaustive(self):
        runner = (ROOT / "tests/run_container.sh").read_text()
        declared = re.findall(r"(?m)^run ([a-z0-9]+) ", runner)
        mapping = re.findall(
            r"(?m)^    ([a-z0-9|]+)\) echo (core|recovery|interface|media) ;;",
            runner,
        )
        self.assertEqual(len(mapping), 4)
        assigned = [name for names, _ in mapping for name in names.split("|")]
        self.assertEqual(len(declared), 51)
        self.assertEqual(len(declared), len(set(declared)))
        self.assertEqual(len(assigned), len(set(assigned)))
        self.assertEqual(set(declared), set(assigned))
        extras = re.findall(
            r"(?m)^run_extra (core|recovery|interface|media) ([a-z0-9-]+) ",
            runner,
        )
        self.assertEqual(
            {name for _, name in extras},
            {"renderpipeline", "textualprimitives", "attachments",
             "selectionactivity", "gatewaybackend", "uitest-contract"},
        )
        self.assertEqual(len(extras), 6)
        self.assertIn("HERMES_OFFLINE_TESTS_PASS shard=$SHARD", runner)
        self.assertIn('with_deadline "$EXEC_LIMIT"', runner)
        self.assertIn('with_deadline "$COMPILE_LIMIT"', runner)

    def test_obsolete_source_hash_inventory_is_not_executed(self):
        workflow = (ROOT / ".github/workflows/hermesshell-single-build.yml").read_text()
        runner = (ROOT / "tests/run_container.sh").read_text()
        self.assertNotIn("tests/verify_source.py", workflow)
        self.assertNotIn("tests/sourcegate/main.py", runner)
        self.assertIn("tests/check_release_identity.py", (ROOT / ".github/workflows/hermes-offline-diagnostics.yml").read_text())
        for old in ("tests/verify_source.py", "tests/gen_release_scope.py",
                    "tests/sourcegate/main.py"):
            self.assertFalse((ROOT / old).exists(), old)

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

    def test_simulator_is_manual_only_and_does_not_set_release_status(self):
        workflow = (ROOT / ".github/workflows/simulator-probe.yml").read_text()
        self.assertEqual(triggers(workflow), {"workflow_dispatch"})
        self.assertNotIn("  pull_request:", workflow)
        self.assertNotIn("  schedule:", workflow)
        self.assertNotIn("statuses: write", workflow)
        self.assertNotIn("simulator-result:", workflow)
        self.assertNotIn("Record exact-commit simulator gold result", workflow)
        self.assertIn("shard: [chat, experience]", workflow)
        self.assertIn("fail-fast: false", workflow)
        self.assertIn("HermesLongTaskRecoveryUITests", workflow)
        self.assertIn("TEST_SHARD: ${{ matrix.shard }}", workflow)
        self.assertIn("hermes-ui-evidence-${{ github.run_id }}-${{ matrix.shard }}", workflow)

    def test_promotion_workflow_never_compiles(self):
        path = ROOT / ".github/workflows/hermesshell-single-promote.yml"
        text = path.read_text()
        self.assertEqual(triggers(text), {"push", "workflow_dispatch"})
        self.assertEqual(jobs(text), ["plan", "promote", "notify", "issue-sync"])
        self.assertNotIn("tests/run_container.sh", text)
        self.assertNotIn("tests/verify_source.py", text)
        self.assertIn("actions/artifacts/${ARTIFACT_ID}/zip", text)
        self.assertNotIn("uses: actions/download-artifact@", text)
        self.assertIn("publish-candidate.py", text)
        self.assertNotIn("github-build-ipa", text)
        self.assertNotIn("xcodegen", text)
        self.assertNotIn("xcodebuild", text)
        self.assertIn("Sync GitHub Issues with verified Release", text)

    def test_auto_release_uses_candidate_only_not_quality_gates(self):
        workflow = (ROOT / ".github/workflows/verified-release-automerge.yml").read_text()
        self.assertEqual(triggers(workflow), {"workflow_run"})
        self.assertIn("HermesBuild single-build candidate", workflow)
        self.assertIn("conclusion == 'success'", workflow)
        self.assertIn("getWorkflowRun", workflow)
        self.assertNotIn("Required exact-head workflow incomplete", workflow)
        self.assertNotIn("Missing changed full-batch acceptance matrix", workflow)
        self.assertNotIn("matrix.issues", workflow)
        self.assertNotIn("['hold', 'no-auto-release']", workflow)
        self.assertIn("return skip('privileged or maintenance-only PR')", workflow)
        self.assertIn("merge_method: 'squash'", workflow)
        self.assertIn("createWorkflowDispatch", workflow)
        self.assertIn("expected_sha", workflow)
        self.assertIn("previous_sha", workflow)
        self.assertNotIn("actions/checkout@", workflow)
        self.assertNotIn("github-build-ipa", workflow)
        runner = (ROOT / "tests/run_container.sh").read_text()
        self.assertIn("tests/model/*.swift", runner)
        self.assertNotIn("tests/model/AutomaticReconciliationTests.swift", runner)
        promote = (ROOT / ".github/workflows/hermesshell-single-promote.yml").read_text()
        self.assertIn("expected_sha:", promote)
        self.assertNotIn("ui-discovery:", promote)
        self.assertNotIn("workflow run simulator-probe.yml", promote)
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
        self.assertIn("hermes-offline-diagnostics.yml", guidance)
        self.assertIn("nonblocking", guidance.lower())
        self.assertIn("historical", guidance.lower())
        self.assertNotIn("tests/gen_release_scope.py", guidance)

    def test_documentation_has_one_authoritative_rules_source(self):
        agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        collaboration = (ROOT / "docs/github-collaboration.md").read_text(encoding="utf-8")
        template = (ROOT / ".github/pull_request_template.md").read_text(encoding="utf-8")
        self.assertIn("Candidate and Release", agents)
        self.assertIn("权威规则来源", readme)
        self.assertIn("唯一权威规则来源", collaboration)
        self.assertIn("唯一权威来源", template)

    def test_reference_docs_do_not_masquerade_as_current_gateway_contracts(self):
        sse = (ROOT / "docs/sse-contract.md").read_text(encoding="utf-8")
        ui = (ROOT / "tests/uitest/README.md").read_text(encoding="utf-8")
        manual = (ROOT / "tests/manual-master.md").read_text(encoding="utf-8")
        self.assertIn("不是当前 API 契约", sse)
        self.assertIn("单次历史抓包", sse)
        self.assertIn("127.0.0.1", ui)
        self.assertIn("mock_gateway.py", ui)
        self.assertIn("fixtures/", ui)
        self.assertNotIn("GET /api/sessions", ui)
        self.assertIn("不是每次提交或发版的必跑清单", manual)

    def test_obsolete_historical_documents_removed(self):
        for relative in (
            "docs/perf-baseline-build131.json",
            "docs/gateway-backend-spec.md",
            "docs/backlog.md",
        ):
            with self.subTest(relative=relative):
                self.assertFalse((ROOT / relative).exists())
        for required in (
            "docs/sse-contract.md",
            "tests/manual-master.md",
            "ci/toolchain-baseline.json",
        ):
            with self.subTest(required=required):
                self.assertTrue((ROOT / required).is_file())

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
