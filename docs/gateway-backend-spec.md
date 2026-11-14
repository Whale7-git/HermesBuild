# Hermes 全网关后端 · 当前实现契约

> **2.9.4 / build142 说明：** Gateway 实例运行时不再采用 WebUI fallback。
> 原生上传 `POST /v1/files`，原生附件下载与预览 `GET /v1/files/by-path`。
> 旧文档关于 WebUI 上传/模型回退的段落保留作历史资料，不代表此版的运行行为。

> **本文档描述的是客户端当前实现所依赖的契约，不是冻结的对外协议。**
> 网关是会随部署版本变化的第三方服务，本文件只能声明「客户端按什么假设实现」；
> 与服务端实际行为冲突时以抓包与生产客户端代码为准，并在文末「附录：历史设计」
> 里保留最初的设计假设，便于判断哪一条被现实推翻过。

> build65 实际契约复核（2026-11-10）：以下历史设计有几处与部署版不符，以本段及生产客户端实现为准。`/api/model/options` 可直接提供真实目录；`/api/sessions` 单页上限200，需遍历 `has_more`，返回不含归档且没有归档列表参数；`/messages?order=oldest` 保持追加时的绝对坐标，`message_count` 仅是待校验提示；`GET /v1/runs/{id}` 提供可核对状态，活动 ID 本机隔离保存；`message.interim.already_streamed=true` 不应重复追加；正常/失败/取消事件分别收尾。fork 不支持 keepCount，客户端会拒绝指定位置的请求。附件仍需要已登录的配套WebUI。

> 目标：HermesShell 从「WebUI 代理」切到「直连 Hermes 网关」，参考 Conduit 的
> 多后端分层思路。真缺的 2 个能力保留 WebUI 通道。

---

## 一、为什么切

WebUI 是给浏览器设计的一层代理，它的会话模型（sidecar）与网关的会话模型
（`state.db`）是两套。会话分层示例（以下 ID 为合成值）：

```
agent.log: [session-fork-example]        platform=api_server  history=0     ← WebUI fork 出的会话
agent.log: [session-parent-example] platform=reply      history=175   ← 父会话，同内容
```

`session-fork-example` 的 177 条消息只存在于 `webui/sessions/<id>.json`；网关
`/v1/chat/completions` 带 `X-Hermes-Session-Id` 时会丢弃 body 历史改读
`state.db`，而 fork id 在库里没有行 → `history=0` → 模型答「这是新会话」。

网关自己的 fork 是对的（`api_server.py:2788-2793`）：

```python
db.create_session(fork_id, ...)
db.end_session(source_id, "branched")
messages = await asyncio.to_thread(db.get_messages, source_id)
await asyncio.to_thread(db.replace_messages, fork_id, messages)   # 真复制
```

实测：`POST /api/sessions/session-source-example/fork` → `message_count: 312`。

---

## 二、网关能力实测清单

`GET /v1/capabilities`（用 `API_SERVER_KEY` 认证）：

| 能力 | 值 |
|---|---|
| `session_fork` / `session_chat_streaming` / `session_model_lock` | true |
| `run_submission` / `run_events_sse` / `run_stop` / `run_steer` | true |
| `run_approval_response` / `approval_events` / `tool_progress_events` | true |
| `reasoning_streaming` / `session_resources` | true |
| `cors` | false |

端点全集（实测）：

```
GET    /health                          GET  /health/detailed
GET    /v1/models                       GET  /api/model/options
POST   /v1/chat/completions             POST /v1/responses
POST   /v1/runs                         GET  /v1/runs/{id}
GET    /v1/runs/{id}/events             POST /v1/runs/{id}/approval
POST   /v1/runs/{id}/steer              POST /v1/runs/{id}/stop
POST   /v1/runs/{id}/resolve-unknown
GET    /v1/skills                       GET  /v1/toolsets
GET    /api/sessions                    POST /api/sessions
GET    /api/sessions/{id}               PATCH /api/sessions/{id}
DELETE /api/sessions/{id}               GET  /api/sessions/{id}/messages
POST   /api/sessions/{id}/fork          POST /api/sessions/{id}/chat
POST   /api/sessions/{id}/chat/stream   POST /api/sessions/{id}/model
```

---

## 三、接口映射（App 现有 → 网关）

