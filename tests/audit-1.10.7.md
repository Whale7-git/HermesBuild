# build35 客户端全工程静态检查与已执行优化

本文件记录代码审查，不等同于真机验收或不存在缺陷的保证。覆盖当前59个客户端Swift文件的清单与静态扫描，并重点人工复核滚动/选区、异步任务/资源生命周期、网络/Cookie、附件、历史/草稿、首页刷新/搜索等调用链。Vendor改动仅限下面列出的原生文字片段接入，其余依赖不升级、不重写。最终编译和全回归结果见交付logs，避免在编译前把计划写成通过。

## 已实施

| 问题 | 改进 | 证据与边界 |
| --- | --- | --- |
| Textual反射选区在用户设备无响应 | 实际文字用UITextView绘制和选区，移除正文的弹面板长按手势 | 原生代码Release验证；手柄/手势待手机 |
| 更新可能重置正在选择的文本 | 实际publication门只保留最新值，选区结束再交付；离焦清旧range释放宿主 | 12条真实门控断言；不模拟UIKit |
| 选字时下方新段落会追到底部 | 几何提交检查实际UITextInput选区，沿用阅读锚点 | 静态调用链审查及现有几何测试；集成手感待手机 |
| 原生段落反复测高 | 相同内容/宽度复用实际测量，内容变动失效；代码自然宽度单独缓存 | 静态审查；无捏造耗时或FPS |
| 畸形会话列表被当作空列表成功 | 仅接受有效数组/sessions/data/items，其他抛解码错误 | 正式Models解码回归 |
| 搜索/归档多包一层401重试 | 去掉外层，继续用performNative已有的一次Cookie同步重试 | 静态路径由最多4次减到2次；没请求生产401 |
| Cookie桥接宽泛子串匹配 | DNS标签边界与IP精确匹配，去掉向WebKit同步全Cookie的后备路径 | 正式helper域名/IP回归；线上登录待手机 |
| 慢解码占槽时取消排队会留墓碑 | 最后消费者取消且未运行时立即移除排队记录，运行任务仍持槽到真正退出 | 实际池256次取消压力，全部329项交互断言 |
| 日志每次头删数组/临时文件无保留上限 | 固定512项循环缓冲、tag64/message2048字节、UUID文件名、最多8份/2MiB本地留底 | 实际循环缓冲和临时文件9条断言，无上传 |

## 保持与尚存边界

- 所有历史门禁清单、上游指纹保留；附件三个受保护文件字节不改。SSE的GET恢复、不确定POST不重发、历史分页/缓存范围、首页原生refreshable原路径保留，走现有离线回归。
- 原生选区是各实际文本片段自己的文档，不能跨独立段落/代码/表格单元格连续拖选；备用全文原文面板保留。含附件/数学图像的片段保持原渲染，不宣称可选图中文字。
- RuntimeLogRecorder仍按旧策略自动上传失败诊断，未改成用户手动同意，也未对已有附件名/路径字段宣称脱敏。本版只优化本地资源上限；并发flush自动上传尚未合并。
- 整页长回复仍受实际文本量影响，Native UITextView增加原生视图成本；缓存测高和原宿主预算不等于达到ChatGPT的FPS。只能在同手机/字号/会话实测比较。
- 没有iPhone/模拟器执行器。没有调用生产会话、上传日志、vision或真实附件下载；不修改WebUI/后端/反代/端口/容器配置。

## 客户端源码清单

- Sources/HermesShell/AppState.swift
- Sources/HermesShell/AppTheme.swift
- Sources/HermesShell/AttachmentHistory.swift
- Sources/HermesShell/AttachmentInteractionState.swift
- Sources/HermesShell/AttachmentModels.swift
- Sources/HermesShell/AttachmentStrip.swift
- Sources/HermesShell/AttachmentViews.swift
- Sources/HermesShell/ChatComposer.swift
- Sources/HermesShell/ChatCore.swift
- Sources/HermesShell/ChatDraftEditor.swift
- Sources/HermesShell/ChatDraftStore.swift
- Sources/HermesShell/ChatHistoryIdentity.swift
- Sources/HermesShell/ChatHistoryStore.swift
- Sources/HermesShell/ChatInputPolicy.swift
- Sources/HermesShell/ChatKeyboardTestView.swift
- Sources/HermesShell/ChatMarkdownDocument.swift
- Sources/HermesShell/ChatMarkdownParser.swift
- Sources/HermesShell/ChatMarkdownWorker.swift
- Sources/HermesShell/ChatMessageViews.swift
- Sources/HermesShell/ChatPerformanceRecorder.swift
- Sources/HermesShell/ChatPerformanceStatistics.swift
- Sources/HermesShell/ChatPerformanceView.swift
- Sources/HermesShell/ChatPreparationQueue.swift
- Sources/HermesShell/ChatRenderBudget.swift
- Sources/HermesShell/ChatRenderEnvironment.swift
- Sources/HermesShell/ChatRenderScheduler.swift
- Sources/HermesShell/ChatRequests.swift
- Sources/HermesShell/ChatScrollState.swift
- Sources/HermesShell/ChatStreamPacing.swift
- Sources/HermesShell/ChatTimeline.swift
- Sources/HermesShell/ChatTimelineProjection.swift
- Sources/HermesShell/ChatUtilities.swift
- Sources/HermesShell/ChatViewportLayout.swift
- Sources/HermesShell/ContextUsageView.swift
- Sources/HermesShell/CookieDomainPolicy.swift
- Sources/HermesShell/DesignComponents.swift
- Sources/HermesShell/HermesAPI.swift
- Sources/HermesShell/HermesShellApp.swift
- Sources/HermesShell/ImageRefKind.swift
- Sources/HermesShell/InlineImages.swift
- Sources/HermesShell/LoginSettings.swift
- Sources/HermesShell/MarkdownBlockPlan.swift
- Sources/HermesShell/MarkdownRenderCheckView.swift
- Sources/HermesShell/MessageListView.swift
- Sources/HermesShell/MessageTextSelectionSheet.swift
- Sources/HermesShell/ModelPicker.swift
- Sources/HermesShell/Models.swift
- Sources/HermesShell/NativeChatModel.swift
- Sources/HermesShell/NativeChatService.swift
- Sources/HermesShell/NativeChatView.swift
- Sources/HermesShell/RootView.swift
- Sources/HermesShell/RuntimeLogRecorder.swift
- Sources/HermesShell/RuntimeLogStorage.swift
- Sources/HermesShell/SessionDrawer.swift
- Sources/HermesShell/SessionListService.swift
- Sources/HermesShell/SessionSearch.swift
- Sources/HermesShell/SessionSearchView.swift
- Sources/HermesShell/SharedAsyncResourcePool.swift
- Sources/HermesShell/StableChatScrollView.swift
