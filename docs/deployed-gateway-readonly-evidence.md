# Deployed Gateway read-only evidence (Issues #91 / #93 / #94)

This is **optional deployment-level diagnosis**, not a replacement for the
released iOS app's XCTest suite. The client already has bounded unresolved
Run handling, no-replay protection, and a bounded attachment upload queue.
The remaining evidence requires the **actual deployed Gateway**, not an
assumed upstream feature.

## Run privately on a machine authorized to reach your own Gateway

Do not paste any API key, session ID, full response body, private URL, or
terminal transcript into a GitHub Issue or ChatGPT.

```bash
export HERMES_GATEWAY_URL='https://your-gateway.example'
read -rs -p 'Gateway API key: ' HERMES_GATEWAY_API_KEY
echo
export HERMES_GATEWAY_API_KEY
python3 scripts/diagnose_deployed_gateway.py
# Optional: supply an already-existing authorized Run ID (never create a Run here)
read -r -p 'Existing Run ID (optional): ' HERMES_RUN_ID
export HERMES_RUN_ID
python3 scripts/diagnose_deployed_gateway.py
unset HERMES_GATEWAY_API_KEY HERMES_RUN_ID HERMES_GATEWAY_URL
```

The probe sends only authenticated GET requests:
`/v1/capabilities` and, when a Run ID is supplied,
`/v1/runs/{id}`. HTTPS is mandatory except for loopback, redirects are
rejected, and TLS verification is never disabled. The fixed-schema JSON
output contains only booleans, whitelisted status labels, numeric HTTP
codes and safety classifications. It never includes credentials,
hostnames, run/admission/session identifiers, or message contents.
The probe must not be added to routine CI because GitHub-hosted runners
should not need user Gateway credentials.

For #91, `MANUAL_RESOLUTION_ELIGIBLE_READ_ONLY` means an authenticated GET
actually reported `status=unknown`, included a nonempty `admission_id`
and integer `execution_generation`, and the same deployment advertised
`features.run_unknown_resolution` plus
`endpoints.run_unknown_resolution`. **No resolution POST is sent.**
An eligible response is only a prerequisite for a separately authorized
mutation test. HTTP 404, 409, 5xx, timeout or connection loss is **not**
proof that an unknown Run has been resolved. Do not retry the original
user POST to work around uncertainty.

For #93, no read-only request can prove the backend actually deletes an
uploaded file, honors ownership, collects orphans or supports offset/hash
resumability. These fields are explicitly `NOT_PROVEN_READ_ONLY`. Actual
remote lifecycle tests need a disposable file, confirmed owner-scoped
server contract, permission and controlled cleanup. Never improvise a
`DELETE /v1/files/{id}` endpoint on a production Gateway.

For #94, the independent Mock Gateway tests exercise scripted Run-status
503/404/disconnect, exact SSE `Last-Event-ID` replay and one accepted
POST. These are **fixture and client-safety regressions**, not evidence of
authentic Gateway restart, pending approval, real-device backgrounding
or network-interruption recovery.

## Interpreting failed observations

- `AUTH_BLOCKED`: verify permissions out of band; do not log the key.
- `NOT_FOUND_NOT_ACKNOWLEDGED`: 404 is not terminal-unknown resolution.
- `SERVER_ERROR_NOT_TERMINAL` or `TRANSPORT_UNKNOWN`: preserve the
  user's durable Run state; do not auto-resend.
- `UNKNOWN_FAIL_CLOSED`: deployment does not have a complete confirmed
  resolution contract. No POST should be attempted.
- `MANUAL_RESOLUTION_ELIGIBLE_READ_ONLY`: a human/controlled E2E test
  must still verify ownership, exact-generation 200/409/404 semantics.

Record the sanitized JSON outcome, upstream Gateway build/version from a
separately trusted source, date, and whether tests were on a disposable
Run. Do not close #91, #93 or #94 solely from the read-only probe.
