#!/usr/bin/env python3
"""Read-only deployed Hermes Gateway contract evidence for Issues #91/#93/#94.

Never sends POST/PATCH/DELETE, dumps payloads, or prints URL, key, run_id,
admission_id, session ID or message text. Only run against your own authorized
Gateway. TLS required except for loopback fixture tests.
"""
import argparse
import ipaddress
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

RUN_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
MAX_JSON_BYTES = 128 * 1024


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        # Never forward a Gateway Bearer across redirect boundaries.
        return None


def validated_base(raw):
    if not raw or raw != raw.strip():
        raise ValueError("missing_or_invalid_gateway_url")
    url = urllib.parse.urlsplit(raw)
    host = url.hostname
    if url.scheme not in ("https", "http") or not host or \
            url.username is not None or url.password is not None or \
            url.query or url.fragment:
        raise ValueError("invalid_gateway_url")
    if url.scheme == "http":
        try:
            local = ipaddress.ip_address(host).is_loopback
        except ValueError:
            local = host == "localhost"
        if not local:
            raise ValueError("tls_required_for_remote_gateway")
    segments = urllib.parse.unquote(url.path).split("/")
    if any(x in (".", "..") for x in segments) or "\\" in url.path:
        raise ValueError("invalid_gateway_prefix")
    return raw.rstrip("/")


def fetch_json(opener, base, key, path, timeout=10):
    request = urllib.request.Request(
        base + path,
        headers={"Authorization": "Bearer " + key, "Accept": "application/json"},
        method="GET")
    try:
        with opener.open(request, timeout=timeout) as response:
            code = response.status
            raw = response.read(MAX_JSON_BYTES + 1)
            if len(raw) > MAX_JSON_BYTES:
                return code, None, "oversize_response"
            obj = json.loads(raw)
            if not isinstance(obj, dict):
                return code, None, "non_object_json"
            return code, obj, None
    except urllib.error.HTTPError as exc:
        # Do not print error body, URL, headers or exception string.
        return exc.code, None, "http_error"
    except (urllib.error.URLError, TimeoutError, OSError, ssl.SSLError):
        return None, None, "transport_unknown"
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return None, None, "malformed_response"


def http_class(code, error):
    if error == "transport_unknown":
        return "TRANSPORT_UNKNOWN"
    if error in ("oversize_response", "non_object_json", "malformed_response"):
        return "INVALID_RESPONSE"
    if code in (401, 403):
        return "AUTH_BLOCKED"
    if code == 404:
        return "NOT_FOUND_NOT_ACKNOWLEDGED"
    if code == 409:
        return "CONFLICT_NOT_ACKNOWLEDGED"
    if code is None:
        return "NO_RESPONSE"
    if 500 <= code <= 599:
        return "SERVER_ERROR_NOT_TERMINAL"
    if code != 200:
        return "HTTP_NON_SUCCESS"
    return "OK"


def probe(base_url, api_key, run_id=None, opener=None):
    base = validated_base(base_url)
    if not api_key or "\r" in api_key or "\n" in api_key:
        raise ValueError("invalid_gateway_key")
    if run_id is not None and not RUN_ID_RE.fullmatch(run_id):
        raise ValueError("invalid_run_id")
    opener = opener or urllib.request.build_opener(NoRedirect())
    cap_code, caps, cap_err = fetch_json(
        opener, base, api_key, "/v1/capabilities")
    features = caps.get("features", {}) if isinstance(caps, dict) else {}
    endpoints = caps.get("endpoints", {}) if isinstance(caps, dict) else {}
    advertised_flag = features.get("run_unknown_resolution") is True \
        if isinstance(features, dict) else False
    endpoint = endpoints.get("run_unknown_resolution") \
        if isinstance(endpoints, dict) else None
    endpoint_advertised = endpoint is not None and endpoint is not False

    result = {
        "schema": 1,
        "read_only": True,
        "methods_sent": ["GET"],
        "capabilities": {
            "response_class": http_class(cap_code, cap_err),
            "http_status": cap_code,
            "run_unknown_resolution_feature": advertised_flag,
            "run_unknown_resolution_endpoint": endpoint_advertised,
        },
        "run": {"checked": run_id is not None},
        "safety": {
            "resolve_unknown_post_sent": False,
            "file_delete_sent": False,
            "chat_post_sent": False,
        },
    }
    if run_id is None:
        result["run"]["outcome"] = "NO_RUN_ID_REQUESTED"
        return result

    status_code, status, error = fetch_json(
        opener, base, api_key, "/v1/runs/" + run_id)
    outcome = http_class(status_code, error)
    run_state = status.get("status") if isinstance(status, dict) else None
    if not isinstance(run_state, str):
        run_state = None
    admission_id = status.get("admission_id") if isinstance(status, dict) else None
    generation = status.get("execution_generation") if isinstance(status, dict) else None
    identity_complete = isinstance(admission_id, str) and bool(admission_id) \
        and type(generation) is int and generation >= 0
    # 404, 409, 5xx and transport loss are NEVER an unknown acknowledgement.
    # Even fully eligible status=unknown is observation only: never POST here.
    if outcome == "OK" and run_state == "unknown":
        verdict = ("MANUAL_RESOLUTION_ELIGIBLE_READ_ONLY"
                   if advertised_flag and endpoint_advertised and identity_complete
                   else "UNKNOWN_FAIL_CLOSED")
    elif outcome == "OK" and run_state in (
            "running", "queued", "completed", "failed", "cancelled", "interrupted"):
        verdict = "OBSERVED_NO_RESOLUTION"
    else:
        verdict = "UNVERIFIED_NO_RESOLUTION"
    result["run"].update({
        "response_class": outcome,
        "http_status": status_code,
        "status": run_state if run_state in (
            "unknown", "running", "queued", "completed", "failed",
            "cancelled", "interrupted") else "unrecognized",
        "admission_present": isinstance(admission_id, str) and bool(admission_id),
        "generation_integer": type(generation) is int,
        "identity_complete": identity_complete,
        "verdict": verdict,
    })
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=int, default=10)
    args = parser.parse_args()
    if args.timeout < 1 or args.timeout > 30:
        parser.error("timeout must be between 1 and 30 seconds")
    try:
        raw = probe(
            os.environ.get("HERMES_GATEWAY_URL", ""),
            os.environ.get("HERMES_GATEWAY_API_KEY", ""),
            os.environ.get("HERMES_RUN_ID") or None)
        print(json.dumps(raw, sort_keys=True, ensure_ascii=False))
        cap_ok = raw["capabilities"]["response_class"] == "OK"
        run_ok = not raw["run"]["checked"] or raw["run"]["response_class"] == "OK"
        return 0 if cap_ok and run_ok else 1
    except ValueError as error:
        # Print fixed validation category only, never user-provided values.
        print(json.dumps({"schema": 1, "read_only": True,
                          "error": str(error), "methods_sent": []}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