| App 现有（WebUI） | 网关 | 说明 |
|---|---|---|
| `api/sessions` | `GET /api/sessions` | 字段更全：`preview` `tool_call_count` `parent_session_id` `pinned` `archived` |
| `api/session` | `GET /api/sessions/{id}/messages` | 分页 `limit`/`offset`/`order`(oldest\|latest) |
| `api/chat/start` | `POST /v1/runs` | 返回 `run_id`，两段式 |
| `api/chat/stream` | `GET /v1/runs/{id}/events` | SSE，支持 `Last-Event-ID` 续传 |
| `api/chat/cancel` | `POST /v1/runs/{id}/stop` | |
| `api/chat/steer` | `POST /v1/runs/{id}/steer` | 原生，不靠 WebUI 转发 |
| `api/session/branch` | `POST /api/sessions/{id}/fork` | **带历史** |
| `api/session/rename` | `PATCH /api/sessions/{id}` `{title}` | 只有一套标题 |
| `api/session/pin` | `PATCH /api/sessions/{id}` `{pinned}` | |
| `api/session/archive` | `PATCH /api/sessions/{id}` `{archived}` | |
| `api/session/delete` | `DELETE /api/sessions/{id}` | |
| `api/session/update`（换模型） | `POST /api/sessions/{id}/model` | |
| `api/session/new` | `POST /api/sessions` | body 可带 `id`/`title`/`model` |
| **`api/upload`（附件）** | **无** | → **保留 WebUI** |
| **`api/models`（模型目录）** | `GET /v1/models` 只有 `hermes-agent` 占位 | → **保留 WebUI** |

### 保留 WebUI 的两个能力

1. **附件上传**：网关根本没有 multipart 上传端点。`AttachmentViews` 里的
   `api/upload` 调用继续走 WebUI base URL。
2. **模型目录**：`/v1/models` 只返回 `{"id":"hermes-agent"}` 占位；
   `/api/model/options` 的 `models` 数组对未认证 provider 全为空。
   App 的模型选择器、`RecentModelStore`（`provider+model` 身份）、
   会话级模型切换都依赖真实目录 → 继续读 WebUI 的 `api/models`。

> 这两项只读/只写单向，不存在会话模型冲突，混跑安全。

---

## 四、SSE 事件映射

网关 `chat/stream` 与 `runs/events` 是两套事件名。**统一以 runs 为准**
（`/v1/runs/{id}/events` 是两段式，与现有协议天然对齐）。但两者在**线上形态**上也不
一样：runs 端点不发 `event:` 行、事件名在 data JSON 里。这是 P0 根因，先看 4.1。

### 4.1 必须先读的 P0 根因：runs 端点不发 `event:` 行

这是曾经让网关模式整体不可用的根因，务必先理解再读下面的映射表：

- **`/v1/runs/{id}/events` 不发 SSE 的 `event:` 行。** 抓包里只有 `id:` 和
  `data:` 两种字段，事件名放在 data JSON 的 `"event"` 字段里：

  ```
  id: 0
  data: {"event": "message.delta", "run_id": "run_...", "delta": "好", "seq": 0}
  ```

  因此 `SSEParser` 得到的 `frame.event` **恒为 `"message"`**。任何只按
  `frame.event` 分支的映射都会把所有帧当未知事件丢掉，表现为「连上了但一个字都
  不出来」。
- **`chat/stream` 端点则发 `event:` 行。** 所以映射层必须同时兼容两种形态：
  优先取 data JSON 的 `event`，为空才回退到 SSE `event:` 行。
- **两处名字冲突时整帧丢弃。** 若 data JSON 说 `run.completed` 而 `event:` 行说
  `message.delta`，这一帧不可信（可能是代理改写或伪造），直接丢弃，不做任何猜测。
- 去重按 `frame.id`（逐帧唯一递增，与 data 内 `seq` 一致），不按 `seq`。

实现位置：`GatewayEventMap.map(_:)` 与 `GatewayEventMap.rawEventName(of:)`。
抓包原始字节流、`id:`/`seq` 结论与终态事件名清单见
[`docs/sse-contract.md`](sse-contract.md)。

### 4.2 映射表

| 网关事件 | 载荷关键字段 | 映射到 App |
|---|---|---|
| `run.started` | `run_id`, `session_id` | 忽略（已有 streamID） |
| `run.queued` | | 无帧（网关生命周期帧，App 状态机没有对应语义） |
| `message.delta` | `delta` | `token` |
| `message.interim` | `text`；`already_streamed=true` 时丢弃 | `token`（并入 streaming） |
| `reasoning.available` | `text` | `reasoning` |
| `tool.started` | `tool`, `preview`, `tool_call_id` | `tool` |
| `tool.completed` | `tool`, `duration`, `error`, `preview` | `tool_complete`（`error` → `is_error`） |
| `run.steered` | | 无帧（仅记日志） |
| `run.stopping` | | 无帧（仅记日志） |
| `run.interrupted` | | 终止：`cancel`（通知行 `.interrupted`） |
| `run.cancelled` | | 终止：`cancel`（通知行 `.cancelled`） |
| `run.completed` | `output`, `usage`, `completed`, `partial`, `interrupted` | **`stream_end`**，见 4.3 |
| `run.failed` | `error` | `apperror` |
| `replay.truncated` | | `apperror`（续传窗口过期，需刷新） |
| `approval.request` | `tool`, `command`, `choices`, `approval_id` | `approval`（`choices` 硬限 `once`/`deny`/`reject`/`cancel`） |
| `approval.responded` | `request_id` | `approval_resolved` |
| `error` | `message` | `apperror` |

