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
    composer = contents.get("ChatComposer.swift", "")
    if ".frame(width: 44, height: 44)" not in composer:
        failures.append("Quote remove action must retain a 44pt touch target")
    if "guard !browserOpen, sidebarGesture.claimed" in root:
        failures.append("RootView: onEnded still reads resettable GestureState.claimed")
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
    )
    contents = {name: (S / name).read_text(encoding="utf-8") for name in names}
    baseline_errors = violations(contents)
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
