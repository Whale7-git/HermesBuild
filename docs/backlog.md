# 待办清单（历史快照，非当前 GPT 构建规范）

> 本文依据 **2.7.1 / build136** 当时的代码和工具链整理。包括 Linux/xtool、自托管 Runner 的结论仅反映历史实现；当前 GPT 构建已改为 GitHub 托管 macOS + Xcode，详见 `docs/gpt-cloud-build.md`。本文不作为 2.28.0/build170 及以后版本的现行发布入口或状态依据。

> **状态：2.7.1 / build136 复核。**
>
> 上一版复核停在 1.37.0 / build117，中间隔了 9 个版本，导致本文长期与实际代码不符：
> 大量标着「仍未修」的条目其实早已关闭。本次逐条对着代码核实后重写。
>
> 现在本文只保留**真正未做的事**。已关闭的条目移到文末「关闭记录」，作为追溯，
> 不再参与排期讨论。

阅读约定：

- **编号**沿用三团队审查报告的编号，便于回查原始证据。
- **位置**按符号名找，不写死行号——行号会漂。
- **未验项**单独成章，不混在待办里。它们是「已知没验」，不是「待修」。
- 判定「不需要修」的条目也列出来，避免下一版重复讨论。

---

## 一、代码项

**当前没有待修的代码项。**

F-64 残差（vendored 改动没有可重放的 patch 文件）已在 2.6.0 关闭：
`Vendor/Textual/patches/` 现有 17 个补丁，实测在干净上游 checkout 上
`git apply -p1` 全部成功且逐字节一致；`UPSTREAM-SHA256.json` 补了 `local_files`。

顺带查出一处**记录错误**：`HERMES-PATCHES.md` 写「7 处本地改动」，逐字节比对
实际是 **17 个文件**有差异。另外 10 个集中在文本选择交互、高亮分词、
`BlockVStack`、`TextFragment` 与 `Style/Overflow.swift`，此前没有任何文字记录。
这说明「靠人写说明维护 vendored 改动」本身不可靠——已改用 patch 文件为准。

---

## 一之二、App Intents：写了但不可用，已从 main 摘除

**结论：在当前构建链下不可实现。代码留档于分支 `feat/app-intents-macos-only`，主线不再携带。**

### 发生了什么

2.6.0 曾加入两个 App Intent（问 Hermes / 新建会话），Release 编译 0 error / 0 warning，
IPA 结构审计全过。但收尾检查 IPA 内容时发现：

```python
[n for n in zipfile.ZipFile(ipa).namelist() if 'appintents' in n.lower()]
# → []
```

**AppIntents 元数据条目为 0，快捷指令里根本不会出现这两个动作。**

### 根因

Apple 需要 `appintentsmetadataprocessor` 在编译后扫描 `AppIntent` 声明、生成
`Metadata.appintents`。该工具**只存在于 macOS 的 Xcode 里**。本项目构建链是
Linux + Swift 6.4.2 + xtool，容器内实测该工具不存在。

没有元数据，系统不知道 App 声明了任何 intent。**代码能编译，只是产物里没有那部分。**

### 为什么拖到 2.7.1 才摘

2.6.1 做了撤回，但那个提交只落在 `release/2.6.1` 分支、没进 main；2.7.0 从 2.6.0
的提交拉出，把死代码又带进了 main。**分支与主线的合并顺序没对齐，等于撤回白做一次。**
本版补上，同时把版本号提到 2.7.1 / build136——2.7.0 和 2.6.1 都是 build135，
SideStore 按 build 号比新旧，2.6.1 永远推不上去。

### 教训（比结论更重要）

1. **「能编译」与「能生效」是两个不同主张。** 离线套件、源码门禁、Release 编译、
   IPA 结构审计四道全绿，功能依然是死的。凡依赖元数据/资源/entitlement 的能力
   （App Intents、Widget、Live Activity、后台模式），收尾必须查该产物**在不在 IPA 里**。
2. **二进制符号搜索不能用来判断「代码在不在」。** Release 优化会把没有动态引用的
   静态类型整体消除。实测：`HermesIntentPlan` 这类纯 Foundation 枚举在 2.6.0 和 2.7.0
   的二进制里都搜不到，但源码确实存在且确实编译了。有运行时引用的
   （`TaskAcknowledgement` 146 次、`SystemNotificationDeliverer` 44 次）才搜得到。
   **判断源码在不在，看源码树；判断产物有没有，看元数据与资源清单。**
