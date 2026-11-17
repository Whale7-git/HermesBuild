#!/usr/bin/env python3
"""Once-only queued-macOS cancel + re-run, from trusted default-branch code."""
from __future__ import annotations

import datetime as dt
import json
import os
import sys
import time
from urllib import error, parse, request

REPO = "Whale7-git/HermesBuild"
WORKFLOW = ".github/workflows/hermesshell-single-build.yml"
CANDIDATE = "Compile and upload one candidate IPA"
OTHER_JOBS = {"Source and release plan", "Swift offline regression"}
QUEUE_SECONDS = 180
MAX_MONITOR_SECONDS = 1080
MAX_ATTEMPTS = 3
POLL_SECONDS = 10


def timestamp(value: str) -> float:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


class GitHub:
    def __init__(self, repository: str, token: str):
        self.repository = repository
        self.token = token

    def api(self, endpoint: str, method: str = "GET") -> dict:
        url = f"https://api.github.com/repos/{self.repository}/{endpoint}"
        req = request.Request(url, method=method, headers={
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "hermes-queued-candidate-watchdog",
        })
        try:
            with request.urlopen(req, timeout=25) as response:
                body = response.read()
                return json.loads(body) if body else {}
        except error.HTTPError as exc:
            # No tokens, headers, or untrusted GitHub bodies in diagnostics.
            raise RuntimeError(
                f"GitHub {method} {endpoint} returned HTTP {exc.code}"
            ) from exc


def run_is_target(run: dict, run_id: int) -> bool:
    return (
        run.get("id") == run_id
        and run.get("event") == "pull_request"
        and run.get("path") == WORKFLOW
        and isinstance(run.get("run_attempt"), int)
        and 1 <= run["run_attempt"] <= MAX_ATTEMPTS
        and (run.get("repository") or {}).get("full_name") == REPO
        and isinstance(run.get("head_sha"), str)
        and len(run["head_sha"]) == 40
    )


def same_open_pr(client: GitHub, run: dict) -> bool:
    prs = run.get("pull_requests") or []
    if len(prs) != 1 or not isinstance(prs[0].get("number"), int):
        return False
    pr = client.api(f"pulls/{prs[0]['number']}")
    return (
        pr.get("state") == "open"
        and (pr.get("base") or {}).get("ref") == "main"
        and (pr.get("head") or {}).get("sha") == run.get("head_sha")
        and ((pr.get("head") or {}).get("repo") or {}).get("full_name") == REPO
    )


def candidate_waiting(jobs: list[dict], now: float) -> bool:
    by_name = {job.get("name"): job for job in jobs}
    if len(jobs) != 3 or len(by_name) != 3:
        return False
    if not OTHER_JOBS.issubset(by_name) or CANDIDATE not in by_name:
        return False
    if any(
        by_name[name].get("status") != "completed"
        or by_name[name].get("conclusion") != "success"
        for name in OTHER_JOBS
    ):
        return False
    candidate = by_name[CANDIDATE]
    if candidate.get("status") != "queued" or candidate.get("started_at") is not None:
        return False
    created = candidate.get("created_at")
    if not isinstance(created, str):
        return False
    elapsed = now - timestamp(created)
    return QUEUE_SECONDS <= elapsed <= MAX_MONITOR_SECONDS + 120


def send_bark(url: str, run_id: int, reason: str) -> bool:
    """Best-effort single alert. Never print URL, token or response body."""
    if not url:
        print("warning: BARK_URL unavailable; queue alert skipped")
        return False
    target = f"https://github.com/{REPO}/actions/runs/{run_id}"
    body = parse.urlencode({
        "title": "HermesBuild macOS 排队异常",
        "body": f"候选构建三轮各等待约 3 分钟仍未开始；{reason}。请检查 GitHub Actions Runner。",
        "url": target,
        "group": "hermes-ci",
    }).encode()
    try:
        with request.urlopen(request.Request(url, data=body, method="POST"),
                             timeout=20) as response:
            payload = json.loads(response.read())
            success = response.status == 200 and payload.get("code") == 200
            print("BARK_SENT queue_watchdog" if success else "warning: Bark rejected queue alert")
            return success
    except (OSError, ValueError, TypeError):
        print("warning: Bark queue alert delivery failed")
        return False


