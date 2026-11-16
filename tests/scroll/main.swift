import Foundation
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message:String) {
    checks += 1
    if !condition() { print("FAIL: \(message)"); exit(1) }
}

// 列表已交给 ScrollView + LazyVStack：加载历史用「锚点 → 锚定回」保位，
// 追加时按跟随意图决定滚不滚。
// 所以这里只锁一件事——什么时候算"跟着底部"，并且必须带迟滞、不抖。

var ownership = ChatPaginationOwnership()
let pageA = ownership.begin()
expect(ownership.owns(pageA), "initial older-page task owns its completion")
ownership.retire()
expect(!ownership.owns(pageA), "page finishing after view disappearance is rejected")
let pageB = ownership.begin()
expect(ownership.owns(pageB) && !ownership.owns(pageA),
       "late old page must not clear successor's spinner or pagination timing")
ownership.retire()
expect(!ownership.owns(pageB), "account switch invalidates pending pagination completion")

var state = ChatScrollState()
expect(state.following, "starts following the tail")

// 1) 短距离离底不算脱离：手指轻碰不该停掉自动跟随
state.update(distanceFromBottom: 60)
expect(state.following, "60pt from bottom stays inside the hysteresis band")

// 2) 超过脱离阈值才真正停
state.update(distanceFromBottom: 120)
expect(!state.following, "beyond 80pt the user has left the tail")

// 3) 停在历史里时新内容只点亮提示
state.receivedAssistantUpdate()
expect(state.hasUnreadContent, "streaming while detached marks new content")

// 4) 回到 60pt 仍在迟滞区：不翻转，也不清提示
state.update(distanceFromBottom: 60)
expect(!state.following && state.hasUnreadContent, "the band does not re-attach or clear unread")

// 5) 回到 40pt 以内才恢复跟随并清提示
state.update(distanceFromBottom: 30)
expect(state.following && !state.hasUnreadContent, "entering 40pt re-attaches and clears unread")

// 6) 跟随中吐字不该点亮提示
state.receivedAssistantUpdate()
expect(!state.hasUnreadContent, "visible updates are already read")

// 7) 主动回到底部：无条件恢复
state.update(distanceFromBottom: 900)
expect(!state.following, "far away detaches")
state.receivedAssistantUpdate()
expect(state.hasUnreadContent, "unread set again")
state.jumpToLatest()
expect(state.following && !state.hasUnreadContent, "jump always re-attaches and clears unread")

// 8) 单调性：一路滚到最底必须跟随（不能停在某个中间态）
state.update(distanceFromBottom: 200)
for step in stride(from: 200.0, through: 0.0, by: -10.0) {
    state.update(distanceFromBottom: step)
}
expect(state.following, "scrolling all the way down always ends attached")

// 9) 关键：滚动中每一帧都会回调，只有状态真的翻转才允许返回 true。
// 每帧都返回 true 会让视图每帧写 @State，列表在手指下自我重排。
var moving = ChatScrollState()
moving.update(distanceFromBottom: 400)   // 先脱离
var writes = 0
for step in stride(from: 400.0, through: 200.0, by: -1.0) {
    if moving.update(distanceFromBottom: step) { writes += 1 }
}
expect(writes == 0, "a long drag inside one state writes nothing per frame (got \(writes))")

// 10) 跨过阈值的那一帧必须只报一次
var crossing = ChatScrollState()
crossing.update(distanceFromBottom: 400)
writes = 0
for step in stride(from: 400.0, through: 0.0, by: -1.0) {
    if crossing.update(distanceFromBottom: step) { writes += 1 }
}
expect(writes == 1, "crossing the hysteresis band reports exactly one change (got \(writes))")
expect(crossing.following, "crossing lands attached")

// 11) 反复在同一区间抖动不得多次上报
var jitter = ChatScrollState()
writes = 0
for distance in [50.0, 55.0, 60.0, 70.0, 65.0, 58.0] {
    if jitter.update(distanceFromBottom: distance) { writes += 1 }
}
expect(writes == 0, "jitter inside the band never flips state")

