"""No-network safety contracts for deployed Gateway read-only evidence probe."""
import importlib.util
import io
import json
from pathlib import Path
import unittest
import urllib.error

SOURCE = Path(__file__).resolve().parents[2] / "scripts" / "diagnose_deployed_gateway.py"
SPEC = importlib.util.spec_from_file_location("diagnose_deployed_gateway", SOURCE)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class Response:
    def __init__(self, status, data):
        self.status = status
        self._body = io.BytesIO(json.dumps(data).encode())

    def read(self, size=-1):
        return self._body.read(size)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self._body.close()


class RecordingOpener:
    def __init__(self, responses):
        self.responses = responses
        self.requests = []

    def open(self, request, timeout=10):
        self.requests.append(request)
        path = request.full_url.removeprefix("https://hermes.test")
        outcome = self.responses.get(path, (404, {"error": "not found"}))
        if isinstance(outcome, Exception):
            raise outcome
        status, body = outcome
        if status >= 300:
            raise urllib.error.HTTPError(request.full_url, status, "fixture", None, None)
        return Response(status, body)


def fixture_caps(enabled=True):
    return {"features": {"run_unknown_resolution": enabled},
            "endpoints": {"run_unknown_resolution": "/v1/runs/{run_id}/resolve-unknown"}
            if enabled else {}}


class DeployedGatewayProbeTests(unittest.TestCase):
    def test_capabilities_only_sends_get_without_leaking_secret(self):
        client = RecordingOpener({"/v1/capabilities": (200, fixture_caps())})
        report = PROBE.probe("https://hermes.test", "private-secret", opener=client)
        self.assertEqual(report["capabilities"]["response_class"], "OK")
        self.assertEqual(report["run"]["outcome"], "NO_RUN_ID_REQUESTED")
        self.assertTrue(report["read_only"])
        self.assertEqual([req.get_method() for req in client.requests], ["GET"])
        self.assertNotIn("private-secret", json.dumps(report))
        self.assertNotIn("hermes.test", json.dumps(report))
        self.assertEqual(client.requests[0].get_header("Authorization"),
                         "Bearer private-secret")

    def test_unknown_requires_matching_capabilities_and_exact_identity(self):
        rid = "ui-run-secret-8"
        admission = "adm-secret-001"
        client = RecordingOpener({
            "/v1/capabilities": (200, fixture_caps()),
            "/v1/runs/" + rid: (200, {
                "run_id": rid, "status": "unknown",
                "admission_id": admission, "execution_generation": 7,
                "session_id": "sensitive-session",
                "messages": ["private-message"],
            }),
        })
        report = PROBE.probe("https://hermes.test", "key", rid, opener=client)
        self.assertEqual(report["run"]["verdict"],
                         "MANUAL_RESOLUTION_ELIGIBLE_READ_ONLY")
        self.assertTrue(report["run"]["identity_complete"])
        self.assertEqual(len(client.requests), 2)
        self.assertEqual([r.get_method() for r in client.requests],
                         ["GET", "GET"])
        out = json.dumps(report)
        for secret in (rid, admission, "private-message",
                       "sensitive-session", "hermes.test", "key"):
            # Short "key" is a field name in unrelated contexts; check
            # values with unambiguous identifying strings below.
            if secret == "key":
                continue
            self.assertNotIn(secret, out)
        self.assertFalse(report["safety"]["resolve_unknown_post_sent"])
        self.assertFalse(report["safety"]["file_delete_sent"])

    def test_unknown_without_server_feature_or_generation_fails_closed(self):
        for caps, gen in [(fixture_caps(False), 7),
                          (fixture_caps(), True), (fixture_caps(), "7"),
                          (fixture_caps(), None)]:
            with self.subTest(gen=gen, caps=caps):
                client = RecordingOpener({
                    "/v1/capabilities": (200, caps),
                    "/v1/runs/runX": (200, {
                        "status": "unknown", "admission_id": "admX",
                        "execution_generation": gen}),
                })
                report = PROBE.probe("https://hermes.test", "secret",
                                     "runX", opener=client)
                self.assertEqual(report["run"]["verdict"], "UNKNOWN_FAIL_CLOSED")

    def test_unverified_status_never_claims_unknown_ack(self):
        for status in (404, 409, 500, 503):
            with self.subTest(status=status):
                client = RecordingOpener({
                    "/v1/capabilities": (200, fixture_caps()),
                    "/v1/runs/runX": (status, {}),
                })
                report = PROBE.probe("https://hermes.test", "secret",
                                     "runX", opener=client)
                self.assertEqual(report["run"]["verdict"],
                                 "UNVERIFIED_NO_RESOLUTION")
                self.assertFalse(report["run"]["identity_complete"])
                self.assertEqual([r.get_method() for r in client.requests],
                                 ["GET", "GET"])

    def test_transport_failure_is_not_absence(self):
        client = RecordingOpener({
            "/v1/capabilities": (200, fixture_caps()),
            "/v1/runs/runX": urllib.error.URLError("private-network"),
        })
        report = PROBE.probe("https://hermes.test", "secret", "runX", opener=client)
        self.assertEqual(report["run"]["response_class"], "TRANSPORT_UNKNOWN")
        self.assertEqual(report["run"]["verdict"], "UNVERIFIED_NO_RESOLUTION")
        self.assertNotIn("private-network", json.dumps(report))

    def test_redirect_does_not_trigger_followup_or_replay(self):
        client = RecordingOpener({"/v1/capabilities": (302, {})})
        report = PROBE.probe("https://hermes.test", "secret", opener=client)
        self.assertEqual(report["capabilities"]["response_class"],
                         "HTTP_NON_SUCCESS")
        self.assertEqual(len(client.requests), 1)
        self.assertEqual(client.requests[0].get_method(), "GET")
        self.assertIsNone(PROBE.NoRedirect().redirect_request(
            client.requests[0], None, 302, "redirect", {}, "https://evil.test"))

    def test_rejects_insecure_remote_and_untrusted_identifiers(self):
        for url in ("http://hermes.test", "https://alice:secret@host.test",
                    "https://host.test/path?key=x", "https://host.test/../x"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                PROBE.probe(url, "key")
        for rid in ("../secret", "a/b", "%2f", "", "a" * 129):
            with self.subTest(rid=rid), self.assertRaises(ValueError):
                PROBE.probe("https://host.test", "key", rid)
        self.assertEqual(PROBE.validated_base("http://127.0.0.1:8642"),
                         "http://127.0.0.1:8642")

    def test_no_raw_credential_or_payload_output(self):
        client = RecordingOpener({
            "/v1/capabilities": (200, {
                "features": {"run_unknown_resolution": True,
                             "user_secret": "the-private-secret"},
                "endpoints": {"run_unknown_resolution": True},
                "api_key": "the-private-secret",
            }),
        })
        report = PROBE.probe("https://hermes.test", "the-private-secret",
                             opener=client)
        self.assertNotIn("the-private-secret", json.dumps(report))
        self.assertEqual(report["methods_sent"], ["GET"])


if __name__ == "__main__":
    unittest.main()