def monitor(client: GitHub, run_id: int, now=time.time, sleep=time.sleep,
            alert=None) -> str:
    """Track attempts 1-3 in one workflow_run.requested invocation.

    A re-run does not trigger another workflow_run.requested event.
    Only queued macOS jobs may be cancelled; never interrupt compilation.
    """
    first = client.api(f"actions/runs/{run_id}")
    if not run_is_target(first, run_id) or first["run_attempt"] != 1:
        return "skip: not an initial same-repository PR candidate"
    deadline = timestamp(first["created_at"]) + MAX_MONITOR_SECONDS
    retries = 0
    while now() < deadline:
        run = client.api(f"actions/runs/{run_id}")
        if not run_is_target(run, run_id):
            return "skip: run identity changed"
        attempt = run["run_attempt"]
        if attempt != retries + 1:
            if attempt <= retries:
                sleep(POLL_SECONDS)
                continue
            return "skip: unexpected attempt transition"
        if run.get("status") == "completed":
            return "skip: candidate run completed"
        if run.get("status") not in ("queued", "in_progress", "requested", "pending", "waiting"):
            return "skip: unexpected run status"
        jobs = client.api(f"actions/runs/{run_id}/jobs?per_page=100").get("jobs", [])
        by_name = {job.get("name"): job for job in jobs}
        if by_name.get(CANDIDATE, {}).get("status") in ("in_progress", "completed"):
            return "ok: macOS started or finished"
        if any(by_name.get(name, {}).get("status") == "completed"
               and by_name[name].get("conclusion") != "success"
               for name in OTHER_JOBS):
            return "skip: source or offline checks failed"
        if not candidate_waiting(jobs, now()):
            sleep(min(POLL_SECONDS, max(0, deadline - now())))
            continue
        if not same_open_pr(client, run):
            return "skip: PR closed, forked, or head changed"
        fresh = client.api(f"actions/runs/{run_id}")
        fresh_jobs = client.api(f"actions/runs/{run_id}/jobs?per_page=100").get("jobs", [])
        if (not run_is_target(fresh, run_id)
                or fresh.get("run_attempt") != attempt
                or fresh.get("status") == "completed"
                or not candidate_waiting(fresh_jobs, now())):
            return "skip: macOS started or run changed on recheck"
        if attempt == MAX_ATTEMPTS:
            if alert:
                alert(run_id, "第三次排队超过 180 秒")
            return "alert: third macOS queue window elapsed; no more retries"
        client.api(f"actions/runs/{run_id}/cancel", method="POST")
        cancelled = False
        for _ in range(30):
            state = client.api(f"actions/runs/{run_id}")
            if not run_is_target(state, run_id) or state["run_attempt"] != attempt:
                return "skip: attempt changed during cancellation"
            if state.get("status") == "completed":
                if state.get("conclusion") != "cancelled":
                    return "skip: cancellation did not produce cancelled"
                cancelled = True
                break
            sleep(5)
        if not cancelled:
            return "skip: cancellation did not finish"
        if not same_open_pr(client, state):
            return "skip: PR changed before retry"
        client.api(f"actions/runs/{run_id}/rerun", method="POST")
        retries += 1
        print(f"QUEUE_RETRY_REQUESTED attempt={attempt + 1} run={run_id}")
        # GitHub updates run_attempt asynchronously; wait for the next attempt.
        # Keep monitoring this same run ID rather than expecting a fresh event.
        sleep(POLL_SECONDS)
    if alert and retries == 2:
        alert(run_id, "监控已达到安全时间上限")
        return "alert: monitor deadline after two retries"
    return "skip: monitor deadline"

def main() -> int:
    if os.environ.get("GITHUB_REPOSITORY") != REPO:
        print("skip: different repository")
        return 0
    if os.environ.get("GITHUB_EVENT_NAME") != "workflow_run":
        print("skip: not workflow_run")
        return 0
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as source:
        event = json.load(source)
    if event.get("action") != "requested":
        print("skip: reruns do not trigger this monitor")
        return 0
    run_id = (event.get("workflow_run") or {}).get("id")
    if not isinstance(run_id, int) or run_id <= 0:
        print("skip: no originating run")
        return 0
    token = os.environ.get("GH_TOKEN")
    if not token:
        raise RuntimeError("watchdog requires job GITHUB_TOKEN actions:write")
    outcome = monitor(GitHub(REPO, token), run_id,
                      alert=lambda rid, reason: send_bark(os.environ.get("BARK_URL", ""), rid, reason))
    print(outcome)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as summary:
            summary.write(
                f"### Candidate queue watchdog\n\n"
                f"- Run ID: {run_id}\n- Outcome: {outcome}\n"
            )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"QUEUE_WATCHDOG_FAILED: {exc}", file=sys.stderr)
        sys.exit(1)
