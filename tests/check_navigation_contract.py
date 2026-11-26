#!/usr/bin/env python3
"""Build202-204 navigation, modal and reading ownership preservation gate.

The feature baseline is build198/build201, NOT build199's drawer-only rewrite.
This checks that executable SwiftUI wiring still exposes every legacy route,
while offline Swift tests validate the underlying navigation and search models.
Static source checks do not claim to simulate an iPhone gesture.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
S = ROOT / "Sources/HermesShell"


def violations(contents: dict[str, str]) -> list[str]:
    required = {
        "RootView.swift": (
            "@StateObject private var unifiedCenter = UnifiedSessionModel()",
            "@State private var browserRoute: [UnifiedBrowserPage] = []",
            "private var singleInstanceBrowser: some View",
            "precedingBrowserLayer(",
            "activeBrowserLayer(",
            "onBrowseAll:",
            "onBrowseAllInstances:",
            "onBrowseAllTasks:",
            "UnifiedSessionBrowser(",
            "UnifiedBrowserBackNavigation.destination(",
            "app.openSessionFromInstance(",
            "browserSessionOpen = true",
            "onClose: backFromBrowser",
            "browserRoute = app.instances.count > 1 ? [.all] : [.single]",
            "if browserRoute.last != .all { browserRoute.append(.all) }",
            "UnifiedBrowserPresentation.shouldRetireBrowserForNewDraft(",
            "@State private var drawerGestureOwner = RootDrawerGestureOwnership()",
            "drawerGestureOwner.changed(",
            "drawerGestureOwner.ended(",
            "drawerGestureOwner.cancelled()",
            "@GestureState private var sessionBackDrag = RootPageGestureState()",
            "@GestureState private var browserBackDrag = RootPageGestureState()",
            "@State private var sessionBackOwner = RootPageGestureOwnership()",
            "@State private var browserBackOwner = RootPageGestureOwnership()",
            "sessionBackOwner.changed(",
            "sessionBackOwner.ended(",
            "browserBackOwner.changed(",
            "browserBackOwner.ended(",
            "@State private var taskCenterPresented = false",
            ".sheet(isPresented: $taskCenterPresented",
            "onShowTaskCenter: presentTaskCenter",
            "onOpenCurrentTaskCenter: presentTaskCenter",
            "navigationGesturesAllowed",
            "taskCenterScope == homeScope",
            "pendingTaskSheetSelection = (",
            "RootTaskSheetNavigation.canOpen(",
            "settlePageReturn(.chat",
            "settlePageReturn(.browser",
            "pageReturnTicket == ticket",
            "modalOpen: app.showSettings || app.needsLogin || taskCenterPresented",
            "SessionTaskCenterView(",
        ),
        "SessionDrawer.swift": (
            "enum Mode { case page, drawer }",
            "if mode == .drawer && app.instances.count > 1",
            "mode: Mode",
            "var onBrowseAll: (() -> Void)?",
            "var onBrowseAllInstances: (() -> Void)?",
            "var onBrowseAllTasks: (() -> Void)?",
            "mode == .page",
            "SessionSearchView(",
            "SessionTaskCenterView(",
            "var onShowTaskCenter: (() -> Void)?",
            "if let onShowTaskCenter { onShowTaskCenter() }",
            "Button(action: presentTaskCenter)",
            "compactBrowseAction(\"全部会话\"",
            "compactBrowseAction(\"全部任务\"",
            "searchField.disabled(selecting)",
            "pendingLocalTaskSelection",
        ),
        "UnifiedSessionBrowser.swift": (
            "struct UnifiedSessionBrowser: View",
            "Picker(\"浏览内容\"",
            "Button(\"当前实例会话\"",
            "TextField(\"搜索所有实例\"",
            "TextField(\"筛选任务或实例\"",
            "center.retry(source:",
            "onSelect(record)",
            "Button(action: onOpenCurrentTaskCenter)",
            "activeAttention > 0",
        ),
        "UnifiedSessionModel.swift": (
            "struct UnifiedSessionIdentity: Hashable",
            "final class UnifiedSessionModel: ObservableObject",
            "func refreshIfNeeded(",
            "func retry(source:",
            "private static func loadOutcome(",
        ),
        "UnifiedTaskWorkspace.swift": (
            "struct UnifiedTaskEntry: Identifiable",
            "enum UnifiedTaskWorkspace",
            "static func entries(",
        ),
        "AppState.swift": (
            "func openSessionFromInstance(",
            "func unifiedCachedSessions(",
            "func unifiedTaskObservations(",
        ),
        "ChatScrollState.swift": (
            "struct RootDrawerGestureOwnership: Equatable",
            "struct RootPageGestureState",
            "struct RootPageGestureOwnership: Equatable",
            "mutating func ended(open: Bool, width: Double,",
            "enum UnifiedBrowserBackNavigation",
            "enum ChatPageBackInteraction",
            "struct ChatDrawerGestureState",
            "enum RootNavigationModalPolicy",
            "enum RootTaskSheetNavigation",
            "static func geometryReportedDistance(",
            "static func isUserScroll(",
        ),
        "StableChatScrollView+Coordinator.swift": (
            "ChatScrollState.geometryReportedDistance(",
            "ChatScrollState.isUserScroll(",
        ),
        "NativeChatView+Chrome.swift": (
            "Button(\"导出已加载内容\"",
            "Button(\"获取完整历史后导出\"",
            "Label(\"导出会话\", systemImage: \"doc.text\")",
            "showPanel(.task)",
            "查看任务与消息队列",
        ),
        "SessionTaskCenterView.swift": (
            ".onTapGesture { onSelect(session) }",
        ),
        "ChatNavigation.swift": (
            "if filtered.isEmpty {",
            "Section(\"关键节点 · \\(filtered.count)\")",
            "加载更早问题",
            "ContentUnavailableView(",
        ),
        "ChatQueueManager.swift": (
            "if model.queuedTurns.isEmpty {",
            "if model.queuedTurns.first?.delivery == .uncertain {",
            "自动续发",
            ".confirmationDialog(",
            "queueEditor(turn, index: index)",
            "model.beginQueuedTurnEdit(",
            "model.commitQueuedTurnEdit(",
            "model.cancelQueuedTurnEdit(",
        ),
        "NativeChatView+Panels.swift": (
            "dismissPanel(then: .locateMessage(id))",
            "dismissPanel(then: .latestMessage)",
            "ChatQueueManager(model: model, onRecovery:",
        ),
        "NativeChatModel+Send.swift": (
            "editing: queueEditingTurnID != nil",
            "func beginQueuedTurnEdit(",
            "func commitQueuedTurnEdit(",
        ),
        "NativeChatView+MessageList.swift": (
            "private var jumpBar: some View",
            "Button { showMessageNavigation = true }",
            "Text(\"新回复\")",
            "goToLatest(animated: true)",
        ),
    }
    failures = [
        f"{name}: missing live contract {token!r}"
        for name, markers in required.items()
        for token in markers if token not in contents.get(name, "")
    ]
    root = contents.get("RootView.swift", "")
    chrome = contents.get("NativeChatView+Chrome.swift", "")
    chat = contents.get("NativeChatView.swift", "")
    unified = contents.get("UnifiedSessionBrowser.swift", "")
    if "@Binding var taskSearch: String" not in unified or (
            "taskSearch: $unifiedTaskQuery" not in root):
        failures.append("Browser task query must be owned by the root navigation state")
    geometry = contents.get("StableChatScrollView+Geometry.swift", "")
    if "itemByID[id] == nil" not in geometry or "turnReading.reset()" not in geometry:
        failures.append("Focused turn must retire when its transcript ID disappears")
    if "guard let rowTop else { return nil }" not in contents.get("ChatScrollState.swift", ""):
        failures.append("Temporary missing row geometry must preserve focus")
    composer = contents.get("ChatComposer.swift", "")
    if ".accessibilityHint(hint)" not in composer or (
            "ChatComposerFeedbackPolicy.sendHint(" not in composer):
        failures.append("Composer disabled actions must provide a state reason")
    browser = contents.get("UnifiedSessionBrowser.swift", "")
    refreshList = contents.get("SessionSearchView.swift", "")
    model = contents.get("UnifiedSessionModel.swift", "")
    for token in ("sessionScrollAnchor: $unifiedSessionScrollAnchor",
                  "taskScrollAnchor: $unifiedTaskScrollAnchor",
                  ".onChange(of: unifiedBrowseIdentity)", "unifiedSessionScrollIndex = 0",
                  "unifiedTaskScrollIndex = 0"):
        if token not in root:
            failures.append(f"Cross-instance browsing: missing root bookmark contract {token}")
    for token in ("SessionRefreshList(scrollID: $visibleScrollID",
                  "UnifiedBrowserScrollPolicy.reconcile(",
                  ".id(record.id)", ".id(entry.id)",
                  ".onChange(of: taskSearch)", ".onChange(of: filter)"):
        if token not in browser:
            failures.append(f"Cross-instance browsing: missing stable scroll contract {token}")
    if ".scrollTargetLayout()" not in refreshList or (
            ".scrollPosition(id: scrollID" not in refreshList):
        failures.append("Cross-instance browser must use target-aware row scroll restoration")
    if "enum UnifiedBrowserScrollPolicy" not in model:
        failures.append("Missing scoped bookmark fallback policy")
    for token in ("failedSources: failedScrollSources",
                  "UnifiedBrowserScrollPolicy.shouldCapture(",
                  "waitingForBookmarkHost", "visibleScrollID != next"):
        if token not in browser:
            failures.append(f"Browser scroll ownership: missing {token}")
    if "userOwnsScroll, id: id" not in browser:
        failures.append("Browser must gate bookmark writes on user-initiated scroll")
    for token in ("handleScrollEvent(_ event: UnifiedBrowserScrollEvent)",
                  "scrollOwnership.receive(event)", "scrollOwnership.datasetChanged()",
                  "rememberScrollBookmark(visibleScrollID)",
                  "retainedSourceIDs: retainedTaskSourceIDs",
                  "waitingForTaskEvidence"):
        if token not in browser:
            failures.append(f"Browser scroll lifecycle: missing {token}")
    if ".onScrollPhaseChange" not in refreshList or (
            "case .interacting:" not in refreshList or
            "case .decelerating:" not in refreshList or
            "case .idle:" not in refreshList):
        failures.append("Cross-instance scroll must report drag, momentum and idle")
    if "struct UnifiedBrowserScrollOwnership" not in model or (
            "deferredReconcile" not in model):
        failures.append("Browser scroll ownership model must defer refresh until idle")
    if "onFailedSource(_ anchor" not in model:
        failures.append("Missing per-identity partial-failure bookmark protection")
    composer = contents.get("ChatComposer.swift", "")
    if ".frame(width: 44, height: 44)" not in composer:
        failures.append("Quote remove action must retain a 44pt touch target")
    if ".fixedSize(horizontal: true, vertical: false)" in composer:
        failures.append("Composer model button must shrink before 44pt send/stop controls")
    for token in ("dynamicTypeSize.isAccessibilitySize ? 5 : 12",
                  ".layoutPriority(-1)", ".minimumScaleFactor(0.85)",
                  "quoteExpanded.toggle()", "收起引用内容", "展开引用内容"):
        if token not in composer:
            failures.append(f"Composer narrow/large text accessibility contract missing: {token}")
    toolViews = contents.get("ChatMessageViews.swift", "")
    toolLogic = contents.get("ChatToolSummary.swift", "")
    for token in ("ChatToolSummary.statusLine(items, allowsRunning: allowsRunning)",
                  "dynamicTypeSize.isAccessibilitySize",
                  ".accessibilityHint(detail)", "复制本轮已加载的回复",
                  "引用回复", "本条回复的更多操作",
                  "Button(\"专注阅读\"", "Button(\"选择本条原文\"",
                  "Button(\"复制本条为 Markdown\"", "Button(\"分享本轮已加载回复\""):
        if token not in toolViews:
            failures.append(f"Chat actions/tool status visibility: missing {token}")
    if "static func statusLine(" not in toolLogic:
        failures.append("Tool summaries must retain verified success/failure/unknown counts")
    for token in ("func navigate(to id:", "func restoreReadingPosition(",
                  "private var jumpBar: some View",
                  "goToLatest(animated: true)"):
        if token not in contents.get("NativeChatView+MessageList.swift", ""):
            failures.append(f"Search/reading return path: missing {token}")
    # build213: search must be user-navigated, scoped, and capped accurately.
    search = contents.get("ChatConversationSearch.swift", "")
    findbar = contents.get("ChatFindBar.swift", "")
    chrome = contents.get("NativeChatView+Chrome.swift", "")
    chat = contents.get("NativeChatView.swift", "")
    reading = contents.get("NativeChatView+MessageList.swift", "")
    coordinator = contents.get("StableChatScrollView+Coordinator.swift", "")
    for token in ("findDetailed(", "hasMoreMatches: true", "queryTooLong: true"):
        if token not in search:
            failures.append(f"Search result correctness missing: {token}")
    for token in ("loadOlderForFind()", "captureCurrentReadingPosition()",
                  "returnToFindOrigin()", "beginFind()",
                  "guard !finding, !findQueryTooLong, !findHits.isEmpty"):
        if token not in chrome:
            failures.append(f"Search navigation owner missing: {token}")
    for token in ("findHasMoreMatches", "findQueryTooLong", "findOrigin"):
        if token not in chat:
            failures.append(f"Search local state missing: {token}")
    if "scheduleFind(.queryChanged, jump: false)" not in chat:
        failures.append("Typing search terms must not automatically move the viewport")
    if "controllerBox.value?.cancelFindNavigation()" not in reading:
        failures.append("User scroll must cancel pending search navigation")
    if "func loadOlderForFind()" not in reading:
        failures.append("Manual search paging must reuse the existing history owner")
    if "func captureCurrentReadingPosition()" not in coordinator:
        failures.append("Search origin must be captured from actual UIKit geometry")
    for token in ("hasMoreMatches", "queryTooLong", "onLoadOlder", "onReturnToOrigin",
                  "olderLimitReached", "canReturnToOrigin"):
        if token not in findbar:
            failures.append(f"Search toolbar missing explicit state/action: {token}")
    # build214: reader chapter navigation must use rendered Markdown headings,
    # bounded highlighter ordinals, and explicit reader-owned scroll commands.
    reader = contents.get("ChatMessageReader.swift", "")
    outline = contents.get("ChatReaderOutline.swift", "")
    for token in ("presentationIntent", "utf16Ranges(of: title",
                  "activeOffset", "sections(in markdown:"):
        if token not in outline:
            failures.append(f"Reader outline must use visible Markdown text: {token}")
    for token in ("showOutline", "chapterJump", "ReaderScrollView(",
                  "ChatReaderOutline.sections(in: source)", "onChapterNavigationDone",
                  "hasMoreSearchMatches", "searchQueryTooLong",
                  "ChatFindHighlight.characterRanges(of: query, in: plain, limit: 301)",
                  "matchCount == 0 || searching || searchQueryTooLong"):
        if token not in reader:
            failures.append(f"Reader interaction regression: {token}")
    # UI test infrastructure: only prove current executable connections.
    # Do NOT require allowsHitTesting(false) on interactive media overlays:
    # the "+N" overlay is intentionally the only hit-testing owner, while its
    # underlying tile has allowsHitTesting(!covered).
    attachmentStrip = contents.get("AttachmentStrip.swift", "")
    composerSource = contents.get("ChatComposer.swift", "")
    replySource = contents.get("ChatMessageViews.swift", "")
    for token in ("let covered = index == 3",
                  ".allowsHitTesting(!covered)", "Button { start(item, .image) }"):
        if token not in attachmentStrip:
            failures.append(f"Attachment overlay touch owner missing: {token}")
    for token in ("AppTheme.minimumTouchSize", "ChatComposerActionPolicy.reservesSendSlot(",
                  "actionButton(symbol: \"arrow.up\"", "actionButton(symbol: \"stop.fill\""):
        if token not in composerSource:
            failures.append(f"Send/Stop shared control geometry missing: {token}")
    if "ChatReadingShortcutPolicy.showInline(" not in replySource:
        failures.append("Reader shortcut policy exists but is not wired into the reply toolbar")
    # build216: composer action geometry stays stable as the first character
    # arrives during generation; no new request/queue semantics are introduced.
    composerPolicy = contents.get("ChatInputPolicy.swift", "")
    shortcutPolicy = contents.get("ChatReadingShortcutPolicy.swift", "")
    messageList = contents.get("NativeChatView+MessageList.swift", "")
    for token in ("reservesSendSlot(", "running && !showsSend("):
        if token not in composerPolicy:
            failures.append(f"Running Send/Stop geometry policy missing: {token}")
    for token in ("ChatComposerActionPolicy.reservesSendSlot(",
                  ".accessibilityHidden(true)", ".allowsHitTesting(false)",
                  "if running { sendModePicker }",
                  ".lineLimit(quoteExpanded ? 8 : 2)",
                  "AppTheme.radiusComposer"):
        if token not in composer:
            failures.append(f"Chat composer polish/IME stability missing: {token}")
    # build219: mode switching must not insert a second composer row.
    # A source-level contract protects the fixed action rail; the simulator
    # verifies the measured editor and first-responder behaviour.
    if "if !readOnly && running {" in composer:
        failures.append("Running-mode selector cannot add a variable-height composer row")
    if composer.count("if running { sendModePicker }") != 1:
        failures.append("Running-mode selector must occupy exactly one existing action slot")
    if "onMetricsChange: receiveMetrics" in composer:
        failures.append("Unused UIKit line metrics must not invalidate the composer state")
    for token in ("minimumUTF16Length = 1000", "!isStreaming && showsCopy"):
        if token not in shortcutPolicy:
            failures.append(f"Inline reading shortcut must stay bounded: {token}")
    for token in ("ChatReadingShortcutPolicy.showInline(",
                  ".accessibilityLabel(\"专注阅读这条长回复\")",
                  "Button(\"专注阅读\"", "Button(action: onCopyReply)",
                  "Button(action: onQuote)"):
        if token not in toolViews:
            failures.append(f"Long-answer toolbar lost an action: {token}")
    for token in ("scroll.hasUnreadContent ? AppTheme.selectionFill : AppTheme.surface",
                  ".accessibilityValue(scroll.hasUnreadContent",
                  ".animation(reduceMotion ? nil : .easeOut(duration: 0.16)",
                  ".frame(height: 48, alignment: .bottom)"):
        if token not in messageList:
            failures.append(f"Unread action must stay outside transcript geometry: {token}")
    # build215: history image preview must use the same scoped authorization
    # as its original-byte save/share route, never silently fall back to cookies.
    strip = contents.get("AttachmentStrip.swift", "")
    overview = contents.get("AttachmentOverview.swift", "")
    catalog = contents.get("AttachmentCatalog.swift", "")
    progress = contents.get("AttachmentProgressPresentation.swift", "")
    imageActions = contents.get("ImagePreviewActions.swift", "")
    attachmentViews = contents.get("AttachmentViews.swift", "")
    for token in ("accountScope: accountScope, authorization: authorization",
                  "guard isActive, !awaitingConsent else",
                  "approvedExternalSource != sourceIdentity",
                  "AttachmentPresentationGate.shared.reserve",
                  "AttachmentMediaGrid: View", "LazyVGrid(columns: columns",
                  "AttachmentLifetimeKeeper(lifetime: route.lifetime)"):
        if token not in strip:
            failures.append(f"Media authentication/lifetime/consent regression: {token}")
    for token in ("AttachmentMediaIndex.candidates(catalog)",
                  "AttachmentMediaGrid(", "matchingFiles",
                  "shownImages = 24", "onLocate(id)", "await model.loadOlder()"):
        if token not in overview:
            failures.append(f"Attachment overview navigation or budget regression: {token}")
    if "var id: String { \"\\(rowID.utf8.count):\\(rowID)\\(path)\" }" not in catalog:
        failures.append("Media gallery must not conflate duplicate paths across messages")
    for token in ("static func downloadText(", "Int(min(100.0, max(0.0, ratio)))"):
        if token not in progress:
            failures.append(f"Attachment progress bounds regression: {token}")
    if "saved ? savedLabel : \"保存原图\"" not in imageActions:
        failures.append("Image save result cannot hide preview-only fallback")
    if "saveNotice = savedOriginal ? \"原图已保存到相册\" : \"已保存预览图到相册\"" not in attachmentViews:
        failures.append("Composer photo preview must disclose downsampled save")
    # build212: every foreground collection must refresh under a scoped,
    # throttled owner, not solely through drawer manual-refresh buttons.
    for token in ("foregroundListPolicy.shouldRefresh(", "await app.refresh()",
                  "guard scope == homeScope, scenePhase == .active"):
        if token not in root:
            failures.append(f"Foreground home refresh lifecycle missing: {token}")
    if "struct ForegroundListRefreshPolicy" not in contents.get("AppState.swift", ""):
        failures.append("Missing instance/account scoped foreground refresh policy")
    if ".onChange(of: scenePhase)" not in contents.get("SessionDrawer.swift", "") or (
            "foregroundDiscoveryPolicy.shouldRefresh(" not in contents.get("SessionDrawer.swift", "")):
        failures.append("Search/archive pane must refresh on foreground resume")
    if "maxAge: ForegroundListRefreshPolicy.freshnessWindow" not in browser:
        failures.append("Unified browser must refresh stale host snapshots after resume")
    cacheNotice = contents.get("NativeChatView+Notices.swift", "")
    cacheComposer = contents.get("NativeChatView+Composer.swift", "")
    composerView = contents.get("ChatComposer.swift", "")
    if "model.error != nil || model.cachedHistoryDate != nil" in cacheNotice:
        failures.append("Healthy cache verification must not force a warning banner")
    if "quietReadOnlyNotice: model.cachedHistoryDate != nil && model.syncing" not in cacheComposer:
        failures.append("Healthy cache verification should not force composer warning line")
    if "if readOnly && !quietReadOnlyNotice" not in composerView:
        failures.append("Only routine cached verification may silence read-only notice")
    if "guard !browserOpen, sidebarGesture.claimed" in root:
        failures.append("RootView: onEnded still reads resettable GestureState.claimed")
    # build220: a short cancelled full-card right drag must never make the
    # mounted UIKit transcript's isScrollEnabled depend on @GestureState.
    # Pushed browser-chat navigation may still temporarily suppress scrolling.
    if '(!browserOpen && sidebarGesture.claimed)' in root:
        failures.append("RootView: drawer gesture must not disable chat vertical scrolling")
    if "suppressVerticalScroll: browserSessionOpen" not in root or (
        "&& (sessionBackDrag.claimed || settlingPage == .chat)" not in root):
        failures.append("RootView: browser page return scroll gate missing")
    if "actualTranslation: Double(value.translation.width)" not in root:
        failures.append("RootView: sidebar release must supply real finger travel")
    if "在浏览器打开" in chrome or "Link(destination: webURL)" in chrome:
        failures.append("Chrome: external browser action was reintroduced")
    if "self.webURL =" in chat or "let webURL: URL" in chat:
        failures.append("NativeChatView: stale external URL initialization returned")
    if "legacyBaseURL: api.webConsoleBaseURL.absoluteString" not in chat:
        failures.append("NativeChatView: attachment legacy base URL must survive")
    if ".onTapGesture { onSelect(session) }" not in contents.get("SessionTaskCenterView.swift", ""):
        failures.append("Task center: owner must handle a single dismissal before navigation")
    if "dismiss()\n                    onSelect(session)" in contents.get("SessionTaskCenterView.swift", ""):
        failures.append("Task center: duplicate dismiss path returned")
    if ".overlay {\n                if filtered.isEmpty" in contents.get("ChatNavigation.swift", ""):
        failures.append("Navigation: full-screen empty overlay intercepts actions")
    queue = contents.get("ChatQueueManager.swift", "")
    notice = contents.get("ChatMessageViews.swift", "")
    disclosure = notice.split("private var internalNoticeBubble: some View {")[-1].split("private var userBubble: some View {")[0]
    for token in ("model.queueClearRefusal", "hasSubmittingTurn",
                  "model.queueRecoveryPaused", "onRecovery()",
                  "interactiveDismissDisabled(editingID != nil)",
                  "QueueEditorExitPolicy.needsDiscardConfirmation(",
                  ".alert(\"未保存队列修改\""):
        if token not in queue:
            failures.append(f"Queue: missing safety/feedback contract {token}")
    if ".frame(minHeight: 44)" not in disclosure:
        failures.append("Internal disclosure: needs a 44pt interactive target")
    if ".overlay {\n                if model.queuedTurns.isEmpty" in contents.get("ChatQueueManager.swift", ""):
        failures.append("Queue: full-screen empty overlay intercepts auto-dispatch controls")
    if "Button { showTaskCenter = true }" in contents.get("SessionDrawer.swift", ""):
        failures.append("Drawer: root task center is bypassed")
    if "model.removeQueuedTurn(id: turn.id)" in contents.get("NativeChatView+Panels.swift", ""):
        failures.append("Queue: edit must never remove turn or replace composer draft")
    return failures


def main() -> int:
    names = (
        "RootView.swift", "SessionDrawer.swift", "UnifiedSessionBrowser.swift",
        "UnifiedSessionModel.swift", "UnifiedTaskWorkspace.swift", "AppState.swift",
        "ChatScrollState.swift", "NativeChatView+Chrome.swift", "NativeChatView.swift",
        "StableChatScrollView+Coordinator.swift",
        "SessionTaskCenterView.swift", "ChatNavigation.swift", "ChatQueueManager.swift",
        "NativeChatView+MessageList.swift",
        "NativeChatView+Panels.swift", "NativeChatModel+Send.swift",
        "ChatMessageViews.swift", "StableChatScrollView+Geometry.swift",
        "ChatComposer.swift", "SessionSearchView.swift",
        "ChatToolSummary.swift", "ChatConversationSearch.swift", "ChatFindBar.swift",
        "ChatMessageReader.swift", "ChatReaderOutline.swift",
        "ChatReadingShortcutPolicy.swift", "ChatInputPolicy.swift",
        "AttachmentStrip.swift", "AttachmentOverview.swift", "AttachmentCatalog.swift",
        "AttachmentProgressPresentation.swift", "ImagePreviewActions.swift", "AttachmentViews.swift",
        "NativeChatView+Composer.swift",
        "NativeChatView+Notices.swift",
    )
    contents = {name: (S / name).read_text(encoding="utf-8") for name in names}
    # Recovery copy is a product contract, not a release permission.
    # Restrict to presentation/model notice files; logs and comments retain
    # their exact technical vocabulary for diagnosis. This is an advisory
    # source diagnostic in the existing workflow.
    recovery_files = (
        "ChatActivity.swift", "NativeChatModel.swift",
        "NativeChatModel+Send.swift", "NativeChatModel+Control.swift",
        "NativeChatModel+Stream.swift", "NativeChatView+Composer.swift",
        "NativeChatView+Notices.swift", "NativeChatView+Chrome.swift",
        "NativeChatView+MessageList.swift", "ChatQueueManager.swift",
        "ChatRecoveryCenter.swift", "ChatWorkspacePanels.swift", "SessionTaskCenter.swift",
    )
    import re
    def recovery_copy_violations(filename: str, source: str) -> list[str]:
        errors = []
        internal = re.compile(r'"[^"\n]*(?:核对|锁定|终态|快照|分页|WebUI|HTTP \\?\d|回读)[^"\n]*"')
        for line_number, line in enumerate(source.splitlines(), 1):
            if line.lstrip().startswith("//") or "recordRuntimeLog(" in line:
                continue
            # This deliberately checks only direct string literals, not a
            # full Swift parser or a claim about all localized strings.
            if internal.search(line):
                errors.append(f"{filename}:{line_number}: user-facing recovery terminology")
        return errors

    copy_errors = [
        error for name in recovery_files
        for error in recovery_copy_violations(name, (S / name).read_text(encoding="utf-8"))
    ]
    if not recovery_copy_violations("fixture.swift", 'notice = "发送保持锁定"'):
        raise AssertionError("recovery copy check did not catch internal terminology")
    if recovery_copy_violations("fixture.swift", '// 状态待核对\nnotice = "正在同步…"'):
        raise AssertionError("recovery copy check rejected comments or normal copy")
    baseline_errors = violations(contents) + copy_errors
    if baseline_errors:
        print("NAVIGATION_CONTRACT_FAILED:")
        print("\n".join(baseline_errors))
        return 1

    # Mutations should be rejected: this tests that the gate cannot quietly
    # accept build199-style deletion of whole user-facing features.
    cases = (
        ("root global search", "RootView.swift",
         "browserRoute = app.instances.count > 1 ? [.all] : [.single]"),
        ("cross-instance list", "RootView.swift", "UnifiedSessionBrowser("),
        ("cross-instance task entry", "RootView.swift", "onBrowseAllTasks:"),
        ("cross-instance identity", "AppState.swift", "func openSessionFromInstance("),
        ("full-page session browser", "SessionDrawer.swift", "mode == .page"),
        ("stable drawer owner", "RootView.swift", "drawerGestureOwner.ended("),
        ("stable browser owner", "RootView.swift", "browserBackOwner.ended("),
        ("browser visual state", "RootView.swift",
         "@GestureState private var browserBackDrag = RootPageGestureState()"),
        ("export action", "NativeChatView+Chrome.swift",
         "Button(\"获取完整历史后导出\""),
        ("root-owned task sheet", "RootView.swift",
         ".sheet(isPresented: $taskCenterPresented"),
        ("deferred task opening", "RootView.swift",
         "RootTaskSheetNavigation.canOpen("),
        ("modal swipe gate", "RootView.swift", "navigationGesturesAllowed"),
        ("unified local task entry", "UnifiedSessionBrowser.swift",
         "Button(action: onOpenCurrentTaskCenter)"),
        ("keyboard geometry protection", "StableChatScrollView+Coordinator.swift",
         "ChatScrollState.geometryReportedDistance("),
        ("user-only scroll delegate", "StableChatScrollView+Coordinator.swift",
         "ChatScrollState.isUserScroll("),
        ("single-owner task dismissal", "SessionTaskCenterView.swift",
         ".onTapGesture { onSelect(session) }"),
        ("navigation scoped empty state", "ChatNavigation.swift",
         "if filtered.isEmpty {"),
        ("queue local empty row", "ChatQueueManager.swift",
         "if model.queuedTurns.isEmpty {"),
        ("status action", "NativeChatView+Chrome.swift",
         "showPanel(.task)"),
        ("stable running stop slot", "ChatComposer.swift",
         "ChatComposerActionPolicy.reservesSendSlot("),
        ("direct long reader", "ChatMessageViews.swift",
         "ChatReadingShortcutPolicy.showInline("),
        ("unread geometry isolation", "NativeChatView+MessageList.swift",
         ".frame(height: 48, alignment: .bottom)"),
        ("reading navigation action", "NativeChatView+MessageList.swift",
         "Button { showMessageNavigation = true }"),
        ("unread reading badge", "NativeChatView+MessageList.swift",
         "Text(\"新回复\")"),
        ("settled browser return", "RootView.swift", "settlePageReturn(.browser"),
        ("root-owned quick task action", "SessionDrawer.swift",
         "Button(action: presentTaskCenter)"),
        ("compact global browse action", "SessionDrawer.swift",
         "compactBrowseAction(\"全部会话\""),
        ("deferred message location", "NativeChatView+Panels.swift",
         "dismissPanel(then: .locateMessage(id))"),
        ("preview auth forwarding", "AttachmentStrip.swift",
         "accountScope: accountScope, authorization: authorization"),
        ("gallery external consent", "AttachmentStrip.swift",
         "guard isActive, !awaitingConsent else"),
        ("overview lazy media", "AttachmentOverview.swift",
         "AttachmentMediaGrid("),
        ("queue editing lease", "NativeChatModel+Send.swift",
         "editing: queueEditingTurnID != nil"),
        ("in-place queue editor", "ChatQueueManager.swift",
         "model.commitQueuedTurnEdit("),
    )
    for description, filename, fragment in cases:
        if fragment not in contents[filename]:
            raise AssertionError(f"fixture missing for {description}")
        altered = dict(contents)
        # Remove every matching binding: some routes have multiple valid entry points.
        altered[filename] = altered[filename].replace(fragment, "")
        if not violations(altered):
            raise AssertionError(f"gate failed to detect removed {description}")

    print("NAVIGATION_CONTRACT_PASS build198 routes, cross-instance tasks, "
          "persistent gesture ownership, build204 reading/status controls")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