// 12) unread 只在第一次吐字时上报
var unread = ChatScrollState()
unread.update(distanceFromBottom: 400)
expect(unread.receivedAssistantUpdate(), "first detached update reports a change")
expect(!unread.receivedAssistantUpdate(), "repeat updates do not re-write view state")


// MARK: - 自动分页闸门（S1-4）

// 13) 全部测量完成、位置与状态都允许：放行
do {
    let now = Date()
    expect(ChatPaginationGate.allowsAutoLoad(unmeasured: [:], now: now,
        canLoadOlder: true, loadingOlder: false, olderOffset: 100, requestedPage: nil),
        "no unmeasured rows lets auto-load through")
}

// 14) 还有刚出现的未测量行：暂时挡住（它可能马上就测完）
do {
    let now = Date()
    expect(!ChatPaginationGate.allowsAutoLoad(unmeasured: ["a": now], now: now,
        canLoadOlder: true, loadingOlder: false, olderOffset: 100, requestedPage: nil),
        "a freshly unmeasured row blocks auto-load while it may still resolve")
}

// 15) 未测量行已超时：放行。这是本轮修的缺陷——此前它会永久阻塞。
do {
    let now = Date()
    let stale = now.addingTimeInterval(-(ChatPaginationGate.unmeasuredGraceSeconds + 0.1))
    expect(ChatPaginationGate.allowsAutoLoad(unmeasured: ["a": stale], now: now,
        canLoadOlder: true, loadingOlder: false, olderOffset: 100, requestedPage: nil),
        "a stuck unmeasured row must not block pagination forever")
}

// 16) 一旧一新混合：新的还没到期，仍然挡住（不能因为有一个超时就全放行）
do {
    let now = Date()
    let stale = now.addingTimeInterval(-(ChatPaginationGate.unmeasuredGraceSeconds + 0.1))
    expect(!ChatPaginationGate.allowsAutoLoad(unmeasured: ["a": stale, "b": now], now: now,
        canLoadOlder: true, loadingOlder: false, olderOffset: 100, requestedPage: nil),
        "one expired row does not excuse a fresh one")
}

// 17) 上限已到：无论测量状态如何都不放行（S1-3）
do {
    let now = Date()
    expect(!ChatPaginationGate.allowsAutoLoad(unmeasured: [:], now: now,
        canLoadOlder: false, loadingOlder: false, olderOffset: 0, requestedPage: nil),
        "no older content available means no auto-load")
}

// 18) 正在加载或已请求过同一页：不重复发起
do {
    let now = Date()
    expect(!ChatPaginationGate.allowsAutoLoad(unmeasured: [:], now: now,
        canLoadOlder: true, loadingOlder: true, olderOffset: 100, requestedPage: nil),
        "an in-flight page is not requested twice")
    expect(!ChatPaginationGate.allowsAutoLoad(unmeasured: [:], now: now,
        canLoadOlder: true, loadingOlder: false, olderOffset: 100, requestedPage: 100),
        "the same offset is not requested twice")
}

// 17) Stable geometry commits must not write equivalent offsets repeatedly.
// UIKit's contentOffset setter is observable even when the assigned value is
// effectively identical; jitter amplified by SwiftUI can move the reader.
expect(!ChatOffsetCommitPolicy.shouldAssign(current: 500, target: 500, interacting: false),
       "identical offsets must not be assigned")
expect(!ChatOffsetCommitPolicy.shouldAssign(current: 500, target: 500.3, interacting: false),
       "fractional rounding jitter must be ignored")
expect(ChatOffsetCommitPolicy.shouldAssign(current: 500, target: 501, interacting: false),
       "real layout delta must still be applied")
expect(!ChatOffsetCommitPolicy.shouldAssign(current: 500, target: 650, interacting: true),
       "active scroll gesture retains offset ownership")
expect(!ChatOffsetCommitPolicy.shouldAssign(current: Double.nan, target: 650, interacting: false),
       "invalid UIKit geometry must not trigger offset writes")
