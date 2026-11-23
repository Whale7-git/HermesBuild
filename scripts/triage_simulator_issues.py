#!/usr/bin/env python3
"""Trusted workflow_run triage: treat simulator artifacts as untrusted DATA.

Create/update one GitHub issue per failing XCTest case. Environment/runner
failures use a separate infrastructure fingerprint. No PR code is executed.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request

MAX_FILES = 12
MAX_BYTES = 16384
TEST_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z_0-9]*\.test[A-Za-z_0-9]{1,120}$")
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")


def api(method: str, path: str, data: dict | None = None) -> dict:
    payload = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(
        "https://api.github.com" + path,
        data=payload,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + os.environ["GH_TOKEN"],
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=25) as response:
        return json.loads(response.read(1024 * 1024))


def safe_assertion(text: str) -> str:
    # Public issues must not quote arbitrary mock-gateway request bodies.
    text = text.rsplit("error:", 1)[-1].strip()
    text = re.sub(r"https?://\S+", "[url]", text)
    text = re.sub(r"(?i)(bearer|token|password|api[_-]?key)\s*[:= ]\s*\S+",
                  "[redacted]", text)
    text = re.sub(r"[^\x20-\x7e]", " ", text)
    return text[:220]


def load_reports(root: Path, run_id: str, sha: str) -> list[dict]:
    result = []
    if not root.is_dir():
        return result
    paths = sorted(root.glob("hermes-ui-triage-*/*simulator-report.json"))
    for path in paths[:MAX_FILES]:
        if not path.is_file() or path.stat().st_size > MAX_BYTES:
            continue
        try:
            item = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, ValueError):
            continue
        if not isinstance(item, dict) or str(item.get("run_id")) != run_id:
            continue
        if item.get("schema") == 2:
            if item.get("harness_sha") != sha or not SHA_PATTERN.fullmatch(
                str(item.get("source_sha", ""))):
                continue
            cases = item.get("cases")
            if not isinstance(cases, list) or len(cases) > 25:
                continue
            valid = []
            for case in cases:
                if (isinstance(case, dict) and
                        TEST_PATTERN.fullmatch(str(case.get("test", ""))) and
                        case.get("status") in {"PASS", "FAIL", "BLOCKED", "INFRA_ERROR"}):
                    valid.append({"test": case["test"], "status": case["status"],
                                  "diagnostics": [safe_assertion(str(x))
                                      for x in case.get("diagnostics", [])[:3]
                                      if isinstance(x, str)] if isinstance(
                                          case.get("diagnostics", []), list) else []})
            item["cases"] = valid
            result.append(item)
            continue
        if (item.get("schema") != 1 or item.get("sha") != sha or
                item.get("shard") not in {"chat", "experience"}):
            continue
        tests = item.get("failed_tests")
        if not isinstance(tests, list):
            continue
        item["failed_tests"] = [x for x in tests[:30] if
                                isinstance(x, str) and TEST_PATTERN.fullmatch(x)]
        assertions = item.get("assertions", [])
        item["assertions"] = ([safe_assertion(x) for x in assertions[:15]
                               if isinstance(x, str)] if isinstance(assertions, list) else [])
        result.append(item)
    return result


def find_issue(repo: str, marker: str) -> dict | None:
    query = urllib.parse.quote(f'repo:{repo} is:issue "{marker}"')
    found = api("GET", f"/search/issues?q={query}&per_page=30")
    for item in found.get("items", []):
        if marker in (item.get("body") or "") and "pull_request" not in item:
            return item
    return None


def upsert(repo: str, key: str, title: str, detail: str, run_id: str) -> None:
    marker = f"simulator-key:{key}"
    existing = find_issue(repo, marker)
    if existing:
        number = existing["number"]
        # Idempotent on action retries, with bounded comment lookup.
        comments = api("GET", f"/repos/{repo}/issues/{number}/comments?per_page=100")
        if run_id not in (existing.get("body") or "") and not any(
            run_id in (comment.get("body") or "") for comment in comments
        ):
            api("POST", f"/repos/{repo}/issues/{number}/comments", {"body": detail})
        print(f"Updated issue #{number}: {title}")
    else:
        body = (f"<!-- {marker} -->\n"
                "Detected by independent Hermes simulator regression.\n\n"
                + detail + "\n\n"
                "A failing test is evidence requiring triage, not proof of a production defect. "
                "Confirm the behavior and record the fix PR before closing.")
        issue = api("POST", f"/repos/{repo}/issues",
                    {"title": title[:180], "body": body})
        print(f"Created issue #{issue['number']}: {title}")



def append_exact_issue(repo: str, number: int, detail: str, run_id: str) -> None:
    # A post-release PASS is evidence, not permission to auto-close an Issue.
    history = api("GET", f"/repos/{repo}/issues/{number}/comments?per_page=100")
    marker = f"<!-- simulator-verification:{run_id}:{number} -->"
    if any(marker in (row.get("body") or "") for row in history):
        return
    api("POST", f"/repos/{repo}/issues/{number}/comments",
        {"body": marker + "\n" + detail})


def triage_versioned(repo: str, report: dict, run_id: str, run_url: str) -> None:
    source = report["source_sha"]
    harness = report["harness_sha"]
    issue_for = {
        "HermesGoldUITests.test02SendStreamAndComplete": 86,
        "HermesGoldUITests.test04StreamingManualReadingKeepsAnchor": 85,
    }
    cases = report["cases"]
    if not cases:
        if report.get("outcome") == "INFRA_ERROR":
            key = hashlib.sha256(b"simulator:unclassified-infrastructure").hexdigest()[:20]
            detail = (f"- Status: INFRA_ERROR before XCTest\n- Product SHA: \x60{source}\x60"
                      f"\n- Harness SHA: \x60{harness}\x60\n- CI run: {run_url}"
                      "\n- Fixture/build/simulator environment must be investigated; not a product PASS.")
            upsert(repo, key, "[simulator-ci] Unclassified simulator run failure",
                   detail, run_id)
        return
    for case in cases:
        test = case["test"]
        status = case["status"]
        diagnosis = "; ".join(case["diagnostics"]) or "See xcresult artifact"
        detail = (f"- Test: \x60{test}\x60\n- Verdict: **{status}**"
                  f"\n- Product SHA: \x60{source}\x60"
                  f"\n- Trusted harness SHA: \x60{harness}\x60"
                  f"\n- CI run: {run_url}\n- Diagnostics: {diagnosis}"
                  "\n- A PASS proves this simulator case only; it does not "
                  "prove live Gateway/device completion or close this Issue.")
        if test in issue_for:
            append_exact_issue(repo, issue_for[test], detail, run_id)
        elif status != "PASS":
            key = hashlib.sha256(("test:" + test).encode()).hexdigest()[:20]
            upsert(repo, key, f"[simulator] {test}", detail, run_id)

def main() -> None:
    repo = os.environ["GITHUB_REPOSITORY"]
    run_id = os.environ["SIMULATOR_RUN_ID"]
    sha = os.environ["SIMULATOR_HEAD_SHA"]
    assert re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo)
    assert run_id.isdecimal() and SHA_PATTERN.fullmatch(sha)
    reports = load_reports(Path(os.environ["SIMULATOR_REPORT_DIR"]), run_id, sha)
    run_url = f"https://github.com/{repo}/actions/runs/{run_id}"
    seen = set()
    versioned = [report for report in reports if report.get("schema") == 2]
    if versioned:
        for report in versioned:
            triage_versioned(repo, report, run_id, run_url)
        return
    for report in reports:
        for testcase in report["failed_tests"]:
            key = hashlib.sha256(("test:" + testcase).encode()).hexdigest()[:20]
            if key in seen:
                continue
            seen.add(key)
            assertion = "; ".join(report["assertions"][:3]) or "See XCTest artifact"
            detail = (f"- Failed test: `{testcase}`\n"
                      f"- Shard: `{report['shard']}`\n"
                      f"- Tested commit: `{sha}`\n"
                      f"- CI run: {run_url}\n"
                      f"- Failure evidence: {assertion}")
            upsert(repo, key, f"[simulator] {testcase}", detail, run_id)
    if not seen:
        # Keep infrastructure/test-harness failures distinct from app bugs.
        key = hashlib.sha256(b"simulator:unclassified-infrastructure").hexdigest()[:20]
        detail = (f"- Test/run status: failure without a validated failed XCTest case\n"
                  f"- Tested commit: `{sha}`\n- CI run: {run_url}\n"
                  "- Check runner, mock Gateway, simulator boot, artifacts and test harness.")
        upsert(repo, key, "[simulator-ci] Unclassified simulator run failure",
               detail, run_id)


if __name__ == "__main__":
    main()