3. **撤回类提交必须进 main，不能只停在发布分支。** 否则下一个从旧提交拉出来的版本
   会把它整个带回来，而且没人会发现——因为「删掉的东西」不会报错。

### 如果将来要做

需要 macOS 构建链，两条路：

| 路径 | 成本 |
|---|---|
| GitHub Actions `macos-latest` | 私有仓库 macOS 计费 $0.062/分钟，按 Linux 的约 10 倍折算额度；Free plan 约 20 次/月。改 public 则免费但源码公开 |
| 本地 Mac | 需一台 Mac |

另需把构建从 SwiftPM 改成 `xcodebuild archive ... CODE_SIGNING_ALLOWED=NO`。
**这条路未验证过**，不要当成「改个 workflow 就行」。

### 零成本替代

不需要 App 提供 intent 也能从快捷指令调用：用「获取 URL 内容」动作直接
POST 到网关的 `POST /v1/chat/completions`（实测 HTTP 200，`stream:false` 可用，
返回标准 OpenAI 结构）。缺点是动作不出现在 Siri 短语里，只能在快捷指令 App 内使用。

---

## 二、已知未验（离线测试覆盖不到）

以下不是缺陷，是**覆盖边界**。离线套件通过**不能**推导出这些行为正确。

### 2.1 设备项

| ID | 为什么离线测不了 | 要确认什么 |
|---|---|---|
| R-RECOVER-01 | 锁屏/后台/断流恢复涉及系统调度 | 不重复发送、不错误宣布完成；切后台再回来能恢复同一 run |
| R-STOP-01 | 停止的 404/409 竞态只在真实网关出现 | 停止中不误显示完成；`.stopped` 通知行只出现一条 |
| R-SELECT-02 | 跨段拖选与流式完成时机强相关 | 流式选字到完成不丢选区 |
| R-STREAM-01 | 跟随/脱离的迟滞体感只能手测 | 上翻停止跟随；回到底部恢复；不抖 |
| R-PERF-01 | 需真实内存与耗时 | 1万/2万字首开、滚动、选字、流式结束 |
| R-AX-01 | VoiceOver 焦点顺序需设备 | 附件预览/编辑/删除/重试独立可激活 |
| R-LIMIT-01 | 历史窗口到上限的提示与导出 | 不跳页、显示原因、导出仍可用 |

### 2.2 2.5.0 新增的未验项

| 项 | 离线能验的 | 离线验不了的 |
|---|---|---|
| 本地通知 | 三类通知的**决策**逻辑（29 条断言） | 真实投递、横幅样式、通知中心堆叠替换、权限弹窗 |
| 标记已处理 | 确认记录的 CRUD、90 天淘汰、撤销、问题重现后失效（19 条断言） | SwiftUI 里 `HStack` + `onTapGesture` 的实际点击与无障碍语义 |
| 上传进度 | 百分比/字节数文案、整百分比节流（16 条断言） | 真实上传时的视觉表现 |

### 2.2b 2.7.0 微动效的未验项

2.7.0 给已有的状态变化加了过渡：工具卡片运行中呼吸、三处图标切换用
`contentTransition(.symbolEffect(.replace.magicReplace))`、五处展开箭头旋转加
0.15s `easeOut`。

这些**全部是渲染期修饰符**，离线套件无法断言（`ChatUtilities`、`ChatMessageViews`、
`ChatComposer` 本来就不在任何编译单元里）。所以本版没有新增测试——造假断言只会
制造虚假覆盖。

| 项 | 离线能验的 | 离线验不了的 |
|---|---|---|
| 工具卡片呼吸 | 能编译、不破坏逻辑 | 节奏是太快、太慢还是刚好 |
| 图标变形 | `magicReplace` 语法正确 | `arrow.up` ↔ `stop.fill` 上观感是否自然（两者非同一符号家族，会退化为交叉淡入+缩放） |
| 箭头旋转 | 0.15s `easeOut` 与既有动画一致 | 快慢手感 |
| 减弱动态效果 | 5 处结构体都读了 `accessibilityReduceMotion` | 系统是否真的停掉动画 |

### 2.3 侧载环境的硬限制

**这一节解释为什么某些功能「看着能做但实际不行」，避免下一版重复尝试。**