expect(!ChatOffsetCommitPolicy.shouldAssign(current: 500, target: Double.infinity, interacting: false),
       "infinite layout coordinates must not be assigned")

// Invalid geometry input must not alter follow/unread state.
var invalidDistance = ChatScrollState()
expect(!invalidDistance.update(distanceFromBottom: Double.nan),
       "non-finite distance has no state transition")
expect(invalidDistance.following, "non-finite distance keeps prior follow state")


// build151: finger-driven card reveal, mid-gesture cancellation and edge safety.
expect(ChatDrawerInteraction.reveal(width: 330, open: false, translation: 110) == 110,
       "closed drawer tracks the finger through the first third")
expect(ChatDrawerInteraction.reveal(width: 330, open: true, translation: -140) == 190,
       "open drawer tracks a leftward closing gesture")
expect(ChatDrawerInteraction.reveal(width: 330, open: true, translation: -1000) == 0,
       "drawer reveal is clamped at the closed edge")
expect(ChatDrawerInteraction.reveal(width: 330, open: false, translation: 1000) == 330,
       "drawer reveal is clamped at the open edge")
expect(!ChatDrawerInteraction.shouldTrack(startX: 80, translationX: 100, translationY: 3,
                                         open: false, width: 330),
       "non-edge drags cannot steal chat selection")
expect(ChatDrawerInteraction.shouldTrack(startX: 170, translationX: 110,
                                        translationY: 8, open: false, width: 330,
                                        allowFullCard: true),
       "full-card swipe from center of a normal chat opens the drawer")
expect(ChatDrawerInteraction.shouldTrack(startX: 318, translationX: 110,
                                        translationY: 8, open: false, width: 330,
                                        allowFullCard: true),
       "full-card swipe near far edge opens the drawer")
expect(!ChatDrawerInteraction.shouldTrack(startX: 170, translationX: -110,
                                         translationY: 8, open: false, width: 330,
                                         allowFullCard: true),
       "leftward drag on a closed chat never triggers drawer")
expect(!ChatDrawerInteraction.shouldTrack(startX: 170, translationX: 20,
                                         translationY: 100, open: false, width: 330,
                                         allowFullCard: true),
       "vertical reading and scrolling keep gesture ownership")
expect(!ChatDrawerInteraction.shouldTrack(startX: 170, translationX: -110,
                                         translationY: 8, open: true, width: 330,
                                         allowFullCard: true),
       "drawer instance rail cannot be hijacked by closing swipe from center")
expect(ChatDrawerInteraction.shouldTrack(startX: 345, translationX: 110,
                                        translationY: 8, open: false, width: 330,
                                        allowFullCard: true),
       "rightmost chat strip is swipeable even when drawer is narrower than screen")
expect(!ChatDrawerInteraction.shouldTrack(startX: -1, translationX: 110,
                                         translationY: 8, open: false, width: 330,
                                         allowFullCard: true),
       "negative local coordinate is rejected")
expect(!ChatDrawerInteraction.shouldTrack(startX: 8, translationX: 20, translationY: 100,
                                         open: false, width: 330),
       "vertical scroll stays owned by the transcript")
expect(ChatDrawerInteraction.shouldTrack(startX: 8, translationX: 120, translationY: 5,
                                        open: false, width: 330),
       "right swipe from left edge starts interactive reveal")
expect(ChatDrawerInteraction.shouldTrack(startX: 385, translationX: -120, translationY: 5,
                                        open: true, width: 330),
       "opened card supports interactive drag-to-close")
expect(!ChatDrawerInteraction.shouldTrack(startX: 90, translationX: -120, translationY: 5,
                                         open: true, width: 330),
       "sidebar instance switcher horizontal gestures must not dismiss the drawer")
expect(!ChatDrawerInteraction.finishOpen(width: 330, wasOpen: false, predictedTranslation: 50),
       "short reveal springs back when released")
