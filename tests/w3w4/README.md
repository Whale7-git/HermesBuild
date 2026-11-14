# W3/W4 只读回归审查（基线 e7ae8cb）

仅新增独立测试；未修改 AppState、其他业务源码、构建/发布脚本、release scope。
此基线的 release.json 仍为 **2.3.0 / build131**，不是已发布 2.4 的构建证明。

## 运行

在隔离编译目录 `/work/hermes24-races` 内：

```sh
python3 tests/w3w4/run.py races             # 当前预期退出 1：两个真实竞态回归为 RED
python3 tests/w3w4/run.py observation       # 退出 0：状态投影及持久记录清理
python3 tests/w3w4/run.py export-recovery   # 退出 0：导出控制器恢复子状态
```

可单独指定竞态，例如：

```sh
python3 tests/w3w4/run.py races stop-old-completion-new-stop
```

`run.py` 从既有 `tests/run_container.sh` 获取实际生产文件列表，编译真实模型。
测试不发生产请求。临时生成文件与二进制均在自己的 `.build/w3w4` 下。

## W4 已确认缺陷：stop 的 defer 不属于任何请求作用域

生产位置：`NativeChatModel+Control.swift:60-95`（尤其 66 行）。

1. `stop-background-failure`：挂起停止请求 → `disconnect()` 推进 revision →
   停止请求失败。catch 因 generation 不匹配跳过，但 defer 无作用域校验，
   `.stopping` 被置 `.idle`。实际状态：
   `suspended=true phase=idle streamID=run running=false`。
   后台运行未被证实结束，模型却丢失 running 事实。
2. `stop-old-completion-new-stop`：第一笔停止挂起 → 离页/回页 GET 重接同一 run →
   第二笔停止挂起 → 第一笔返回失败。第一笔 defer 把第二笔的 `.stopping` 写成 idle。
   第二笔仍在途时实际状态：`phase=idle canSend=true streamID=run`。
   不只是提示偏差：普通发送门禁已打开。

两例首次编译即真实 RED；没有通过改生产代码制造 GREEN。
既有 `tests/model/main.swift:308-323` 只覆盖“旧停止返回时当前已是 streaming”，
因此绕过了 defer 对“第二个 stopping”的覆盖，也没覆盖未回页的悬挂失败。

**最小修复建议（未实施）：** 给停止提交引入独立请求身份，defer 仅能清理它自己拥有的
状态；未确认停止时保留 run ID，落回未连接的运行/待核对状态，不能无条件 idle。
仅给 defer 加 revision 判断还不足以处理离页后的失败：不要把原停止状态永久留住。

## 已通过的现有行为

- 审批在途离页/后台：旧成功/旧失败不撤卡、不写当前错误、不重复审批，也不停止后台。
- 回页同一审批保持单飞；当前 SSE `approval_resolved` 才移除该卡片。
- 回页换审批后，旧响应及其 defer 不清新卡、不解锁新审批提交。
- 页面仍在前台时，普通停止失败保留 run ID 和未连接 streaming，不伪造停止终态通知。
- `runRecoveryNoticeShown` 对同一 model/page 粘性：成功写入、GET、idle 均不清除。
  新 model 经 `resumeForeground()` 重观察健康/降级 backend，不继承旧 model 的 warning。
- W3 使用**原样提取**的生产 `recordTaskSignals()`，连接真实 AppState/SessionTaskStore：
  同 model 恢复 warning 保留；新健康 model 明确重观察后，旧 recovery/approval/
  verification/stopping 信号从内存与持久记录删除。未新增“标记已处理”。
- 复用原有 PendingRecoveryTests / ActivityRecoveryTests / PhaseTransitionTests：
  pendingAbsent 才重发；active/部分历史/失败 GET 不重发；EOF/前台恢复仅 GET，不重复 POST。
- 导出控制器失败范围保留、dismiss 后同范围重试、已加载范围失败标记、取消 ticket 失效、
  ready→share 状态通过；既有 TranscriptPager 29 断言及 TranscriptExporter 18 用例通过。

## W3 必须保留的证据边界

`observation` 是 headless 投影/存储测试，**显式调用**真实观察函数，不证明 SwiftUI 自动触发。
生产 `NativeChatView.swift:5-20` 的 recorder 只有 `.onChange`，未见 initial/onAppear 调用；
`.task` 在 276 行初次 `model.load()` 后也未显式 `recordTaskSignals()`。
新建健康 idle model 的 watched facts 可以从始至终均为 false/nil：loading→idle 本身不在
观察字段中。故旧持久提醒**可能直到离页（307-309 行）或另一个 watched fact 改变才被清掉**。
这是明确的初次观察接线风险，未在 SwiftUI 运行时执行，不应把“重观察函数能清掉”写成
“新建页面必然自动清掉”。最小建议是在首次权威 load 后或 recorder 初始出现时调用现有观察，
无需新增用户动作/已处理标记。

导出控制器测试只将 UI-only import 换为 Foundation，并使用最小文件值替身；不声称验证
UIKit 分享、真实文件租约回收或完整 NativeChatView 生命周期。

## 实测证据

本次实际日志在独立证据目录：
`/opt/data/cache/scratch/hermes24-races-evidence/`。

- `races-red.log` / `races-final.log`：swiftc 退出 0；8 场景中 6 通过、2 RED，runner 退出 1。
- `observation.log`：初次 test fixture 缺 HermesBackend conformance 编译退出 1；
  补复用既有 conformance 后 `observation-fixed.log` 退出 0（不是生产缺陷）。
- `export-recovery.log`：退出 0。
- `baseline-full-offline.log`：45 编译套件与其后 5 脚本通过，但新增独立测试不在冻结
  release scope，sourcegate 按预期拒绝，退出 1；未修改 scope 掩盖。
- `pristine-full-offline.log`：从本地 `git archive e7ae8cb` 建到同一隔离目录的
  `.build/pristine`，原始基线全离线运行 `HERMES_OFFLINE_TESTS_PASS`，退出 0。
- `pristine-sourcegates.log`：原始基线 verify_source 及 sourcegate 7 场景，退出 0。

日志包含命令和退出码。基线验证与新增测试后的源码门禁不混报；没有执行 Release 编译、
IPA 审计、生产 API、配置或服务变更。通过的新增场景是现有行为 characterization；
缺陷回归按 TDD 先建立并实跑 RED，在只读授权下故意保持 RED，不虚构修复后的 GREEN。
