# Hermes iOS UI test Gateway

Runs **only** on 127.0.0.1. The server never connects to real instances and uses only public synthetic data. Routes come directly from Sources/HermesShell/GatewayRequests.swift and GatewayBackend.swift. JSON shapes follow GatewayDecode.swift and GatewayEventMap.swift.

Run: python3 tests/uitest/mock_gateway.py --port 8765
Check: python3 -m unittest discover -s tests/uitest -p 'test_*.py' -v

- GET /api/sessions, GET /api/sessions/{id} (nested session metadata), GET /api/sessions/{id}/messages
- POST /api/sessions, POST /v1/runs, GET /v1/runs/{id}, GET /v1/runs/{id}/events
- POST /v1/runs/{id}/stop, POST /v1/files, GET /v1/files/by-path
- GET /api/model/options
- POST /__control/stub with {"method":"GET","path":"/api/sessions","status":429,"body":{"error":{"message":"Rate limited"}}} or {"disconnect":true}, optional "delay_ms"
- GET /__control/log, POST /__control/reset

All unknown routes return **501 MOCK_UNKNOWN_ROUTE** and are separately recorded. The request log exposes only presence/scheme of Authorization and cookie presence, never actual values, message bodies or user credentials. No uploaded files are written to disk. The synthetic PNG is embedded in the test server.

The initial fixture includes a 1000+ UTF-16-unit answer so XCUITest can check reader scrolling without relying on live LLM output. The synthetic stream follows the Gateway SSE JSON "event" convention and terminates with "run.completed". State resets between tests.

**Scope:** Gateway-mode flows only. The WebUI cookie/login flow is a separate contract, not emulated by pretending Gateway API-key authentication has cookies. Actual iOS UI behavior is not validated by these Python tests; Stage 3 must operate the Simulator.