expect(ChatDrawerInteraction.finishOpen(width: 330, wasOpen: false, predictedTranslation: 200),
       "decisive right swipe completes opening")
expect(ChatDrawerInteraction.finishOpen(width: 330, wasOpen: true, predictedTranslation: -50),
       "short leftward drag cancels closing")
expect(!ChatDrawerInteraction.finishOpen(width: 330, wasOpen: true, predictedTranslation: -200),
       "decisive leftward drag closes")
expect(!ChatDrawerInteraction.shouldTrack(startX: .nan, translationX: 100,
                                          translationY: 0, open: false, width: 330),
       "invalid gesture geometry cannot start transition")

// build152: full-height card clipping must interpolate monotonically and
// preserve a square, unshaded canvas at rest.
let cardClosed = ChatCardPresentation.style(progress: 0)
let cardQuarter = ChatCardPresentation.style(progress: 0.25)
let cardHalf = ChatCardPresentation.style(progress: 0.5)
let cardOpen = ChatCardPresentation.style(progress: 1)
expect(cardClosed.cornerRadius == 0 && cardClosed.shadowOpacity == 0,
       "resting chat canvas must have no ghost card shadow")
expect(cardQuarter.cornerRadius < cardHalf.cornerRadius
       && cardHalf.cornerRadius < cardOpen.cornerRadius,
       "interactive card corner radius tracks finger progress")
expect(cardOpen.cornerRadius == 44 && cardOpen.drawerParallax == 0,
       "fully exposed sidebar shows a single rounded chat card")
expect(ChatCardPresentation.style(progress: -2).cornerRadius == 0,
       "negative or interrupted progress is clamped")
expect(ChatCardPresentation.style(progress: 99).cornerRadius == 44,
       "overshooting the open edge never expands the corner")
expect(ChatCardPresentation.style(progress: .nan).cardDim == 0,
       "invalid gesture progress never pollutes SwiftUI appearance")
expect(ChatCardPresentation.style(progress: 0.5, reduceMotion: true).drawerParallax == 0,
       "reduce motion disables decorative parallax")

expect(ChatPageBackInteraction.shouldTrack(startX: 9, horizontal: 120, vertical: 3),
       "child page right edge swipe enters interactive back transition")
expect(ChatPageBackInteraction.shouldTrack(startX: 28, horizontal: 120, vertical: 3),
       "browser back edge includes a practical 32pt touch area")
expect(!ChatPageBackInteraction.shouldTrack(startX: 90, horizontal: 120, vertical: 3),
       "child page does not steal arbitrary horizontal text selection")
expect(!ChatPageBackInteraction.shouldTrack(startX: 9, horizontal: 12, vertical: 55),
       "vertical child list scrolling does not trigger a back transition")
expect(!ChatPageBackInteraction.shouldTrack(startX: 9, horizontal: -120, vertical: 0),
       "left swipe in a child page is not a back gesture")
expect(ChatPageBackInteraction.shouldDismiss(width: 390, predictedTranslation: 240),
       "decisive child-page swipe returns to mounted conversation")
expect(!ChatPageBackInteraction.shouldDismiss(width: 390, predictedTranslation: 85),
       "partial child-page swipe cancels without destroying page state")

// build187: toolbar/back gesture must follow the same stack, never
// jump from a nested All Instances page straight to the chat.
expect(UnifiedBrowserBackNavigation.destination(route: [.single, .all],
       source: .drawer) == .singleInstance,
       "single->all returns to the single-host browser")
expect(UnifiedBrowserBackNavigation.destination(route: [.all],
       source: .drawer) == .drawer,
       "drawer->all returns to the real mounted drawer")
expect(UnifiedBrowserBackNavigation.destination(route: [.all],
       source: .chat) == .chat,
       "home search->all returns to the conversation")
expect(UnifiedBrowserBackNavigation.destination(route: [.single],
       source: .drawer) == .drawer,
       "drawer->single returns to drawer")
expect(UnifiedBrowserPresentation.canOpenSidebar(
       browserOpen: true, browserSessionOpen: true),
       "toolbar drawer opens from a chat selected in the unified browser")
