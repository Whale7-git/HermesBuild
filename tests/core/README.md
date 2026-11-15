# Historical manual SSH test instructions

> This document describes an optional older remote test wrapper. GPT Cloud Build runs the core suite directly under `bash tests/run_container.sh` on GitHub's Ubuntu runner; it does not use SSH, `ios-build`, or `HERMES_TEST_TARGET`.

# Pure Foundation chat core tests

Run from the project root:

```sh
HERMES_TEST_TARGET=user@build-host bash tests/core/run.sh final
```

This copies only ChatCore.swift, main.swift and the supplied synthetic live fixtures
to `/work/hermes-chatcore-tests` inside `ios-build` on the SSH target supplied by `HERMES_TEST_TARGET`, then runs:

```sh
swiftc -warnings-as-errors Sources/HermesShell/ChatCore.swift tests/core/main.swift -o core-tests
./core-tests all
```

No packages, application server, credentials or live API calls are used. The local
runner records compiler/runtime stdout in `tests/core/evidence-<label>.txt`.
Optional second argument selects a test name. A Swift compiler on another machine
can execute the two commands directly from this project's root.

## TDD evidence

Each numbered `evidence-01-red.txt` through `evidence-12-red.txt` was recorded
before implementing the corresponding behavior. Each `*-green.txt` is a full
regression run after that slice. Initial missing-type/member compilation failures
establish the requested interfaces; later RED runs demonstrate behavioral failures.
The sequence is SSE basic → SSE wire edge cases → snapshot text/pagination →
envelope errors → history tools → OpenAI message tools → stream text → replay
IDs → stream tools → authoritative done and live fixture → terminal events →
interaction notices. Final result: **126 assertions, 0 failures**.

The fixture files contain a synthetic protocol conversation with fixed sample
session IDs, model names and timestamps. Assertions check the `IOS_NATIVE_OK` marker and
counts; test output never prints message bodies or fixture fields.

## Internal interfaces

- `SSEFrame(event:data:id:)`: string event/data and optional string ID.
- `SSEParser()`, `mutating feed(line:) -> SSEFrame?`: feed each decoded line,
  including the empty delimiter. CRLF, comments, multiline data, ID-only frames,
  persistent SSE IDs, empty IDs and NUL-ID rejection are supported. Only delimiter
  dispatches a frame; EOF by itself does not dispatch or terminate anything.
- `ChatMessage(id:role:content:)` and
  `ChatTool(id:name:args:result:done:isError:)`: mutable, Identifiable values.
- `ChatSnapshot(data:) throws`: accepts `{session: {...}}` or direct session.
  Exposes `sessionID`, `messages`, `tools`, `activeStreamID`, `olderOffset`,
  `readOnly`, plus `messagesTruncated`. Uses explicit `read_only`; does not infer
  writability from channel/source. Requires session ID and a messages array and
  throws for malformed/error envelopes rather than returning an empty success.
  Message fallback identity includes session and original offset+row index.
  Text parts render; hidden/system/tool-call placeholders do not. Tool results
  become cards, joined to top-level or OpenAI assistant declarations by call ID.
- `ChatTranscript()`: set `messages`/`tools` to seed history. Exposes mutable
  `messages`, `tools`, `reasoning`, `terminal`, `failure`, `lastEventID`, plus
  `notice`; `mutating apply(_:) throws` consumes frames.
  A fresh value is one new stream; retain it on reconnect for ID deduplication.
  New tokens never append onto the previous historical assistant message.
  `done` atomically replaces messages and tools from the authoritative session.
  `cancel`, `stream_end`, `error`, `apperror` terminate; failed stream_end status
  is surfaced as failure. EOF is not a terminal event. `approval`/`clarify` report
  attention in `notice`, but do not claim completion or perform any approval.
  Unknown event types are ignored safely. After termination content is immutable;
  follow-up frames may advance the cursor but cannot erase an earlier failure.

Malformed recognized text/tool events throw and do not advance the ID cursor.
Non-JSON/empty fatal errors still produce terminal failure instead of disappearing.
No Markdown, UI, transport, configuration or services are included in this core.