**终态白名单**（`GatewayBackend.streamNativeTurn` 按**原始事件名**判定，与 `map`
是否产出帧无关）：`run.completed`、`run.cancelled`、`run.interrupted`、
`run.failed`、`replay.truncated`、`error`。命中即清 `runStore`，即使该帧 map
失败也要清——否则坏帧会让 run 永久悬挂、下次启动锁死发送。

### 4.3 `run.completed` 映射成 `stream_end`，不是 `done`

早期设计写的是 `run.completed → done`，**这是错的，已实测推翻**：

- `done` 在 `ChatTranscript` 里的语义是「用快照里的 messages 覆盖整个列表」。
- 而网关的 `run.completed` 只给一段 `output`，没有真实消息行 id / `sourceIndex`。
  合成一条消息覆盖整个列表，会把已加载历史压成一条，随后的 history 拉取再重建
  一遍——用户看到的是「回复刚结束、历史闪一下」，正在拖选的文字立刻被打断。
- 因此正常收尾发 `stream_end`（只标记结束、保留已流式内容，`usage` 照常透传）；
  `partial` / `interrupted` 发 `cancel`（保留半截内容并给出可见提示）；
  `completed: false` 发 `stream_end` + `status: work_limit`（预算耗尽，通知行
  `.workLimit`）。

**`run.completed` 的 `partial`/`interrupted` 必须保留语义**：现有
`ChatTranscript.terminal` 依赖它判断这轮是否完整，不能一律当成功。

**`completed` 必须是严格 `Bool`**：缺省 / `null` / `"unknown"` / `2` / `{}` 一律
视为「状态未知」（`stream_end` + `status: unknown` + 中性通知），不得伪装成正常
完成绕过 `work_limit` 判定。

---

## 五、客户端架构

### 新增协议（拆开「聊天」与「会话管理」）

```swift
/// 会话生命周期 + 列表元数据。WebUI 与网关各一份实现。
protocol SessionService: AnyObject {
    func sessions(limit: Int?, includeArchived: Bool) async throws -> [SessionSummary]
    func createSession(title: String?, model: String?) async throws -> String
    func renameSession(sessionID: String, title: String) async throws
    func setSessionPinned(sessionID: String, pinned: Bool) async throws
    func setSessionArchived(sessionID: String, archived: Bool) async throws
    func deleteSession(sessionID: String) async throws
    func forkSession(sessionID: String, keepCount: Int?) async throws -> String
    func setSessionModel(sessionID: String, model: String, provider: String?) async throws
}
```

`NativeChatService`（已有）保持不变 —— 它已经是「聊天轮次」的正确抽象。

### 后端组合

```swift
enum BackendKind: String, Codable { case webui, gateway }

struct HermesInstance {
    var id = UUID()
    var name: String
    var baseURL: String        // gateway 模式：网关地址 + API key
    var apiKey: String?        // gateway 必填
    var backend: BackendKind = .webui
    var webuiBaseURL: String?  // gateway 模式下附件上传 / 模型目录用
}
```

**gateway 实例的 `api` 是一个组合体**：

```
GatewayChatService   → NativeChatService（聊天轮次，/v1/runs）
GatewaySessionService→ SessionService（列表/fork/改名…）
WebUIFallback        → 附件上传 + 模型目录（只这两项）
```

`AppState.api` 的类型从 `HermesAPI` 改为一个聚合协议：

```swift
protocol HermesBackend: NativeChatService, SessionService {
    var attachmentBaseURL: URL { get }   // 上传走这里
    var chatRequests: ChatRequests { get }
    func availableModels() async throws -> ModelCatalog
    func authStatus() async throws -> AuthStatus
    func login(password: String) async throws
    func performNative(_ request: URLRequest) async throws -> Data
    func syncCookiesToWebKit() async
    func syncCookiesFromWebKit() async
}
```

`HermesAPI`（WebUI）与 `GatewayBackend` 都实现它 → `AppState` / `NativeChatModel`
几乎不用改。

