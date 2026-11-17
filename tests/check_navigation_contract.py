#!/usr/bin/env python3
"""Build202 navigation preservation gate.

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
        ),
        "UnifiedSessionBrowser.swift": (
            "struct UnifiedSessionBrowser: View",
            "Picker(\"浏览内容\"",
            "Button(\"当前实例会话\"",
            "TextField(\"搜索所有实例\"",
            "TextField(\"筛选任务或实例\"",
            "center.retry(source:",
            "onSelect(record)",
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
        ),
        "NativeChatView+Chrome.swift": (
            "Button(\"导出已加载内容\"",
            "Button(\"获取完整历史后导出\"",
            "Label(\"导出会话\", systemImage: \"doc.text\")",
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
    if "guard !browserOpen, sidebarGesture.claimed" in root:
        failures.append("RootView: onEnded still reads resettable GestureState.claimed")
    if "在浏览器打开" in chrome or "Link(destination: webURL)" in chrome:
        failures.append("Chrome: external browser action was reintroduced")
    if "self.webURL =" in chat or "let webURL: URL" in chat:
        failures.append("NativeChatView: stale external URL initialization returned")
    if "legacyBaseURL: api.webConsoleBaseURL.absoluteString" not in chat:
        failures.append("NativeChatView: attachment legacy base URL must survive")
    return failures


def main() -> int:
    names = (
        "RootView.swift", "SessionDrawer.swift", "UnifiedSessionBrowser.swift",
        "UnifiedSessionModel.swift", "UnifiedTaskWorkspace.swift", "AppState.swift",
        "ChatScrollState.swift", "NativeChatView+Chrome.swift", "NativeChatView.swift",
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
    )
    for description, filename, fragment in cases:
        if fragment not in contents[filename]:
            raise AssertionError(f"fixture missing for {description}")
        altered = dict(contents)
        altered[filename] = altered[filename].replace(fragment, "", 1)
        if not violations(altered):
            raise AssertionError(f"gate failed to detect removed {description}")

    print("NAVIGATION_CONTRACT_PASS build198 routes, cross-instance tasks, "
          "persistent gesture ownership, export-only chat menu")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
