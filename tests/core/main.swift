import Foundation

var assertions = 0
var failures = 0
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    assertions += 1
    if !condition() { failures += 1; print("FAIL: \(label)") }
}
func test(_ name: String, _ body: () throws -> Void) {
    let requested = CommandLine.arguments.dropFirst().first ?? "all"
    guard requested == "all" || requested == name else { return }
    let before = failures
    do { try body() } catch { failures += 1; print("FAIL: \(name): \(error)") }
    print("\(before == failures ? "PASS" : "FAIL"): \(name)")
}

test("sse_basic") {
    var parser = SSEParser()
    expect(parser.feed(line: "event: token") == nil, "event waits for delimiter")
    expect(parser.feed(line: "data: hello") == nil, "data waits for delimiter")
    let frame = parser.feed(line: "")
    expect(frame?.event == "token", "event name")
    expect(frame?.data == "hello", "event payload")
    expect(frame?.id == nil, "optional ID")
    _ = parser.feed(line: "data: next")
    expect(parser.feed(line: "")?.event == "message", "default event resets")
}

test("sse_wire") {
    var parser = SSEParser()
    expect(parser.feed(line: ": keepalive\r") == nil, "comments ignored")
    _ = parser.feed(line: "event: tool\r")
    _ = parser.feed(line: "id: 12\r")
    _ = parser.feed(line: "data: first\r")
    _ = parser.feed(line: "data:  second\r")
    _ = parser.feed(line: "retry: 3000\r")
    let frame = parser.feed(line: "\r")
    expect(frame?.event == "tool", "CRLF delimiter")
    expect(frame?.data == "first\n second", "multiline and single space stripping")
    expect(frame?.id == "12", "event ID")
    _ = parser.feed(line: "id: bad\u{0}id")
    _ = parser.feed(line: "data")
    let emptyData = parser.feed(line: "")
    expect(emptyData?.data == "", "empty data field is still data")
    expect(emptyData?.id == "12", "SSE last event ID persists; NUL ID ignored")
    _ = parser.feed(line: "id:")
    _ = parser.feed(line: "data: reset")
    expect(parser.feed(line: "")?.id == "", "empty ID clears resume cursor")
    _ = parser.feed(line: "event: ignored")
    _ = parser.feed(line: "id: 13")
    expect(parser.feed(line: "") == nil, "no-data frames ignored")
    _ = parser.feed(line: "data: ok")
    let reset = parser.feed(line: "")
    expect(reset?.event == "message", "no-data frame resets event")
    expect(reset?.id == "13", "ID-only frame updates cursor")
}

func snapshot(_ json: String) throws -> ChatSnapshot {
    try ChatSnapshot(data: Data(json.utf8))
}

