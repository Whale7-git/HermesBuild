import Foundation
var count = 0
func expect(_ value: @autoclosure () -> Bool, _ label: String) {
 count += 1; if !value() { print("FAIL: \(label)"); exit(1) }
}
var t = ChatTranscript()
try t.apply(SSEFrame(event:"context_status",data:#"{"prefill":{"status":"applied","message_count":5}}"#,id:"1"))
expect(t.contextStatus == "applied", "prefill status is visible, not mistaken for token capacity")
try t.apply(SSEFrame(event:"done",data:#"{"session":{"session_id":"s","messages":[]},"usage":{"input_tokens":1200,"output_tokens":300,"context_length":200000,"last_prompt_tokens":1500,"estimated_cost":0.012}}"#,id:"2"))
expect(t.usage?.inputTokens == 1200, "done usage input parsed")
expect(t.usage?.contextFraction == 0.0075, "capacity percentage uses last prompt, not accumulated input")
let snap = try ChatSnapshot(data:Data(#"{"session":{"session_id":"s","_messages_offset":40,"context_length":10000,"last_prompt_tokens":2500,"messages":[{"role":"user","content":"问题"},{"role":"tool","content":"结果"},{"role":"assistant","content":"答复"}]}}"#.utf8))
expect(snap.messages[1].sourceIndex == 42, "raw index includes invisible tool rows and pagination offset")
expect(snap.usage.contextFraction == 0.25, "snapshot context usage parses server fields")
let plan = try MessageForkPlan.regenerate(messageID:snap.messages[1].id, messages:snap.messages)
expect(plan.keepCount == 40 && plan.text == "问题", "regenerate branches before the original user and sends it once")
let edit = try MessageForkPlan.edit(messageID:snap.messages[0].id, messages:snap.messages)
expect(edit.keepCount == 40 && !edit.sendImmediately, "edit starts draft in new branch without destructive truncation")
do {
 _ = try MessageForkPlan.regenerate(messageID:"missing",messages:snap.messages)
 expect(false,"unknown message rejected")
} catch { expect(true,"unknown rejected") }
let unknown = ChatUsage(fields:[:])
expect(unknown.contextFraction == nil && unknown.inputTokens == nil, "missing counters not fabricated as zero")
let zero = ChatUsage(fields:["context_length":10000,"last_prompt_tokens":0])
expect(zero.contextFraction == nil, "unreported zero prompt is not claimed as 0% used")
// A12: 溢出/非有限计数必须视为未报告，最坏 fraction*100 也不得让百分比渲染 trap。
let overflow = ChatUsage(fields:["last_prompt_tokens":1e18,"context_length":1])
expect(overflow.promptTokens == nil, "1e18 prompt tokens is unreported, not a fabricated counter")
expect(overflow.contextFraction == nil, "overflowing prompt yields no context fraction")
let nonFinite: [Any] = [1e19, Double.nan, Double.infinity, "1e400", "nan"]
for (index, value) in nonFinite.enumerated() {
    let usage = ChatUsage(fields:["last_prompt_tokens":value,"context_length":1000])
    expect(usage.promptTokens == nil, "overflowing or non-finite prompt token \(index) rejected")
    expect(usage.contextFraction == nil, "overflowing or non-finite prompt token \(index) yields no fraction")
}
let clamped = ChatUsage(fields:["last_prompt_tokens":1e12,"context_length":2e12])
expect(clamped.promptTokens == 1_000_000_000_000 && clamped.contextLength == 2_000_000_000_000, "business-bound counters stay legal")
expect(clamped.contextFraction == 0.5, "legal large counters still compute the fraction")
expect(ChatContextPressure(usage: nil) == nil, "missing usage never fabricates context pressure")
expect(ChatContextPressure(usage: ChatUsage(fields: [
    "last_prompt_tokens": 7499, "context_length": 10000
])) == nil, "context pressure stays hidden below 75 percent")
let elevated = ChatContextPressure(usage: ChatUsage(fields: [
    "last_prompt_tokens": 7500, "context_length": 10000
]))
expect(elevated?.severity == .elevated && elevated?.percent == 75,
       "75 percent starts the elevated warning")
let critical = ChatContextPressure(usage: ChatUsage(fields: [
    "last_prompt_tokens": 9000, "context_length": 10000
]))
expect(critical?.severity == .critical && critical?.message.contains("压缩") == true,
       "90 percent becomes critical and points to server-side compression")
expect(ChatContextPressure(usage: ChatUsage(fields: [
    "last_prompt_tokens": 1e18, "context_length": 1
])) == nil, "overflowing counters never produce context pressure")
// Recency groups use local calendar days, not 24-hour offsets (DST is 23/25h).
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
let iso = ISO8601DateFormatter()
func date(_ text: String) -> Date {
    guard let parsed = iso.date(from: text) else { fatalError("bad test date") }
    return parsed
}
let now = date("2026-03-09T08:00:00Z")
expect(SessionRecencyBucket.bucket(for: now, now: now, calendar: calendar) == .today, "today")
expect(SessionRecencyBucket.bucket(for: date("2026-03-08T08:30:00Z"), now: now, calendar: calendar) == .yesterday,
       "yesterday crosses spring DST without a 24h assumption")
expect(SessionRecencyBucket.bucket(for: date("2026-03-03T09:00:00Z"), now: now, calendar: calendar) == .week,
       "seven-day window includes six previous calendar days")
expect(SessionRecencyBucket.bucket(for: date("2026-03-02T09:00:00Z"), now: now, calendar: calendar) == .earlier,
       "older messages do not enter the recent week")
expect(SessionRecencyBucket.bucket(for: nil, now: now, calendar: calendar) == .unknown, "missing dates not fabricated")
expect(SessionRecencyBucket.bucket(for: date("2025-12-31T22:00:00Z"), now: date("2026-01-01T20:00:00Z"), calendar: calendar) == .yesterday,
       "year-boundary grouping")
expect(Set(SessionRecencyBucket.allCases.map(\.id)).count == 5, "stable distinct section identities")
func task(_ progress: Bool = false, queued: Int = 0, submitting: Int = 0, uncertain: Int = 0,
          verify: Bool = false, error: Bool = false, storage: Bool = false) -> ChatTaskSummary {
    ChatTaskSummary(activity: "连接中断，正在恢复…", progressing: progress, queued: queued,
                    submitting: submitting, uncertain: uncertain,
                    needsVerification: verify, hasError: error, storageIssue: storage)
}
expect(!task().visible, "idle adds no permanent chrome")
expect(task(true).title == "连接中断，正在恢复…", "reconnection never relabelled as running")
expect(task(true).kind == .progress, "ordinary progress is not warning")
expect(!task(true).needsActionBar, "ordinary progress stays in the navigation subtitle")
expect(task(submitting: 1).kind == .progress, "submitting is not uncertain")
expect(!task(submitting: 1).needsActionBar, "submitting uses the same single progress surface")
expect(task(queued: 2).kind == .queued && task(queued: 2).title == "待发送 2 条", "queue count visible")
expect(task(queued: 2).needsActionBar, "queued messages keep an actionable task bar")
expect(task(true, queued: 2).detail == "连接中断，正在恢复… · 查看消息队列",
       "one summary combines ordinary activity and queue")
expect(task(true, queued: 2).needsActionBar, "a queue keeps its action even while another request runs")
expect(task(true, uncertain: 1).kind == .attention, "uncertainty overrides progress")
expect(task(true, uncertain: 1).needsActionBar, "uncertainty always remains actionable")
expect(task(uncertain: 2).detail?.contains("不会自动重发") == true, "uncertain sends keep the safety action")
expect(task(verify: true).kind == .attention, "ordinary pending send exposes recovery")
expect(task(error: true).kind == .attention, "errors remain actionable")
expect(task(verify: true, error: true, storage: true).title == "本地数据需要检查", "storage failure retains priority")
expect(task(queued: -3).kind == .idle, "invalid negative display count is clamped")

// build151: the protocol envelope is a presentation-only disclosure.
// Original messages and their source indices remain unchanged.
let wrapped = "[OUT-OF-BAND USER MESSAGE — delivered once]\n已不是旧版本\n[/OUT-OF-BAND USER MESSAGE]"
let historical = ChatMessage(id: "oob-1", role: "user", content: wrapped, sourceIndex: 11)
expect(ChatBackgroundEnvelope.userBody(historical) == nil,
       "a history index and pasted OOB envelope do not prove background origin")
let labelledOOB = ChatMessage(id: "oob-2", role: "user", content: wrapped,
                             sourceIndex: 11, displayKind: "internal_notification")
expect(ChatBackgroundEnvelope.userBody(labelledOOB) == "已不是旧版本",
       "server-labelled OOB retains human-readable disclosure text")
expect(historical.content == wrapped, "original OOB text is preserved for export and copy")
expect(ChatBackgroundEnvelope.userBody(ChatMessage(id: "draft", role: "user", content: wrapped)) == nil,
       "locally composed user text is never reclassified as an OOB envelope")
expect(ChatBackgroundEnvelope.userBody(ChatMessage(
    id: "quoted", role: "assistant", content: wrapped, sourceIndex: 12)) == nil,
       "assistant quote never becomes an OOB notification")
expect(ChatBackgroundEnvelope.userBody(ChatMessage(
    id: "partial", role: "user", content: "[OUT-OF-BAND USER MESSAGE —", sourceIndex: 13)) == nil,
       "partial OOB marker is ordinary user content")
expect(ChatBackgroundEnvelope.userBody(ChatMessage(
    id: "server", role: "user", content: "hello", sourceIndex: 14,
    displayKind: "internal_notification")) == "hello",
       "explicit server label keeps a backend message collapsed")
print("EXPERIENCE_PASS \(count) assertions")
