# Gateway SSE 历史抓包样例（2026-11-11）

> **证据性质：单次历史抓包，不是当前 API 契约。** 本文只记录当时观察到的响应字节和字段。不能据此保证当前服务器、其他版本或所有运行路径都使用相同端点、事件、字段或终态语义。当前行为必须结合服务端版本、客户端源码和实时请求重新验证。

抓包时间：2026-11-11  
端点：`GET /v1/runs/{run_id}/events`  
鉴权：`Authorization: Bearer <API_SERVER_KEY>`  
Accept：`text/event-stream`

## 原始样本

```text
: open

id: 0
data: {"event": "message.delta", "run_id": "run_...", "timestamp": 1794333820.31, "delta": "好", "seq": 0}

id: 1
data: {"event": "run.completed", "run_id": "run_...", "timestamp": 1794333820.88, "output": "好", "usage": {"input_tokens": 18521, "output_tokens": 2, "total_tokens": 18523}, "runtime": {...}, "completed": true, "partial": false, "interrupted": false, "seq": 1}

: stream closed
```

## 该样本中观察到的现象

1. 样本没有 SSE `event:` 行；事件名放在 data JSON 的 `event` 字段中。
2. 样本中的 SSE `id` 为 0、1，且与 JSON `seq` 相同。只有这两帧，不能推导所有服务端实现都保证二者一致。
3. `: open` 和 `: stream closed` 是该样本中的 SSE 注释行。
4. 样本的 `run.completed` 含 `completed`、`partial`、`interrupted`、`output` 和 `usage` 字段；本样本只展示 `completed: true`，不证明其他组合的服务端语义。
5. 当时未抓到 `run.failed`、`run.cancelled` 或 `replay.truncated` 样本。未抓到不代表服务端不存在这些事件。

## 使用边界

- 这份记录可用于理解历史抓包、定位协议差异；不能替代当前服务端 API 文档或实时契约测试。
- 新增/修改事件映射时，以当前真实请求和服务端实现为依据，并增加对应 fixture 与确定性测试。
- 不要将本文中的历史 Issue 编号、旧版本修复要求或推测的终态映射当成现行实现规范。