expect(!UnifiedBrowserPresentation.canOpenSidebar(
       browserOpen: true, browserSessionOpen: false),
       "a bare browser keeps control of its own back destination")
expect(UnifiedBrowserPresentation.canOpenSidebar(
       browserOpen: false, browserSessionOpen: false),
       "ordinary chat hamburger opens the drawer")
expect(UnifiedBrowserPresentation.shouldRetireBrowserForNewDraft(
       browserOpen: true, browserSessionOpen: true, currentSessionID: nil),
       "new draft from browser-selected chat clears the old return route")
expect(!UnifiedBrowserPresentation.shouldRetireBrowserForNewDraft(
       browserOpen: true, browserSessionOpen: true, currentSessionID: "sid"),
       "normal session changes retain their browser back route")
expect(UnifiedBrowserPresentation.conversationVisible(
       active: true, sidebarOpen: false, browserOpen: true,
       browserSessionOpen: true, modalOpen: false, hasSession: true),
       "selected conversation remains foreground even when browser stays mounted")
expect(!UnifiedBrowserPresentation.conversationVisible(
       active: true, sidebarOpen: true, browserOpen: true,
       browserSessionOpen: false, modalOpen: false, hasSession: true),
       "drawer browser never presents the chat as foreground")
expect(!UnifiedBrowserPresentation.conversationVisible(
       active: true, sidebarOpen: false, browserOpen: true,
       browserSessionOpen: false, modalOpen: false, hasSession: true),
       "browser top page suppresses conversation presentation")
expect(!UnifiedBrowserPresentation.conversationVisible(
       active: false, sidebarOpen: false, browserOpen: true,
       browserSessionOpen: true, modalOpen: false, hasSession: true),
       "backgrounded app cannot present a foreground conversation")
expect(ChatPageBackInteraction.shouldTrack(startX: 190, horizontal: 100,
       vertical: 3, allowFullCard: true),
       "full-card right-swipe may begin from middle")
expect(!ChatPageBackInteraction.shouldTrack(startX: 190, horizontal: 20,
       vertical: 100, allowFullCard: true),
       "vertical scroll never hijacked")
expect(!ChatPageBackInteraction.shouldTrack(startX: 190, horizontal: -100,
       vertical: 0, allowFullCard: true),
       "leftward card gesture is never back")

expect(ChatTurnViewport.contentHeight(baseBottom: 240, anchorTop: 140,
                                      viewport: 800) == 940,
       "new turn reserve lets the user bubble sit at the top of the viewport")
expect(ChatTurnViewport.offset(baseBottom: 240, anchorTop: 140,
                               viewport: 800) == 140,
       "short answers keep the current user bubble fixed")
expect(ChatTurnViewport.offset(baseBottom: 1250, anchorTop: 140,
                               viewport: 800) == 450,
       "long answers follow after crossing the visible viewport")
expect(ChatTurnViewport.contentHeight(baseBottom: 240, anchorTop: nil,
                                      viewport: 800) == 800,
       "restored history does not keep a temporary turn reserve")
expect(ChatTurnViewport.offset(baseBottom: 240, anchorTop: .nan,
                               viewport: 800) == 0,
       "invalid turn anchor never writes a NaN scroll offset")

// build155: three known hosts must fit the fully exposed 340pt drawer.
// A fourth host remains scrollable, rather than being squeezed to 40pt.
expect(ChatDrawerRailLayout.totalWidth(instanceCount: 3) <= 340,
       "three instance chips must fit inside the expanded drawer")
expect(ChatDrawerRailLayout.totalWidth(instanceCount: 4) > 340,
       "four hosts use scrollable instance navigation")
let draggedCard = ChatCardPresentation.style(progress: 0.5)
let revealedCard = ChatCardPresentation.style(progress: 1)
expect(draggedCard.cornerRadius > 0 && draggedCard.cornerRadius < revealedCard.cornerRadius,
       "all card corners interpolate through the gesture")
