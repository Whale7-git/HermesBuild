---
name: ios-design-audit
description: Audit HermesBuild SwiftUI visual consistency, semantic theme tokens, shared controls, navigation chrome, adaptive layout and accessibility.
---

# Hermes iOS design-system consistency

## Inspect in this order

1. `Sources/HermesShell/AppTheme.swift`: semantic light/dark/high-contrast colors, spacing and corner radius tokens.
2. `DesignComponents.swift`, `HermesChrome.swift`, `HermesEmptyState.swift`, `ExperiencePresentation.swift`: reusable button, row, notice, avatar and empty-state patterns.
3. Page owners: `RootView.swift`, `NativeChatView+Chrome.swift`, `ChatComposer.swift`, `SessionDrawer.swift`, `UnifiedSessionBrowser.swift`, `LoginSettings.swift`, task center and attachment views.
4. Existing coverage: `tests/check_swiftui_modifiers.py`, `tests/check_navigation_contract.py`, `tests/experience/main.swift` and relevant contract tests.

## Review matrix

For each visible screen, record: background/surface hierarchy; title and toolbar; typography including Dynamic Type; color usage in light/dark/high contrast; spacing and radius; accessible label/value/trait; tap target; loading/empty/error/retry; modal and keyboard safe areas; motion reduction; iPhone/iPad portrait/landscape behaviors if evidence exists.

Flag duplicated *meaningful* components or inconsistent semantic treatments (same action presented differently), not a literal number merely because it is not an AppTheme token. A fixed 44pt navigation hit area and content-specific image sizes can be intentional. Check the actual surrounding code before proposing an abstraction.

## Output and fixes

Create a before/after component map with exact paths and references. Mark screenshot-dependent judgments as "needs rendering evidence". Prefer a minimal shared component/token change over large-scale view rewrites. Do not replace the existing navigation or third-party rendering library merely for styling. Require accessibility and both appearances in acceptance criteria; do not claim contrast or Dynamic Type compliance from reading source alone.