| 限制 | 依据 | 影响 |
|---|---|---|
| 后台任务静默失效 | SideStore 用免费证书安装时改写 bundle ID，但不同步改写 `BGTaskSchedulerPermittedIdentifiers`（SideStore issue #1475 实测：`register()` 返回 true、`submit()` 不报错、handler 永不触发、无任何日志） | `BGAppRefreshTask`、`BGProcessingTask`、`BGContinuedProcessingTask`、`LongRunningIntent` 全部不可用 |
| 通知仅前台 | 我们用的是 `trigger: nil` 立即投递，Apple 明确该方式要求 App 运行中创建 | App 被系统挂起或结束后收不到通知 |
| **App Intents 元数据缺失** | 构建链是 Linux + Swift 6.4.2 + xtool，**没有 Apple 的 `appintentsmetadataprocessor`**（该工具只在 macOS Xcode 里）。实测 2.6.0 的 IPA 里 AppIntents 相关条目 **0 个**，`AppIntent` 声明不会被系统发现 | 2.6.0 的「问 Hermes」「新建会话」两个 intent **编译通过但不出现在快捷指令里**。代码保留，等有 macOS 构建环境才生效 |
| Widget / Live Activity 受 App ID 限制 | 每个 extension 消耗一个 App ID，免费账号上限 10 个、7 天过期 | 加 extension 类功能前必须确认 ID 余额 |
| APNs 不可用 | 需服务端改造 + 证书，交接文档明确禁止改服务端 | 无法做真正的远程推送 |

已关闭的 R 项：**R-13**（SSE `id:` 是否逐帧唯一）已抓包确认逐帧唯一递增，
按 `frame.id` 去重安全，结论记录在 `docs/sse-contract.md`。

---

## 三、已判定「不需要修」，勿在下一版重开