expect(revealedCard.cornerRadius == 44 && revealedCard.cardDim > 0,
       "fully opened card keeps its rounded clipped silhouette")

var turnReading = ChatTurnReadingState()
expect(turnReading.phase == .idle && turnReading.rowID == nil,
       "controller starts without a user-turn focus")
turnReading.focus(rowID: "m-user-1", rowTop: 140, contentBottom: 240, viewport: 800)
expect(turnReading.phase == .focusingTurn,
       "new actual user message enters top-focus state")
expect(turnReading.target(contentBottom: 240, rowTop: 140, viewport: 800) == 140,
       "new user prompt stays at top")
expect(turnReading.target(contentBottom: 700, rowTop: 140, viewport: 800) == 140,
       "short reply does not move the user's question")
expect(turnReading.target(contentBottom: 700, rowTop: 140, viewport: 400) == 140,
       "keyboard shrink alone does not trigger reply follow")
expect(turnReading.target(contentBottom: 760, rowTop: 140, viewport: 400,
                          allowGrowth: false) == 140,
       "rotation or keyboard-induced reflow does not count as reply growth")
expect(turnReading.target(contentBottom: 760, rowTop: 140, viewport: 400) == 140,
       "post-resize layout does not retroactively move reading focus")
expect(turnReading.contentHeight(contentBottom: 700, viewport: 400) >= 540,
       "short reply retains runtime reserve during keyboard animation")
expect(turnReading.target(contentBottom: 1250, rowTop: 140, viewport: 400) == 450,
       "true long output advances follow after the initial viewport is filled")
expect(turnReading.phase == .streamingFollowing,
       "long reply enters streaming-follow phase")
turnReading.replyCompleted()
expect(turnReading.phase == .settled,
       "completion ends automatic follow without destroying reading position")
expect(turnReading.target(contentBottom: 1400, rowTop: 140, viewport: 400) == 450,
       "late Markdown measurement cannot move a completed answer")
turnReading.userBeganReading()
expect(turnReading.phase == .manualReading && turnReading.rowID == nil,
       "user drag cancels automated focus")
expect(turnReading.target(contentBottom: 1500, rowTop: 140, viewport: 400) == nil,
       "post-drag server updates cannot steal focus")
turnReading.focus(rowID: "m-user-2", rowTop: 1650, contentBottom: 1740, viewport: 700)
expect(turnReading.phase == .focusingTurn,
       "next new user question begins a new reading phase")
turnReading.reset()
expect(turnReading.phase == .idle && turnReading.rowID == nil,
       "session change or navigation clears stale reading state")

// build178: 1000 incremental history/keyboard updates cannot invent reply
// growth or steal a focus from manual reading.
var longTurn = ChatTurnReadingState()
longTurn.focus(rowID: "m-user-1000", rowTop: 240, contentBottom: 350, viewport: 780)
for page in 1...20 {
    let displacement = Double(page * 60)
    let anchored = longTurn.target(contentBottom: 350 + displacement,
                                   rowTop: 240 + displacement, viewport: 780,
                                   allowGrowth: false)
    expect(anchored == 240 + displacement,
           "older-page prepend maintains the focused user's screen coordinate")
}
for index in 0..<1000 {
    let viewport = index.isMultiple(of: 2) ? 390.0 : 780.0
    let offset = longTurn.target(contentBottom: 1550, rowTop: 1440,
                                 viewport: viewport, allowGrowth: false)
    expect(offset == 1440, "keyboard/width reflows must not drift 1000 times")
}
longTurn.userBeganReading()
for i in 0..<150 {
    expect(longTurn.target(contentBottom: Double(2000 + i),
                           rowTop: 1440, viewport: 390) == nil,
           "manual reading ignores stream growth, even after many tool updates")
}

