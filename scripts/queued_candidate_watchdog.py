#!/usr/bin/env python3
"""Once-only queued-macOS cancel + re-run, from trusted default-branch code."""
from __future__ import annotations

import datetime as dt
import json
import os
import sys
import time
from urllib import error, request

REPO = "Whale7-git/HermesBuild"
WORKFLOW = ".github/workflows/hermesshell-single-build.yml"
CANDIDATE = "Compile and upload one candidate IPA"
OTHER_JOBS = {"Source and release plan", "Swift offline regression"}
QUEUE_SECONDS = 180
MAX_MONITOR_SECONDS = 600
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
        and run.get("run_attempt") == 1
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


def monitor(client: GitHub, run_id: int, now=time.time, sleep=time.sleep) -> str:
    first = client.api(f"actions/runs/{run_id}")
    if not run_is_target(first, run_id):
        return "skip: not an initial same-repository PR candidate"
    deadline = timestamp(first["created_at"]) + MAX_MONITOR_SECONDS
    while now() < deadline:
        run = client.api(f"actions/runs/{run_id}")
        if not run_is_target(run, run_id) or run.get("status") == "completed":
            return "skip: run finished or identity changed"
        if run.get("status") not in (
            "queued", "in_progress", "requested", "pending", "waiting"
        ):
            return "skip: unexpected run status"
        jobs = client.api(f"actions/runs/{run_id}/jobs?per_page=100").get("jobs", [])
        if candidate_waiting(jobs, now()):
            if not same_open_pr(client, run):
                return "skip: PR closed, forked, or head changed"
            fresh = client.api(f"actions/runs/{run_id}")
            fresh_jobs = client.api(
                f"actions/runs/{run_id}/jobs?per_page=100"
            ).get("jobs", [])
            if (
                not run_is_target(fresh, run_id)
                or fresh.get("status") == "completed"
                or not candidate_waiting(fresh_jobs, now())
            ):
                return "skip: macOS started or run changed on recheck"
            client.api(f"actions/runs/{run_id}/cancel", method="POST")
            # Never re-run while the original workflow is still live.
            for _ in range(30):
                state = client.api(f"actions/runs/{run_id}")
                if not run_is_target(state, run_id):
                    return "skip: attempt changed during cancellation"
                if state.get("status") == "completed":
                    if state.get("conclusion") != "cancelled":
                        return "skip: cancellation did not produce cancelled"
                    if not same_open_pr(client, state):
                        return "skip: PR changed before retry"
                    client.api(f"actions/runs/{run_id}/rerun", method="POST")
                    return "rerun: cancelled queued attempt and requested all jobs"
                sleep(5)
            return "skip: cancellation did not finish"
        by_name = {job.get("name"): job for job in jobs}
        if (
            by_name.get(CANDIDATE, {}).get("status") in ("in_progress", "completed")
            or any(
                by_name.get(name, {}).get("status") == "completed"
                and by_name[name].get("conclusion") != "success"
                for name in OTHER_JOBS
            )
        ):
            return "skip: macOS started/finished or a gate failed"
        sleep(min(POLL_SECONDS, max(0, deadline - now())))
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
    outcome = monitor(GitHub(REPO, token), run_id)
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
