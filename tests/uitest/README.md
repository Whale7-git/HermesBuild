# Hermes iOS UI test Gateway

`mock_gateway.py` 是供 UI 测试使用的本地合成 Gateway。它只监听 loopback（`127.0.0.1`），不连接真实实例，不使用真实账号或用户数据。

## 运行

```sh
python3 tests/uitest/mock_gateway.py --port 8765
python3 -m unittest discover -s tests/uitest -p 'test_*.py' -v
```

## 测试数据与安全边界

- 固定响应数据保存在 `tests/uitest/fixtures/`；服务端路由、状态和故障注入实现位于 `mock_gateway.py`，对应契约测试位于 `test_mock_gateway.py`。修改路由或响应时同步更新测试，不要维护第二份路由清单。
- `/__control` 路由仅用于测试控制、重置和检查请求记录。请求日志只记录认证信息是否存在及其方案，不保存密钥、Cookie 值或消息正文。
- 未知路由返回 `501 MOCK_UNKNOWN_ROUTE`，并记录下来；不要为了让测试通过而静默模拟未实现的生产接口。
- 测试中的图片为内嵌合成 PNG，不会写入真实用户文件。

## 范围

Python 测试验证 mock Gateway 的 HTTP 契约和故障注入，不验证 iOS 真实手势、排版或设备行为。模拟器 UI 回归是独立的手动工作流；真机结果必须单独记录。

## Run 退化场景注入

线上 Gateway 的流保留期（`_RUN_STREAM_TTL=300`）短于状态保留期（`_RUN_STATUS_TTL=3600`），因此存在 **`GET /v1/runs/{id}` 返回 200、同时 `GET /v1/runs/{id}/events` 返回 404** 的真实窗口。mock 用 `/__control/scenario` 复现它：

```sh
curl -s -X POST http://127.0.0.1:8765/__control/scenario \
  -H 'Content-Type: application/json' \
  -d '{"events_404": true, "status_404": false}'
```

| 键 | 语义 |
| --- | --- |
| `status_404` | 所有 `GET /v1/runs/{id}` 返回 404（状态 TTL 过期），不影响 history |
| `events_404` | 所有 `GET /v1/runs/{id}/events` 返回 404（流 TTL 过期），与 `status_404` 独立生效 |
| `status_latency_ms` | `GET /v1/runs/{id}` 真实延迟，0–10000 |
| `status` | 覆盖状态读返回的 state（终态或非终态），`null` 表示恢复真实状态 |
| `output` | 覆盖状态读的 `output` 文本，`null` 表示使用 Run 自己的终态回复 |

- 部分更新：只改请求体里出现的键；`POST /__control/reset` 会把全部开关恢复默认。
- `GET /__control/scenario` 读取当前值；`GET /__control/log` 的 `scenario` / `resolved_runs` 字段同样可断言。
- `GET /v1/runs/{id}` 始终包含 `output`：终态是最终回复文本，非终态为 `null`，避免客户端把空串当作已完成答案。
- `POST /v1/runs/{id}/resolve-unknown` 返回权威投影 `{run_id,id,session_id,status,output,admission_id,execution_generation}`。`admission_id` 形如 `adm-{run_id}`，`execution_generation` 从 1 起每次调用递增；Run 不存在返回 404。它只结算 Run 记录，不写 history，避免掩盖后端真实持久化行为。
- 终态集合固定为 `{completed, failed, cancelled, interrupted}`；其余状态都按非终态处理。

对应用例在 `test_mock_scenarios.py`。