// build180: status-bar-to-top is a manual reading action, not a new
// streamed-growth focus command. Simulate 180 changing tool heights after it.
var statusBarReading = ChatTurnReadingState()
statusBarReading.focus(rowID: "m-user", rowTop: 300, contentBottom: 420, viewport: 600)
statusBarReading.userBeganReading()
for i in 0..<180 {
    expect(statusBarReading.target(contentBottom: 800 + Double(i * 20),
                                   rowTop: 300, viewport: 600) == nil,
           "status-bar reading never gets pulled back to the streamed answer")
}
expect(statusBarReading.phase == .manualReading,
       "status-bar navigation transfers offset ownership to the reader")

// A sub-pixel keyboard/safe-area width wobble is a single TextKit layout.
// A true pixel/rotation change must still trigger fresh measurement.
expect(ChatDraftWidthPolicy.canonical(301.01, scale: 3)
       == ChatDraftWidthPolicy.canonical(301.10, scale: 3),
       "subpixel editor proposals use the same intrinsic height cache")
expect(ChatDraftWidthPolicy.canonical(301.1, scale: 3)
       != ChatDraftWidthPolicy.canonical(301.8, scale: 3),
       "real width change recomputes wrapping")
expect(ChatDraftWidthPolicy.canonical(.nan, scale: 3) == 0
       && ChatDraftWidthPolicy.canonical(301, scale: 0) == 0,
       "invalid input geometry never propagates nonfinite sizes")
expect(ChatDrawerRailLayout.readableChipWidth(for: "1 号") == 76,
       "short numbered instances retain a compact 44pt-touch chip")
expect(ChatDrawerRailLayout.readableChipWidth(for: "My long Hermes server") > 108,
       "descriptive host names are readable with horizontal overflow")
expect(ChatDrawerRailLayout.readableChipWidth(for: String(repeating: "深圳", count: 30)) == 180,
       "very long instance titles stay bounded and horizontally scroll")

// build156: rail width derives from actual view width, not the 340pt max.
let wideChip = ChatDrawerRailLayout.chipWidth(availableWidth: 340, instanceCount: 3)
expect(wideChip > 90 && ChatDrawerRailLayout.totalWidth(
       instanceCount: 3, chipWidth: wideChip) <= 340,
       "three chips fit a full-width drawer")
let smallChip = ChatDrawerRailLayout.chipWidth(availableWidth: 280, instanceCount: 3)
expect(smallChip >= 76 && smallChip < wideChip,
       "smaller phone reduces chip width, keeping touch targets usable")
expect(ChatDrawerRailLayout.totalWidth(instanceCount: 3, chipWidth: smallChip) <= 294,
       "small drawer requires little/no horizontal scrolling")
expect(ChatDrawerRailLayout.chipWidth(availableWidth: 340, instanceCount: 8) == 76,
       "many instances remain horizontally scrollable at a readable minimum")
expect(ChatDrawerRailLayout.chipWidth(availableWidth: .nan, instanceCount: 3) == 108,
       "invalid layout measurement never creates a nonfinite frame")

// build156: text sizing derives from final UIKit width, not SwiftUI padding.
expect(ChatDraftHeightPolicy.lines(naturalHeight: 21, lineHeight: 22,
                                   accessibility: false) == 1,
       "empty draft fits a single line")
expect(ChatDraftHeightPolicy.lines(naturalHeight: 66, lineHeight: 22,
                                   accessibility: false) == 3,
       "three-line draft is measured exactly")
expect(ChatDraftHeightPolicy.lines(naturalHeight: 440, lineHeight: 22,
                                   accessibility: false) == 6,
       "long pasted text caps at six visible lines")
expect(ChatDraftHeightPolicy.lines(naturalHeight: 440, lineHeight: 22,
                                   accessibility: true) == 3,
       "accessible text caps at three visible lines")
expect(ChatDraftHeightPolicy.height(lines: 3, lineHeight: 22) == 66,
       "SwiftUI and UIKit derive input height from one row policy")
expect(ChatDraftHeightPolicy.lines(naturalHeight: .nan, lineHeight: 22,
                                   accessibility: false) == 1,
       "invalid interim measurement does not expand the composer")
print("SCROLL_POLICY_PASS \(checks) assertions")
