#!/usr/bin/env python3
"""Verify the actual SwiftUI root's native chat/drawer navigation wiring.

This is an integration *source contract*, not a simulated iOS touch event.
Event-order behavior is tested in tests/scroll/main.swift with the same
RootNavigationInteraction callbacks that RootView actually calls.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def violations(root: str, drawer: str, interaction: str, browser_files: set[str]) -> list[str]:
    failures: list[str] = []
    required = {
        "single native route": "@State private var navigation = RootNavigationState()",
        "persistent gesture event host": "@State private var navigationInteraction = RootNavigationInteraction()",
        "transient visual offset": "@GestureState private var sidebarGesture = RootNavigationGesture()",
        "one onChanged event owner": "navigationInteraction.changed(",
        "one onEnded decision owner": "navigationInteraction.ended(",
        "one visual gesture updater": ".updating($sidebarGesture)",
        "one chat card container": "ChatCardContainer(",
        "drawer always mounted": "SessionListPane(",
        "host-side vertical scroll suppression": "navigationInteraction.claimed || sidebarGesture.claimed",
        "native sidebar accessibility": 'accessibilityIdentifier("native-session-sidebar")',
        "native chat accessibility": 'accessibilityIdentifier("native-chat-page")',
        "gesture host accessibility": 'accessibilityIdentifier("native-chat-sidebar-host")',
        "cross-instance modal": ".fullScreenCover(isPresented: $showUnifiedSessions)",
        "cross-instance view": "UnifiedSessionBrowser(",
        "cross-instance sessions action": "onBrowseAllInstances:",
        "cross-instance tasks action": "onBrowseAllTasks:",
    }
    for name, needle in required.items():
        if root.count(needle) != 1:
            failures.append(f"{name}: expected one RootView binding, saw {root.count(needle)}")
    for name, count in [("DragGesture(", 1), (".simultaneousGesture(", 1)]:
        if root.count(name) != count:
            failures.append(f"duplicate/absent root gesture {name}: {root.count(name)}")
    for forbidden in (
        "browserRoute", "browserSessionOpen", "browserBackDrag",
        "ChatPageBackInteraction", "precedingBrowserLayer", "activeBrowserLayer",
        "navigationSwipeClaimed", "UnifiedBrowserBackNavigation",
    ):
        if forbidden in root:
            failures.append(f"legacy competing navigation in RootView: {forbidden}")
    for forbidden in ("enum Mode", "mode == .page", "onBrowseAll:",
                      "backToDrawer"):
        if forbidden in drawer:
            failures.append(f"browser-only drawer path persisted: {forbidden}")
    for forbidden in ("UnifiedBrowserPresentation", "UnifiedBrowserBackNavigation",
                      "UnifiedBrowserPage", "UnifiedBrowserSource", "ChatPageBackInteraction"):
        if forbidden in interaction:
            failures.append(f"second root navigation in gesture policy: {forbidden}")
    for path in ("UnifiedSessionBrowser.swift", "UnifiedSessionModel.swift",
                 "UnifiedTaskWorkspace.swift"):
        if path not in browser_files:
            failures.append(f"cross-instance management source missing: {path}")
    if "var onBrowseAllInstances:" not in drawer or "var onBrowseAllTasks:" not in drawer:
        failures.append("cross-instance drawer entry callbacks missing")
    for positive in ("struct RootNavigationInteraction", "func changed(", "func ended(",
                     "func cancelled()", "struct RootNavigationState"):
        if positive not in interaction:
            failures.append(f"actual gesture/nav transition unavailable: {positive}")
    if ".sheet(isPresented: $showTaskCenter)" not in drawer:
        failures.append("native task center sheet disappeared")
    if "SessionSearchView(" not in drawer:
        failures.append("native session search disappeared")
    if "instanceStrip" not in drawer:
        failures.append("native instance switching rail disappeared")
    return failures


def validate() -> list[str]:
    folder = ROOT / "Sources/HermesShell"
    names = ("UnifiedSessionBrowser.swift", "UnifiedSessionModel.swift",
             "UnifiedTaskWorkspace.swift")
    present = {p for p in names if (folder / p).exists()}
    failures = violations(
        (folder / "RootView.swift").read_text(),
        (folder / "SessionDrawer.swift").read_text(),
        (folder / "ChatScrollState.swift").read_text(),
        present,
    )
    chrome = (folder / "NativeChatView+Chrome.swift").read_text()
    if 'Label("在浏览器打开"' in chrome or "Link(destination: webURL)" in chrome:
        failures.append("external browser action must not remain in chat menu")
    return failures


def self_test() -> None:
    """Guard against a source contract that would always pass."""
    root = (ROOT / "Sources/HermesShell/RootView.swift").read_text()
    drawer = (ROOT / "Sources/HermesShell/SessionDrawer.swift").read_text()
    policy = (ROOT / "Sources/HermesShell/ChatScrollState.swift").read_text()
    required_files = {"UnifiedSessionBrowser.swift", "UnifiedSessionModel.swift",
                      "UnifiedTaskWorkspace.swift"}
    tamper = (
        (root + "\n.simultaneousGesture(DragGesture())", drawer, policy, required_files),
        (root.replace("navigationInteraction.ended(", "navigation.finishSwipe("),
         drawer, policy, required_files),
        (root, drawer.replace("var onBrowseAllInstances:", "var removedEntry:"),
         policy, required_files),
        (root, drawer, policy, set()),
    )
    for index, case in enumerate(tamper):
        if not violations(*case):
            raise AssertionError(f"navigation structural regression {index} went undetected")


if __name__ == "__main__":
    issues = validate()
    if issues:
        raise SystemExit("NAVIGATION_CONTRACT_FAILED: " + "; ".join(issues))
    self_test()
    print("NAVIGATION_CONTRACT_PASS native chat/drawer, isolated cross-instance modal, one gesture owner")