| 编号 | 结论 |
|---|---|
| F-66 | 正面项：`TODO/FIXME/XXX/HACK` 0 处、生产源码真实 `print` 0 个、无硬编码密钥。保持即可 |
| F-76（前半） | `../`、绝对路径、NUL、`\`、`/`、百分号编码的 `..` 均已拦截，UUID 目录 + 符号链接检查有效 |
| A-18 | 单例 `addObserver` 无反注册：进程级单例，不构成泄漏 |
| F-69 | `AttachmentModels.swift` 已判 `CancellationError` 再决定是否 `batch.fail`，取消不再渲染成红色失败态 |
| F-29（完全可重现构建） | 值得做但收益低于成本。`scripts/repro-check.sh` 已在，需要时手工量化即可 |
| F-55e | `ImageRatioStore` 保持静默，逐处加「可忽略」注释；不为纯展示引入埋点 |

---

## 四、门禁与流程

现状（已实现，记录备查）：

- **版本单一真源**：`release.json` 提供 `version` / `build`，`verify_source.py`、
  `release-local.sh`、`build-on-9.ps1` 三处都从它读；scope 文件名由 `{build}` 派生。
- **`Info.plist` 是静态文件**，仍需手工同步——`release.json` 的 `_note` 已写明。
  **`build` 必须是字符串**，写成数字会被门禁拒绝。
- **新增/改动文件必须先重生成 scope**，否则门禁报
  `changed scope mismatch: undeclared=[...]`。`gen_release_scope.py` 通常要跑两次才收敛。
- **孤儿套件（F-84）已关闭**：`tests/restoration` 与 `tests/markdown` 引用的 API 早已不存在，
  已删除；跟随/迟滞由 `tests/scroll`、Markdown 分段由 `tests/markdownblocks` 覆盖。

---

## 五、关闭记录（逐条对应上面的编号）

| 编号 | 关闭方式 | 验证 |
|---|---|---|
| F-55a | `ChatHistoryStore` 编码失败改为删除该条缓存 + 返回失败 + stderr 留痕，不再留下更旧的窗口冒充最新；1.43.0 进一步返回失败分类并接入运行时日志 | `tests/historycache` |
| F-55b | 文件级 `completeFileProtection` / 排除备份失败时**不写这份缓存**（宁可没缓存，不要可备份的明文）；目录级仍可容忍；1.43.0 将安全属性失败分类上报 | 编译 + `tests/historycache` |
| F-55c | `InstanceCredentialStore` 脱敏分支编码失败即放弃写入并保留旧值 | `tests/credentials` 28 条 |
| F-55d + F-71 | `GatewayRunStore.persist` 写后回读比对；失败置 `persistenceFailed`。后端标记每次写入按本次结果重置，聊天页在观察到失败后保持一次粘滞提示，当前进程仍以内存记录防止重复发送 | `tests/gatewaybackend` + `tests/model` |
| F-55e | `ImageRatioStore` 保持静默，逐处加「可忽略」注释；不为纯展示引入埋点 | — |
| F-23 | 上限提为 `GatewayAnchorLimits`（64 会话 / 256 锚点）+ 只读测试快照；断言超限后淘汰的是**最旧**的、最新 64 个仍在 | `tests/gatewaybackend` |
| F-78 | 会话列表分页上限提为命名常量 + 总请求预算，超预算抛 429；历史侧已有 30 次预算 | 编译 + `tests/gatewaybackend`（2 条：429 文案、精确命中预算数） |
| F-68 | 同一轮内同名工具 > 1 且结果行缺 `tool_call_id` 时**不认领**，单独成卡并标「未能关联」——宁可多一张卡也不挂错轮次 | 编译 + `tests/gatewaybackend`（6 条：歧义不认领、结果各归其位、对照组、显式 id 摘除） |
| F-75 | `opaqueFilePath` 的 `..` 防护补 9 条断言：6 种必须拒绝（含 `%2e%2e%2f`、`..%5c..`、`//host`）、3 种必须通过（避免过度拦截） | `tests/attachments` |
| F-64 | `THIRD_PARTY_NOTICES` 补 vendored Textual 上游 revision 与本地改动清单；`swiftui-math` 改 `upToNextMinor` 封上界（**patch 文件仍未建，见第一节**） | 编译 |
| F-29 | 新增 `scripts/repro-check.sh`（手工量化工具，不入流水线）：同 commit 跑两次、比 sha256、不同则解包逐文件定位 | 脚本 `bash -n` |
| F-67 | 85 个 `evidence-*.txt` 移入 `outputs/evidence/`（保留目录结构），`outputs/` 已加入门禁忽略集 | 门禁 pass |
| F-84 | 删除两个引用已移除 API 的孤儿测试目录；保留仍有效的 `tests/scroll` 与 `tests/markdownblocks` 覆盖 | 全量离线门禁 |
| F-73 | 三个巨型文件 3948 → 1474 行：`NativeChatModel` 1345→492（+Send/+Stream/+Control）、`NativeChatView` 1321→448（+4 个）、`StableChatScrollView` 1282→534（+Geometry/+Coordinator） | 编译 + 全部离线套件 |
| F-72 | `valid == false` 时写一行 stderr 诊断，只含 scope 标识不含 id | 编译 |
| F-77 | `canRead` 默认改 `false`（fail-closed）；`AppState.init` 末尾补 `configureAppScope`，保证任何读取前已登记作用域 | `tests/runtimerecorder`（含「未配置时不提供他人磁盘快照」正面断言） |
| F-76 残差 | 文件名做 `Cc`/`Cf` 过滤（含 U+202E）、按 UTF-8 字节截断到 255、Unicode 归一化 | `tests/attachments` |
| A-17 | 网关 `login` 改为抛 501「使用 API Key，不支持密码登录」，不再静默成功；`sessionsForFiltering` 确认**非**协议要求（`SessionDiscoveryService` 只声明 `searchSessions`/`archivedSessions`），已删除、调用点改用 `sessions()`；`syncCookiesTo/FromWebKit` 是 `HermesBackend` 协议要求，保留并注明 | 编译 + `tests/gatewaybackend`（2 条：501、零请求） |
| A-19 | README 历史段落加「当前版本见文首」；三份旧 manual 移入 `outputs/archive/` | 门禁 pass |
| A-20 | `run_native.sh` 远程目录改为 `$(date +%s)-$$` 独立后缀 + `trap` 清理，并发不再互相覆盖 | 脚本 `bash -n` |

---

## 六、当前规模（2.7.0 / build135）

| 项 | 值 |
|---|---|
| 生产源文件 | 139 个 `.swift` |
| 离线套件 | 50 个 |
| 通过项 | 413 |
| 门禁文件数 | 546 |
| 最低系统 | iOS 18.0 |