test("snapshot_text") {
    let s = try snapshot(#"{"session":{"session_id":"s1","messages":[{"role":"system","content":"hidden"},{"role":"user","message_id":"u1","id":"ignored","content":"hello"},{"role":"assistant","id":"a1","content":[{"type":"text","text":"A"},{"type":"image_url","image_url":{"url":"unused"}},{"type":"text","text":"B"}]},{"role":"assistant","content":null,"tool_calls":[]}],"tool_calls":[],"active_stream_id":"stream1","_messages_offset":40,"_messages_truncated":true,"read_only":true}}"#)
    expect(s.sessionID == "s1", "unwrap session")
    expect(s.messages.count == 2, "system and empty assistant omitted")
    expect(s.messages.first?.id == "u1", "message_id before id")
    expect(s.messages.last?.id == "a1", "id preserved")
    expect(s.messages.last?.content == "AB", "only text parts concatenated")
    expect(s.activeStreamID == "stream1", "active stream")
    expect(s.olderOffset == 40, "page offset")
    expect(s.messagesTruncated, "truncation flag")
    expect(s.readOnly, "explicit read only")
    let direct = try snapshot(#"{"session_id":"s2","messages":[],"is_cli_session":true,"source":"telegram"}"#)
    expect(direct.messages.isEmpty, "empty session valid")
    expect(!direct.readOnly, "do not infer read only from source or CLI")
    expect(direct.activeStreamID == nil, "missing active stream")
    let blank = try snapshot(#"{"session_id":"s","messages":[],"active_stream_id":"  "}"#)
    expect(blank.activeStreamID == nil, "blank active stream cannot lock sending or open an invalid stream route")
    let overflowing = try JSONSerialization.data(withJSONObject: ["session_id": "s", "_messages_offset": Int.max,
        "messages": [["role": "user", "content": "one"]]])
    do {
        _ = try ChatSnapshot(data: overflowing)
        expect(false, "overflowing history coordinates must throw instead of trapping")
    } catch { expect(true, "overflowing history coordinates reject safely") }
    expect(direct.olderOffset == 0 && !direct.messagesTruncated, "unpaged defaults")
    let p1 = try snapshot(#"{"session_id":"s","_messages_offset":41,"messages":[{"role":"user","content":"same"}]}"#)
    let p2 = try snapshot(#"{"session_id":"s","_messages_offset":40,"messages":[{"role":"assistant","content":"previous"},{"role":"user","content":"same"}]}"#)
    expect(p1.messages[0].id == p2.messages[1].id, "fallback IDs stable across overlapping pages")
    let other = try snapshot(#"{"session_id":"other","_messages_offset":41,"messages":[{"role":"user","content":"same"}]}"#)
    expect(other.messages[0].id != p1.messages[0].id, "fallback IDs scoped to session")
}

test("internal_notification_origin") {
    let s = try snapshot(#"{"session_id":"s","messages":[{"id":"i1","role":"user","content":"[OUT-OF-BAND USER MESSAGE]","display_kind":"internal_notification"},{"id":"u1","role":"user","content":"[OUT-OF-BAND USER MESSAGE]"}]}"#)
    expect(s.messages.count == 2, "internal notification stays in transcript")
    expect(s.messages[0].displayKind == "internal_notification", "server display_kind survives normalization")
    expect(s.messages[1].displayKind == nil, "user-authored OOB-like text is not hidden")
    expect(ChatBackgroundEnvelope.userBody(s.messages[0]) == nil,
           "mislabelled plain user text remains a user bubble")
    let actual = ChatMessage(id: "oob", role: "user",
                             content: "[OUT-OF-BAND USER MESSAGE — notification]\nBackground work[/OUT-OF-BAND USER MESSAGE]",
                             displayKind: "internal_notification")
    expect(ChatBackgroundEnvelope.userBody(actual) == "Background work",
           "a labelled, balanced background envelope is recognized")
    let userTyped = ChatMessage(id: "typed", role: "user", content: actual.content)
    expect(ChatBackgroundEnvelope.userBody(userTyped) == nil,
           "a pasted wrapper is still a normal user bubble")
}

test("snapshot_errors") {
    let invalid = [
        "not JSON", "[]", "{}", #"{"session":null}"#,
        #"{"session":{"session_id":"s"}}"#,
        #"{"session_id":"s","messages":{}}"#,
        #"{"session_id":"","messages":[]}"#,
        #"{"session_id":"s","messages":[],"tool_calls":"invalid"}"#,
        #"{"error":"Unauthorized","session":{"session_id":"s","messages":[]}}"#
    ]
    for (index, json) in invalid.enumerated() {
        var threw = false
        do { _ = try snapshot(json) } catch { threw = true }
        expect(threw, "malformed envelope \(index) throws")
    }
    do {
        _ = try snapshot(#"{"error":"Unauthorized","status":401}"#)
        expect(false, "401 error throws")
    } catch {
        expect(error.localizedDescription.contains("Unauthorized"), "401 reason preserved")
    }
}

test("snapshot_tools") {
    let s = try snapshot(#"{"session_id":"s","messages":[],"tool_calls":[{"tid":"t1","name":"lookup","args":{"q":"test"},"result":"found","done":true,"is_error":false},{"tid":"t2","name":"run","args":"{\"cmd\":\"false\"}","snippet":"failed","done":true,"is_error":true},{"id":"t3","name":"wait","args":null,"preview":"starting","done":false}]}"#)
    expect(s.tools.count == 3, "top level tool count")
    guard s.tools.count == 3 else { return }
    expect(s.tools[0].id == "t1" && s.tools[0].name == "lookup", "canonical tid and name")
    expect(s.tools[0].args == #"{"q":"test"}"#, "object args serialized")
    expect(s.tools[0].result == "found" && s.tools[0].done, "canonical result and done")
    expect(s.tools[1].args == #"{"cmd":"false"}"#, "string args preserved")
    expect(s.tools[1].result == "failed" && s.tools[1].isError, "snippet and error")
    expect(s.tools[2].id == "t3" && s.tools[2].args.isEmpty, "id alias and null args")
    expect(!s.tools[2].done && s.tools[2].result == "starting", "running preview")
}

test("snapshot_message_tools") {
    let s = try snapshot(#"{"session":{"session_id":"s","tool_calls":[],"messages":[{"role":"user","content":"run checks"},{"role":"assistant","content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"x\"}"}},{"id":"call2","function":{"name":"run","arguments":{"cmd":"check"}}}]},{"role":"tool","tool_call_id":"call1","content":[{"type":"text","text":"found"}]},{"role":"tool","tool_call_id":"call2","result":{"ok":false},"is_error":true},{"role":"assistant","content":"finished"}]}}"#)
    expect(s.messages.map { $0.role } == ["user", "assistant"], "tool rows not bubbles; null tool-call assistant filtered")
    expect(s.tools.count == 2, "recover cards when top-level empty")
    guard s.tools.count == 2 else { return }
    expect(s.tools[0].id == "call1" && s.tools[0].name == "lookup", "OpenAI function identity")
    expect(s.tools[0].args == #"{"q":"x"}"#, "OpenAI argument string")
    expect(s.tools[0].done && s.tools[0].result == "found", "tool role completes card")
    expect(s.tools[1].args == #"{"cmd":"check"}"#, "OpenAI object arguments")
    expect(s.tools[1].done && s.tools[1].isError && s.tools[1].result == #"{"ok":false}"#, "result field and error flag")
    let merged = try snapshot(#"{"session_id":"s","tool_calls":[{"tid":"c","name":"lookup","args":{"q":"x"},"preview":"working","done":false}],"messages":[{"role":"assistant","content":"checking","tool_calls":[{"id":"c","function":{"name":"lookup","arguments":"{\"q\":\"x\"}"}}]},{"role":"tool","tool_call_id":"c","content":"full result"},{"role":"tool","tool_call_id":"orphan","name":"other","content":"orphan result"}]}"#)
    expect(merged.messages.first?.content == "checking", "assistant text with tools retained")
    expect(merged.tools.count == 2, "same tool ID merged; orphan shown")
    expect(merged.tools.first?.result == "full result" && merged.tools.first?.done == true, "full tool result wins preview")
    expect(merged.tools.last?.name == "other" && merged.tools.last?.done == true, "orphan result card")
}

test("snapshot_attachments") {
    // A11: 纯 image_url 内容块 + attachments 的用户消息不再被过滤；
    // data:/file: 等不支持或危险 scheme 被剔除。
    let imageOnly = try snapshot(#"{"session_id":"s","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}],"attachments":["photo.jpg"]}]}"#)
    expect(imageOnly.messages.count == 1, "image-only user message is no longer filtered")
    expect(imageOnly.messages.first?.content == "", "image-only message keeps empty text")
    expect(imageOnly.messages.first?.attachmentPaths == ["photo.jpg"], "attachment path preserved; data URL excluded")
    // 空文字 + 混合 attachments：整行保留，危险 scheme 被过滤。
    let mixed = try snapshot(#"{"session_id":"s","messages":[{"role":"user","content":"","attachments":["photo.jpg","file:///etc/passwd","https://host/ok.png"]}]}"#)
    expect(mixed.messages.count == 1, "empty text with attachments is no longer filtered")
    expect(mixed.messages.first?.attachmentPaths == ["photo.jpg", "https://host/ok.png"], "dangerous attachment schemes are filtered")
    // 纯空消息与 system/tool 行仍然被过滤。
    let filtered = try snapshot(#"{"session_id":"s","messages":[{"role":"user","content":""},{"role":"user","content":"   "},{"role":"system","content":"hidden"},{"role":"tool","content":"result"}],"tool_calls":[]}"#)
    expect(filtered.messages.isEmpty, "blank rows and system/tool lines stay filtered")
    // 纯文字与文字+图片混排行为不变。
    let plain = try snapshot(#"{"session_id":"s","messages":[{"role":"user","content":"纯文字"},{"role":"user","content":[{"type":"text","text":"看这张图"},{"type":"image_url","image_url":{"url":"data:image/png;base64,BBBB"}}],"attachments":["shot.png"]}]}"#)
    expect(plain.messages.count == 2, "text messages unchanged")
    expect(plain.messages[0].content == "纯文字" && plain.messages[0].attachmentPaths.isEmpty, "plain text keeps no attachment paths")
    expect(plain.messages[1].content == "看这张图" && plain.messages[1].attachmentPaths == ["shot.png"], "text+image mixing keeps text and attachments")
}

func frame(_ event: String, _ data: String, _ id: String? = nil) -> SSEFrame {
    SSEFrame(event: event, data: data, id: id)
}

test("transcript_text") {
    var t = ChatTranscript()
    t.messages = [ChatMessage(id: "past", role: "assistant", content: "old reply")]
    expect(!t.terminal && t.failure == nil && t.lastEventID == nil, "new stream is nonterminal")
    try t.apply(frame("token", #"{"text":"Hello"}"#, "1"))
    try t.apply(frame("reasoning", #"{"text":"think "}"#, "2"))
    try t.apply(frame("token", #"{"text":" world"}"#, "3"))
    try t.apply(frame("reasoning", #"{"text":"more"}"#, "4"))
    expect(t.messages.count == 2, "new assistant bubble instead of appending history")
    expect(t.messages.first?.content == "old reply", "historical assistant unchanged")
    expect(t.messages.last?.role == "assistant" && t.messages.last?.content == "Hello world", "token accumulation")
    expect(t.reasoning == "think more", "separate reasoning accumulation")
    expect(t.lastEventID == "4", "resume cursor")
    var empty = ChatTranscript()
    try empty.apply(frame("token", #"{"text":""}"#))
    expect(empty.messages.isEmpty, "empty token not a bubble")
    try empty.apply(frame("context_status", #"{"status":"ready"}"#, "5"))
    try empty.apply(frame("future_event", "not JSON", "6"))
    expect(empty.messages.isEmpty && !empty.terminal && empty.failure == nil, "unknown events safely ignored")
    expect(empty.lastEventID == "6", "unknown event advances cursor")
    // Transport EOF does not call apply: it cannot imply server completion.
    expect(!t.terminal, "EOF without terminal event remains nonterminal")
}

test("transcript_replay") {
    var t = ChatTranscript()
    try t.apply(frame("token", #"{"text":"A"}"#, "opaque-a"))
    try t.apply(frame("token", #"{"text":"B"}"#, "opaque-b"))
    try t.apply(frame("token", #"{"text":"A"}"#, "opaque-a"))
    try t.apply(frame("token", #"{"text":"B"}"#, "opaque-b"))
    expect(t.messages.last?.content == "AB", "nonconsecutive reconnect replay deduplicated")
    expect(t.lastEventID == "opaque-b", "replay cannot regress cursor")
    try t.apply(frame("reasoning", #"{"text":"R"}"#, "opaque-r"))
    try t.apply(frame("reasoning", #"{"text":"R"}"#, "opaque-r"))
    expect(t.reasoning == "R", "reasoning replay deduplicated")
    try t.apply(frame("token", #"{"text":"!"}"#))
    try t.apply(frame("token", #"{"text":"!"}"#))
    expect(t.messages.last?.content == "AB!!", "ID-less tokens are not falsely deduplicated")
    try t.apply(frame("token", #"{"text":"x"}"#, ""))
    try t.apply(frame("token", #"{"text":"x"}"#, ""))
    expect(t.messages.last?.content == "AB!!xx" && t.lastEventID == "", "empty ID resets cursor, not event identity")
    var threw = false
    do { try t.apply(frame("token", "{}", "retry")) } catch { threw = true }
    expect(threw, "malformed token throws")
    expect(t.lastEventID == "", "bad event cannot advance cursor")
    try t.apply(frame("token", #"{"text":"fixed"}"#, "retry"))
    expect(t.messages.last?.content.hasSuffix("fixed") == true, "failed event not marked seen")
}

test("transcript_tools") {
    var t = ChatTranscript()
    try t.apply(frame("tool", #"{"tid":"a","name":"run","args":{"cmd":"one"},"preview":"running"}"#, "1"))
    try t.apply(frame("tool", #"{"tid":"b","name":"run","args":"two"}"#, "2"))
    expect(t.tools.count == 2, "concurrent same-name tools stay distinct")
    try t.apply(frame("tool_complete", #"{"tid":"b","name":"run","args":{},"preview":"failed","is_error":true}"#, "3"))
    try t.apply(frame("tool_complete", #"{"tid":"b","name":"run","preview":"failed","is_error":true}"#, "3"))
    guard t.tools.count == 2 else { expect(false, "tool count before merge checks"); return }
    expect(!t.tools[0].done && t.tools[1].done, "complete matches tid, not name")
    expect(t.tools[0].args == #"{"cmd":"one"}"# && t.tools[1].args == "two", "empty completion args preserve initial args")
    expect(t.tools[1].result == "failed" && t.tools[1].isError, "completion preview and error")
    try t.apply(frame("tool_complete", #"{"tid":"orphan","name":"run","preview":"orphan result"}"#, "4"))
    expect(t.tools.count == 3 && !t.tools[0].done, "different explicit tid never steals pending tool")
    try t.apply(frame("tool_complete", #"{"name":"run","preview":"finished"}"#, "5"))
    expect(t.tools[0].done && t.tools[0].result == "finished", "id-less completion matches pending name")
    try t.apply(frame("tool", #"{"name":"lookup","args":{"q":"x"}}"#, "6"))
    let noID = t.tools.last?.id
    try t.apply(frame("tool_complete", #"{"name":"lookup","preview":"found"}"#, "7"))
    expect(t.tools.count == 4 && t.tools.last?.id == noID && t.tools.last?.done == true, "generated identity retained on id-less completion")
    expect(!t.terminal, "tool completion is not stream completion")
}

test("transcript_tool_ambiguity") {
    var t = ChatTranscript()
    try t.apply(frame("tool", #"{"tid":"first","name":"run","preview":"one"}"#, "1"))
    try t.apply(frame("tool", #"{"tid":"second","name":"run","preview":"two"}"#, "2"))
    try t.apply(frame("tool_complete", #"{"name":"run","preview":"ambiguous"}"#, "3"))
    expect(t.tools.count == 3, "id-less same-name completion creates an unresolved row")
    expect(t.tools[0].id == "first" && !t.tools[0].done, "first same-name call is not guessed")
    expect(t.tools[1].id == "second" && !t.tools[1].done, "second same-name call is not guessed")
    expect(t.tools[2].done && t.tools[2].result == "ambiguous", "ambiguous result remains visible")
}

test("transcript_streaming_revision") {
    var t = ChatTranscript()
    t.messages = [ChatMessage(id: "u", role: "user", content: "question")]
    try t.apply(frame("token", #"{"text":"a"}"#, "first"))
    let before = ChatStreamingTailSnapshot(
        messages: t.messages, tools: t.tools, notices: t.notices,
        running: true, toolsAreLive: true,
        transcriptRevision: t.transcriptRevision,
        transcriptStructureRevision: t.transcriptStructureRevision)
    try t.apply(frame("token", #"{"text":"b"}"#, "second"))
    let after = ChatStreamingTailSnapshot(
        messages: t.messages, tools: t.tools, notices: t.notices,
        running: true, toolsAreLive: true,
        transcriptRevision: t.transcriptRevision,
        transcriptStructureRevision: t.transcriptStructureRevision)
    expect(after.transcriptRevision > before.transcriptRevision,
           "token frame advances the transcript revision")
    expect(after.transcriptStructureRevision == before.transcriptStructureRevision,
           "token-only tail update does not advance structure revision")
    expect(after.messages.last?.content == "ab", "token frame updates the assistant tail")
    expect(ChatStreamingTailProof.canReplaceTail(from: before, to: after),
           "tail-only revision accepts the streaming fast path")

    var structureChanged = t
    structureChanged.messages[0].content = "edited history"
    try structureChanged.apply(frame("token", #"{"text":"c"}"#, "2"))
    let changed = ChatStreamingTailSnapshot(
        messages: structureChanged.messages, tools: structureChanged.tools,
        notices: structureChanged.notices, running: true, toolsAreLive: true,
        transcriptRevision: structureChanged.transcriptRevision,
        transcriptStructureRevision: structureChanged.transcriptStructureRevision)
    expect(!ChatStreamingTailProof.canReplaceTail(from: after, to: changed),
           "earlier-row mutation cannot use the tail fast path")

    let unchanged = ChatStreamingTailSnapshot(
        messages: t.messages, tools: t.tools, notices: t.notices,
        running: true, toolsAreLive: true,
        transcriptRevision: t.transcriptRevision,
        transcriptStructureRevision: t.transcriptStructureRevision)
    expect(!ChatStreamingTailProof.canReplaceTail(from: unchanged, to: unchanged),
           "an unchanged revision cannot claim a tail update")
}

test("transcript_done") {
    var t = ChatTranscript()
    t.messages = [ChatMessage(id: "optimistic", role: "user", content: "pending")]
    try t.apply(frame("token", #"{"text":"draft"}"#, "1"))
    try t.apply(frame("tool", #"{"tid":"temporary","name":"run"}"#, "2"))
    try t.apply(frame("done", #"{"session":{"session_id":"s","messages":[{"id":"u","role":"user","content":"saved"},{"id":"a","role":"assistant","content":"authoritative"}],"tool_calls":[{"tid":"final","name":"lookup","result":"saved tool","done":true}]},"usage":{}}"#, "3"))
    expect(t.terminal && t.failure == nil, "done terminal success")
    expect(t.messages.map { $0.id } == ["u", "a"], "done replaces optimistic and streaming bubbles")
    expect(t.messages.last?.content == "authoritative", "done authority beats token draft")
    expect(t.tools.count == 1 && t.tools.first?.id == "final", "done replaces transient tools")
    try t.apply(frame("token", #"{"text":"late"}"#, "4"))
    expect(t.messages.last?.content == "authoritative", "late token cannot mutate settled transcript")
    try t.apply(frame("stream_end", #"{"session_id":"s"}"#, "5"))
    expect(t.terminal && t.failure == nil && t.lastEventID == "5", "done then stream_end harmless")
    var invalid = ChatTranscript()
    try invalid.apply(frame("token", #"{"text":"keep"}"#, "a"))
    var threw = false
    do { try invalid.apply(frame("done", #"{"session":{"bad":true}}"#, "b")) } catch { threw = true }
    expect(threw, "malformed done is not success")
    expect(!invalid.terminal && invalid.messages.last?.content == "keep" && invalid.lastEventID == "a", "malformed done atomic")
}

test("live_fixture") {
    let dir = URL(fileURLWithPath: "tests/core/fixtures")
    let history = try ChatSnapshot(data: Data(contentsOf: dir.appendingPathComponent("ios-native-live-history.json")))
    expect(history.messages.count == 2, "real fixture history count")
    expect(history.messages.last?.content.contains("IOS_NATIVE_OK") == true, "ASSERT IOS_NATIVE_OK history")
    let eventData = try Data(contentsOf: dir.appendingPathComponent("ios-native-live-events.json"))
    guard let events = try JSONSerialization.jsonObject(with: eventData) as? [[String: Any]] else {
        throw ChatCoreError.malformed("fixture event array")
    }
    expect(events.count == 6, "real fixture event count")
    var transcript = ChatTranscript()
    for event in events {
        guard let name = event["event"] as? String, let data = event["data"] as? String else {
            throw ChatCoreError.malformed("fixture event fields")
        }
        try transcript.apply(frame(name, data, event["id"] as? String))
    }
    expect(transcript.terminal && transcript.failure == nil, "real fixture done")
    expect(transcript.messages.count == 2, "real done authority count")
    expect(transcript.messages.last?.content.contains("IOS_NATIVE_OK") == true, "ASSERT IOS_NATIVE_OK stream")
    expect(transcript.messages.map { $0.content } == history.messages.map { $0.content }, "real done matches GET history")
}

test("transcript_terminal") {
    for event in ["cancel", "stream_end"] {
        var t = ChatTranscript()
        try t.apply(frame("token", #"{"text":"partial"}"#, "1"))
        try t.apply(frame(event, #"{"session_id":"s"}"#, "2"))
        expect(t.terminal && t.failure == nil, "\(event) is terminal without failure")
        expect(t.messages.last?.content == "partial", "\(event) preserves partial reply")
        try t.apply(frame("token", #"{"text":"late"}"#, "3"))
        expect(t.messages.last?.content == "partial", "\(event) suppresses late token")
    }
    for event in ["error", "apperror"] {
        var t = ChatTranscript()
        try t.apply(frame("token", #"{"text":"partial"}"#))
        try t.apply(frame(event, #"{"label":"Gateway request failed","message":"Unauthorized","hint":"Check authorization"}"#, "err"))
        expect(t.terminal, "\(event) is terminal")
        expect(t.failure?.contains("Unauthorized") == true && t.failure?.contains("Check authorization") == true, "\(event) preserves explanation")
        expect(t.messages.last?.content == "partial" && t.lastEventID == "err", "\(event) preserves content and cursor")
        try t.apply(frame("stream_end", "{}", "end"))
        expect(t.failure?.contains("Unauthorized") == true, "stream_end cannot clear error")
    }
    var plain = ChatTranscript()
    try plain.apply(frame("error", "Disconnected"))
    expect(plain.terminal && plain.failure?.contains("Disconnected") == true, "non-JSON error still surfaced")
    var nested = ChatTranscript()
    try nested.apply(frame("error", #"{"error":{"message":"Denied"}}"#))
    expect(nested.terminal && nested.failure?.contains("Denied") == true, "nested error message")
    var empty = ChatTranscript()
    try empty.apply(frame("apperror", ""))
    expect(empty.terminal && !(empty.failure ?? "").isEmpty, "empty error never silently succeeds")
    var failedEnd = ChatTranscript()
    try failedEnd.apply(frame("stream_end", #"{"status":"failed"}"#))
    expect(failedEnd.terminal && failedEnd.failure?.contains("failed") == true, "failed stream_end is not success")
}

test("transcript_notices") {
    var t = ChatTranscript()
    try t.apply(frame("approval", #"{"description":"Allow test command","request_id":"synthetic"}"#, "a"))
    expect(t.notice?.contains("需要审批") == true, "approval requires explicit attention")
    expect(t.notice?.contains("Allow test command") == true, "approval description retained")
    expect(!t.terminal && t.failure == nil, "approval pauses, not completion or error")
    try t.apply(frame("approval_resolved", #"{"request_id":"other"}"#, "other-answer"))
    expect(t.notice?.contains("需要审批") == true, "unrelated approval acknowledgement preserves the current notice")
    try t.apply(frame("approval_resolved", #"{"request_id":"synthetic"}"#, "answer"))
    expect(t.notice == nil && !t.terminal, "matching acknowledgement clears exactly its approval notice")
    try t.apply(frame("clarify", #"{"question":"Which test option?","choices":["A","B"]}"#, "b"))
    expect(t.notice?.contains("需要澄清") == true && t.notice?.contains("Which test option?") == true, "clarify requires explicit attention")
    expect(!t.terminal && t.messages.isEmpty, "clarify not ordinary chat bubble")
    var fallback = ChatTranscript()
    try fallback.apply(frame("approval", "{}"))
    expect(!(fallback.notice ?? "").isEmpty, "missing interaction details still notified")
    try t.apply(frame("cancel", "{}", "c"))
    expect(t.terminal && t.notice?.contains("已取消") == true, "cancel replaces stale approval state")
}

test("stop_notice") {
    // F-32：`stop()` 成功路径必须留下一行 `.stopped` 通知（`appendStopNotice`）。
    // 这里锁它的两条性质：真的产生一行；重复调用不叠加（同一轮只记一条）。
    var t = ChatTranscript()
    try t.apply(frame("token", #"{"text":"写一半"}"#, "1"))
    t.appendStopNotice()
    expect(t.notices.count == 1, "a stop appends exactly one notice row")
    expect(t.notices.first?.kind == .stopped, "the stop notice is kind .stopped")
    expect((t.notices.first?.message ?? "").isEmpty == false, "the stop notice carries visible text")
    expect(t.notices.first?.id.hasPrefix("notice-stopped") == true,
           "the stop notice id is derived from its kind")
    // 幂等：重复点停止 / 重连后再次收尾都不能叠加第二行。
    t.appendStopNotice()
    t.appendStopNotice()
    expect(t.notices.count == 1, "appendStopNotice is idempotent within one turn")
    expect(t.notices.filter { $0.kind == .stopped }.count == 1, "only one .stopped row ever exists")

    // 停止不是失败：不能顺带把 transcript 标成 failure。
    expect(t.failure == nil, "a stop is not an error")
    expect(t.messages.last?.content == "写一半", "a stop keeps the streamed reply")

    // 已有别的终态通知时，停止仍然要单独留一行（不同 kind 互不吞并）。
    var cancelled = ChatTranscript()
    try cancelled.apply(frame("cancel", #"{"message":"cancelled"}"#, "c1"))
    expect(cancelled.notices.map(\.kind) == [.cancelled], "cancel records its own notice first")
    cancelled.appendStopNotice()
    expect(cancelled.notices.map(\.kind) == [.cancelled, .stopped],
           "a stop after cancel adds its own row instead of being swallowed")
    // 反过来也一样：已经停过之后再来的 cancel 不会顶掉 .stopped 的幂等判定。
    cancelled.appendStopNotice()
    expect(cancelled.notices.filter { $0.kind == .stopped }.count == 1,
           "repeated stops never duplicate even next to another terminal notice")
    expect(Set(cancelled.notices.map(\.id)).count == cancelled.notices.count,
           "notice ids stay unique across kinds")

    // 通知行不参与消息列表：停止不能凭空造出一条 assistant 气泡。
    expect(cancelled.messages.isEmpty, "a stop notice is not a chat message")
}

test("accepted_run_receipt_is_unique_and_terminal") {
    let receipt = ActiveTurnRecovery(
        runID: "run-1", historyEnd: 2,
        knownIDs: ["old-u", "old-a"],
        text: "upload", attachmentPaths: ["/state/report.pdf"])
    func snapshotOf(_ rows: [[String: Any]], offset: Int = 0,
                    active: String? = nil) throws -> ChatSnapshot {
        var root: [String: Any] = [
            "session_id": "s", "_messages_offset": offset, "messages": rows,
            "read_only": false
        ]
        if let active { root["active_stream_id"] = active }
        return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: root))
    }
    let original: [[String: Any]] = [
        ["id": "old-u", "role": "user", "content": "earlier"],
        ["id": "old-a", "role": "assistant", "content": "earlier answer"]
    ]
    let submitted: [String: Any] = [
        "id": "fresh", "role": "user", "content": "upload",
        "attachments": [["path": "/state/report.pdf"]]
    ]
    let answer: [String: Any] = [
        "id": "reply", "role": "assistant", "content": "done"
    ]
    let valid = try snapshotOf(original + [submitted, answer])
    expect(receipt.confirmsCompletion(in: valid),
           "only the matching new turn followed by assistant may finish")
    let encoded = try JSONEncoder().encode(receipt)
    let decoded = try JSONDecoder().decode(ActiveTurnRecovery.self, from: encoded)
    expect(decoded == receipt, "accepted-turn receipt round-trips durably")
    let submittedOnly = try snapshotOf(original + [submitted])
    expect(!receipt.confirmsCompletion(in: submittedOnly),
           "submitted user text without a reply is not terminal evidence")
    let otherTurn = try snapshotOf(original + [
        ["id": "other", "role": "user", "content": "other"], answer])
    expect(!receipt.confirmsCompletion(in: otherTurn),
           "another client's turn cannot complete the current accepted POST")
    let duplicateTurn = try snapshotOf(original + [submitted, submitted, answer])
    expect(!receipt.confirmsCompletion(in: duplicateTurn),
           "duplicate matching user rows are ambiguous")
    let wrongFile: [String: Any] = [
        "id": "wrong", "role": "user", "content": "upload",
        "attachments": [["path": "/state/wrong.pdf"]]
    ]
    let wrongAttachment = try snapshotOf(original + [wrongFile, answer])
    expect(!receipt.confirmsCompletion(in: wrongAttachment),
           "attachment identity mismatch blocks unsafe completion")
    let truncated = try snapshotOf([submitted, answer], offset: 3)
    expect(!receipt.confirmsCompletion(in: truncated),
           "truncated history does not prove the start boundary")
    let stillActive = try snapshotOf(original + [submitted, answer], active: "run-1")
    expect(!receipt.confirmsCompletion(in: stillActive), "active stream is not completed")
}

test("recovered_run_needs_fresh_turn_evidence") {
    let oldAnswerOnly = try snapshot(#"{"session_id":"s","messages":[{"role":"user","content":"old"},{"role":"assistant","content":"old answer"}]}"#)
    expect(!oldAnswerOnly.confirmsRunFinished(afterRawIndex: 2),
           "a historical assistant answer cannot finish a newer disconnected run")
    expect(!oldAnswerOnly.confirmsRunFinished(afterRawIndex: nil),
           "an unknown start boundary cannot prove the recovered run finished")
    let userOnly = try snapshot(#"{"session_id":"s","messages":[{"role":"user","content":"old"},{"role":"assistant","content":"old answer"},{"role":"user","content":"new"}]}"#)
    expect(!userOnly.confirmsRunFinished(afterRawIndex: 2),
           "a fresh user message without a reply is not terminal evidence")
    let completed = try snapshot(#"{"session_id":"s","messages":[{"role":"user","content":"old"},{"role":"assistant","content":"old answer"},{"role":"user","content":"new"},{"role":"assistant","content":"new answer"}]}"#)
    expect(completed.confirmsRunFinished(afterRawIndex: 2),
           "a new user turn followed by its assistant answer proves completion")
    expect(!completed.confirmsRunFinished(afterRawIndex: 4),
           "the boundary cannot include only an older assistant reply")
    let active = try snapshot(#"{"session_id":"s","messages":[{"role":"user","content":"new"},{"role":"assistant","content":"answer"}],"active_stream_id":"still-running"}"#)
    expect(!active.confirmsRunFinished(afterRawIndex: 0),
           "an active run must never be inferred finished from history text")
}

test("attachment_patterns") {
    // 正则必须预编译成常量：总览每次渲染都会对整份 catalog 调用 paths，
    // 在循环里编译模式会把滚动拖成 O(条目数) 次编译。
    let many = (0..<40).map { "![x](https://example.invalid/\($0).png)" }.joined(separator: " ")
    let started = Date()
    for _ in 0..<50 { _ = AttachmentHistory.paths(content: many, attachments: nil) }
    let elapsed = Date().timeIntervalSince(started)
    expect(AttachmentHistory.paths(content: many, attachments: nil).count == 40,
           "every media reference is still extracted")
    expect(elapsed < 5, "repeated parsing stays bounded (took \(elapsed)s)")
    expect(AttachmentHistory.paths(content: "MEDIA:/a.png MEDIA:/a.png", attachments: nil) == ["/a.png"],
           "deduplication is unchanged")
    expect(AttachmentHistory.paths(content: "![x](javascript:alert)", attachments: nil).isEmpty,
           "dangerous schemes are still rejected")
}

test("unattributed_tools_do_not_move_to_latest_turn") {
    let snapshot = try ChatSnapshot(data: JSONSerialization.data(withJSONObject: [
        "session_id": "multi",
        "messages": [
            ["id": "u1", "role": "user", "content": "first"],
            ["id": "a1", "role": "assistant", "content": "answer"],
            ["id": "u2", "role": "user", "content": "second"]
        ],
        "tool_calls": [["id": "legacy", "name": "terminal", "result": "old result"]]
    ]))
    expect(snapshot.tools.first?.afterMessageID == nil, "Unknown ownership must not be invented from the last user")
}
test("long_run_page_coverage") {
    let latest = try snapshot(#"{"session_id":"test","_messages_offset":4,"messages":[{"id":"t4","role":"tool","content":"done"},{"id":"answer","role":"assistant","content":"complete"}]}"#)
    let earlier = try snapshot(#"{"session_id":"test","_messages_offset":0,"messages":[{"id":"sent","role":"user","content":"original"},{"id":"t1","role":"tool","content":"done"},{"id":"t2","role":"tool","content":"done"},{"id":"t3","role":"tool","content":"done"}]}"#)
    let gap = try snapshot(#"{"session_id":"test","_messages_offset":0,"messages":[{"id":"sent","role":"user","content":"original"},{"id":"t1","role":"tool","content":"done"},{"id":"t2","role":"tool","content":"done"}]}"#)
    let receipt = ActiveTurnRecovery(runID: "run", historyEnd: 0,
                                     knownIDs: [], text: "original", attachmentPaths: [])
    expect(!receipt.confirmsCompletion(in: latest), "tail without original user must stay uncertain")
    expect(receipt.confirmsCompletion(in: [latest, earlier]),
           "contiguous raw windows can prove a long tool run finished")
    expect(!receipt.confirmsCompletion(in: [latest, gap]),
           "a missing raw index cannot prove unique submission")
    let concurrent = try snapshot(#"{"session_id":"test","_messages_offset":0,"messages":[{"id":"sent","role":"user","content":"original"},{"id":"other","role":"user","content":"another"},{"id":"t2","role":"tool","content":"done"},{"id":"t3","role":"tool","content":"done"}]}"#)
    expect(!receipt.confirmsCompletion(in: [latest, concurrent]),
           "interleaved user submissions must remain ambiguous")
}

print("RESULT: \(assertions) assertions, \(failures) failures")
if failures > 0 { exit(1) }