---

## 六、分页语义差异（易错点）

WebUI：`api/session?msg_limit=60&msg_before=<index>` —— 游标是**消息索引**。
网关：`/messages?limit=60&offset=<n>&order=oldest` —— 是 **offset 分页**。

映射规则（当前实现，`GatewayHistoryReader`）：
- **一律 `order=oldest`**：offset 是从会话头部数的**绝对坐标**，另一端追加消息
  不会让已读窗口的坐标漂移。用 `order=latest` 会随尾部增长整体平移，翻页时
  重复或漏行。
- 首屏：`GET /api/sessions/{id}` 的 `message_count` 只是**待校验提示**，不是真相。
  按它算出 `start = max(0, total - pageSize)` 后拉 `pageSize + 1` 行探测尾部；
  探测不符（有第 61 行、或短于 60 且 start≠0）就二分重算真实总数，最多 3 轮。
- 加载更早：`before` 必须命中已记下的页锚点，否则报「历史分页位置已失效，请刷新会话后
  重试」；取回后再核对最后一行的 id 是否仍等于锚点，不等则报「历史已被修改，请刷新
  会话后再加载更早消息」并整页拒绝。
- 同一会话的 `read()` 串行化（每会话一条 `Task` 链），避免并发刷新交错覆盖锚点。

`ChatSnapshot.rawMessageEndIndex` 必须仍表示「本窗口的排他末端」，
`olderOffset` 表示「已加载到第几条（从末尾往前的偏移）」。这两者在
`applySnapshot` / `trimLoadedMessages` 里有强依赖，映射错了会重复或丢消息。

**网关消息行的 `id` 是整数**（`86643`），WebUI 是字符串。
`stableMessageID` 需要接受整数 id 并转成字符串，否则
`PlaceholderCandidate.knownIDs` 的绑定会失效。

---

## 七、必须保持不变的行为（回归基线）

1. `canSend` 仍是「能开新一轮」；`canSendWhileRunning` 独立算。
2. `steer/queue/interrupt` 三条路径的失败语义不变。
3. 附件未全部就绪不允许发送。
4. `pendingSend` 的「结果未确认 → 核对 → 重发/放弃」三态。
5. 分页双预算（2000 条 / 16MiB）与整页原子提交。
6. 日志作用域（`beginScope` 不重建缓冲区）。

---

## 八、验收标准

- [ ] 网关实例能列出会话、进会话、发消息、流式收、停止、引导
- [ ] **fork 后 `history` 不为 0**（这是本次的核心目的）
- [ ] 重命名后 WebUI/Desktop 看到同一标题
- [ ] 附件仍可上传并随消息发出
- [ ] 模型选择器仍能列出真实模型并切换
- [ ] WebUI 实例行为完全不变（不能回归）
- [ ] 离线单测全过（含新增的网关事件映射用例）

---

## 附录：历史设计假设（已被实现推翻，仅存档）

下面几条是最初「冻结」时写下的判断，后续实测/实现证明是错的。保留它们是为了
避免有人拿旧文档当规范回退实现。**不要按这一节写代码。**

| 原设计假设 | 现实 | 现在的做法 |
|---|---|---|
| 合约层冻结，并行模块按本文档实现 | 网关随部署版本变化，文档无法冻结 | 本文档只声明客户端当前假设，冲突以抓包为准（见文首） |
| `run.completed → done` | `done` 会用快照覆盖整个列表，网关只给一段 `output`，历史被压成一条、拖选被打断 | `stream_end`（见 4.3） |
| `runs/events` 与 `chat/stream` 事件形态相同，按 `event:` 行分支即可 | runs 端点**不发 `event:` 行**，事件名在 data JSON 里，`frame.event` 恒为 `message` | 优先读 data JSON 的 `event`（见 4.1） |
| `/messages?order=latest` + `_messages_offset` | latest 会让坐标随尾部增长平移，翻页重复/漏行 | `order=oldest` 绝对坐标（见第六节） |
| `message_count` 可直接当总数用 | 会过期（另一端追加、压缩） | 仅作提示，探测 + 二分校验 |
| `message.interim` 一律并入正文 | 部署版对已通过 delta 下发的内容标 `already_streamed=true` | 该标记为 true 时丢弃 |
| fork 支持 `keepCount` 指定位置分支 | 部署版只支持完整复制 | 客户端在发请求前就拒绝（501） |
| 归档可双向操作 | 没有归档列表接口，归档后找不回来 | App 内拒绝归档 |
| `/v1/models` 可当模型目录 | 只有 `hermes-agent` 占位 | 回落 WebUI 的 `api/models` |
