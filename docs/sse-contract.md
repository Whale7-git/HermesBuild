# 网关 SSE 契约（抓包确认）

抓包时间：2026-11-11
端点：`GET /v1/runs/{run_id}/events`
鉴权：`Authorization: Bearer <API_SERVER_KEY>`
Accept：`text/event-stream`

## 实测字节流

```
: open

id: 0
data: {"event": "message.delta", "run_id": "run_...", "timestamp": 1794333820.31, "delta": "好", "seq": 0}

id: 1
data: {"event": "run.completed", "run_id": "run_...", "timestamp": 1794333820.88, "output": "好", "usage": {"input_tokens": 18521, "output_tokens": 2, "total_tokens": 18523}, "runtime": {...}, "completed": true, "partial": false, "interrupted": false, "seq": 1}

: stream closed
```

## 契约结论

1. **不发 `event:` 行**。事件名在 `data` JSON 的 `"event"` 字段里。客户端 `frame.event` 恒为 `"message"`，必须优先读 data JSON 的 `event`。
2. **`id:` 逐帧唯一且递增**（0, 1, …），与 data 内 `seq` 一致。按 `frame.id` 去重是安全的（R-13 关闭）。
3. `: open` / `: stream closed` 是 SSE 注释行，解析器应忽略。
4. `run.completed` 带 `completed`/`partial`/`interrupted` 布尔、`output` 文本、`usage` 计数。
   - `completed: false` = 预算/步数耗尽（本版应映射 work_limit）。
   - `partial: true` 或 `interrupted: true` = 半截/中断（本版按 cancel 收尾）。
5. 终态事件名（待补抓）：`run.failed` / `run.cancelled` / `replay.truncated` 尚未抓包，按 `GatewayEventMap` 现有映射处理，需在实现中 fail-safe。

## 对修复的影响

- P0-14/15 保持按 `frame.id` 去重，**不**改按 seq。
- P0-13：`completed` 必须严格 Bool；缺省/畸形视为「状态未知」，不当作正常完成。
- 新增回归 fixture 应直接使用上述真实字节流（含无 `event:` 行、带 `id:`），不要手工构造 `SSEFrame(event:)`。
