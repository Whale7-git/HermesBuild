import Foundation

/// 跟随策略。UIKit 在几何提交时根据此意图保持最新端或可见消息锚点。
///
/// 两个阈值（40 / 80）之间是迟滞区：手指停在中间时状态不翻转，
/// 避免在边界来回抖动导致视图被反复拉。
///
/// 关键：几何回调每帧都来，只有状态真的翻转时才返回 true。
/// 每帧都写 @State 会让整个 body 每帧重建，列表在手指拖动时自我重排，
/// 体感就是“不丝滑”。
struct ChatScrollState: Equatable {
    private(set) var following = true
    private(set) var hasUnreadContent = false

    static let resumeThreshold: Double = 40
    static let detachThreshold: Double = 80

    /// UIKit layout/keyboard callbacks are not a user's scroll-to-bottom.
    /// When already reading history, a resized viewport that temporarily
    /// reports distance 0 must never silently reattach the stream follower.
    /// User-driven scrollViewDidScroll still owns the normal 40/80 hysteresis.
    static func geometryReportedDistance(_ distance: Double,
                                         following: Bool,
                                         navigationDetached: Bool) -> Double {
        guard distance.isFinite else { return detachThreshold + 1 }
        // UIKit geometry changes may temporarily report distance far from
        // bottom before commitLayout restores its anchor. Such callbacks
        // preserve existing ownership in both directions; user drag is the
        // only event that can change it through the delegate.
        return !following || navigationDetached
            ? max(detachThreshold + 1, distance)
            : min(resumeThreshold - 1, max(0, distance))
    }

    /// Programmatic layout/keyboard scroll notifications are not reading
    /// gestures. Preserve vertical drag/deceleration without claiming
    /// horizontal navigation, animations or viewport resize as manual intent.
    static func isUserScroll(tracking: Bool, dragging: Bool, decelerating: Bool,
                             horizontalBackPan: Bool, animatedJump: Bool,
                             resizingViewport: Bool) -> Bool {
        !horizontalBackPan && !animatedJump && !resizingViewport
            && (tracking || dragging || decelerating)
    }

    /// 离视觉底部的距离（pt），只由几何回调驱动，不猜手势。
    /// 传入 max(0, contentSize.height - bounds.height - contentOffset.y)。
    /// - Returns: 状态是否发生变化（调用方据此决定要不要写视图状态）。
    @discardableResult
    mutating func update(distanceFromBottom distance: Double) -> Bool {
        guard distance.isFinite else { return false }
        let before = self
        if distance < Self.resumeThreshold {
            following = true
            hasUnreadContent = false
        } else if distance > Self.detachThreshold {
            following = false
        }
        return self != before
    }

    /// 用户停在历史里时新吐出的内容只算“有新内容”，不拽视图。
    @discardableResult
    mutating func receivedAssistantUpdate() -> Bool {
        guard !following, !hasUnreadContent else { return false }
        hasUnreadContent = true
        return true
    }

    mutating func jumpToLatest() {
        following = true
        hasUnreadContent = false
    }
}

/// A single visible Session owns a single page request ticket. Retiring
/// invalidates even non-cooperative network completions and protects a
/// replacement page from an old completion resetting its spinner.
struct ChatPaginationOwnership {
    private var activeTicket: UUID?

    mutating func begin() -> UUID {
        let ticket = UUID()
        activeTicket = ticket
        return ticket
    }

    func owns(_ ticket: UUID) -> Bool { activeTicket == ticket }

    mutating func retire() { activeTicket = nil }
}

/// 自动分页的判定。抽成纯类型是为了能在离线套件里断言——
/// 真实的判定点在 `StableChatScrollView+Coordinator`，那是 UIKit 文件，
/// 不在任何 Linux 套件的编译单元里。
enum ChatPaginationGate {

    /// 未测量行超过这个时长就不再阻塞自动分页。
    ///
    /// `unmeasured` 只在「测量成功」或「行被移除」时收缩，而测量要等
    /// 解析完成（`isPending && !hasContent`）。解析任务被丢弃、渲染上下文
    /// 未就绪等情况下，一个行会永久 pending——此前 `guard unmeasured.isEmpty`
    /// 会让自动分页永久停摆，且没有任何提示。分页本身不依赖精确高度，
    /// 所以超过这个时限就放行。
    static let unmeasuredGraceSeconds: Double = 3

    /// 是否允许发起「加载更早」。
    ///
    /// - Parameters:
    ///   - unmeasured: 尚未完成测量的行 id 与「从何时开始未测量」。
    ///   - now: 当前时间，注入以便断言。
    static func allowsAutoLoad(unmeasured: [String: Date], now: Date,
                               canLoadOlder: Bool, loadingOlder: Bool,
                               olderOffset: Int, requestedPage: Int?) -> Bool {
        guard canLoadOlder, !loadingOlder, olderOffset > 0 else { return false }
        guard requestedPage != olderOffset else { return false }
        // 全部测完，或剩余未测量项都等够了：都不再阻塞。
        guard unmeasured.isEmpty || unmeasured.values.allSatisfy({
            now.timeIntervalSince($0) >= unmeasuredGraceSeconds
        }) else { return false }
        return true
    }
}

/// Prevent UIKit offset feedback during keyboard size changes and drag/scroll.
/// An unchanged contentOffset assignment still triggers UIKit machinery on
/// some iOS releases; a near-identical write contributes no visual movement.
///
/// Do not suppress explicit navigation/return-to-latest: those use the command
/// path, which remains separate from normal geometry commits.
enum ChatOffsetCommitPolicy {
    static let tolerance: Double = 0.5

    static func shouldAssign(current: Double, target: Double, interacting: Bool) -> Bool {
        guard current.isFinite, target.isFinite, !interacting else { return false }
        return abs(target - current) > tolerance
    }
}

/// A consistent axis-owner contract for all primary navigation cards.
/// Rightward dominant drags own card return; vertical scrolling keeps
/// ownership otherwise. Use the SAME ratio for SwiftUI card gestures and
/// the UIKit transcript scroll controller.
enum ChatBackAxisPolicy {
    static func claimsReturn(horizontal: Double, vertical: Double) -> Bool {
        guard horizontal.isFinite, vertical.isFinite else { return false }
        return horizontal > 0 && horizontal > abs(vertical) * 1.65
    }
}

/// Pure gesture contract for the chat-card/sidebar interactive transition.
/// UIKit/SwiftUI owns animation; these functions own thresholds, cancellation,
/// and boundary clamps so they can be regression-tested without an iOS SDK.
enum ChatDrawerInteraction {
    static func reveal(width: Double, open: Bool, translation: Double) -> Double {
        guard width.isFinite, width > 0, translation.isFinite else { return 0 }
        let start = open ? width : 0
        return min(width, max(0, start + (open ? min(0, translation) : max(0, translation))))
    }

    static func shouldTrack(startX: Double, translationX: Double,
                            translationY: Double, open: Bool, width: Double,
                            allowFullCard: Bool = false) -> Bool {
        guard startX.isFinite, translationX.isFinite, translationY.isFinite,
              width.isFinite, width > 0, startX >= 0 else { return false }
        // Only the exposed chat card, not the drawer's horizontal host rail,
        // owns a drag-to-close. A closed chat card accepts back from ANY x.
        let validOrigin = open ? startX >= width - 12 :
            (allowFullCard || startX < 24)
        let validDirection = open
            ? translationX < 0 && -translationX > abs(translationY) * 1.65
            : ChatBackAxisPolicy.claimsReturn(
                horizontal: translationX, vertical: translationY)
        return validOrigin && validDirection
    }

    static func finishOpen(width: Double, wasOpen: Bool, predictedTranslation: Double) -> Bool {
        guard width.isFinite, width > 0, predictedTranslation.isFinite else { return wasOpen }
        let destination = reveal(width: width, open: wasOpen, translation: predictedTranslation)
        return wasOpen ? destination >= width * 0.56 : destination > width * 0.44
    }
}

/// One drag retains horizontal ownership after the initial direction test.
/// Requiring shouldTrack() on EVERY update made a closing card snap to its
/// fully open offset when the finger reversed at the left edge.
struct ChatDrawerGestureState {
    private(set) var claimed = false
    private(set) var translation: Double = 0

    mutating func update(startX: Double, horizontal: Double, vertical: Double,
                         open: Bool, width: Double, allowFullCard: Bool = false) {
        guard horizontal.isFinite, vertical.isFinite else { return }
        if !claimed {
            guard ChatDrawerInteraction.shouldTrack(
                startX: startX, translationX: horizontal, translationY: vertical,
                open: open, width: width, allowFullCard: allowFullCard) else { return }
            claimed = true
        }
        // Once claimed, keep raw signed translation. The reveal policy clamps
        // to [0, width] without transferring gesture ownership to text scroll.
        translation = horizontal
    }
}

/// Modal sheets own all pan gestures until dismissed, even if a parent
/// simultaneously recognizes a horizontal drag behind the sheet.
enum RootNavigationModalPolicy {
    static func allowsGesture(taskCenterPresented: Bool,
                              settingsPresented: Bool,
                              needsLogin: Bool) -> Bool {
        !taskCenterPresented && !settingsPresented && !needsLogin
    }
}

/// Defer a task selection until its sheet has fully disappeared. A host or
/// account change during dismissal revokes the pending navigation.
enum RootTaskSheetNavigation {
    static func canOpen(pendingScope: String,
                        currentScope: String,
                        sessionAvailable: Bool) -> Bool {
        !pendingScope.isEmpty && pendingScope == currentScope && sessionAvailable
    }
}

/// Persistent event owner for the root chat-card / drawer gesture.
/// @GestureState provides only interactive translation; SwiftUI may reset it
/// before onEnded, so a separate state value must own the completed gesture.
/// Browser-page gestures use their own route, not this drawer owner.
struct RootDrawerGestureOwnership: Equatable {
    private(set) var claimed = false

    mutating func changed(open: Bool, startX: Double, horizontal: Double,
                          vertical: Double, width: Double) {
        guard !claimed else { return }
        claimed = ChatDrawerInteraction.shouldTrack(
            startX: startX, translationX: horizontal, translationY: vertical,
            open: open, width: width, allowFullCard: true)
    }

    /// A cancelled, vertical, or browser-owned gesture has no destination.
    /// The caller changes the drawer only when a claimed gesture has ended.
    mutating func ended(open: Bool, width: Double,
                        predictedTranslation: Double) -> Bool? {
        defer { claimed = false }
        guard claimed else { return nil }
        return ChatDrawerInteraction.finishOpen(
            width: width, wasOpen: open, predictedTranslation: predictedTranslation)
    }

    mutating func cancelled() { claimed = false }
}

/// Transient visual motion for the two existing stacked browser routes.
/// Unlike a raw CGFloat GestureState this retains ownership across finger
/// reversal within one gesture, while still resetting between gestures.
struct RootPageGestureState {
    private(set) var claimed = false
    private(set) var translation: Double = 0

    mutating func update(startX: Double, horizontal: Double, vertical: Double) {
        guard horizontal.isFinite, vertical.isFinite else { return }
        if !claimed {
            guard ChatPageBackInteraction.shouldTrack(
                startX: startX, horizontal: horizontal, vertical: vertical,
                allowFullCard: true) else { return }
            claimed = true
        }
        translation = max(0, horizontal)
    }
}

/// The stacked browser and the chat opened from it each hold their own stable
/// event owner. Only the topmost route receives input; this struct does not
/// modify the route stack or steal the native chat/drawer gesture.
struct RootPageGestureOwnership: Equatable {
    private(set) var claimed = false

    mutating func changed(startX: Double, horizontal: Double, vertical: Double) {
        guard !claimed else { return }
        claimed = ChatPageBackInteraction.shouldTrack(
            startX: startX, horizontal: horizontal, vertical: vertical,
            allowFullCard: true)
    }

    mutating func ended(width: Double, predictedTranslation: Double) -> Bool {
        defer { claimed = false }
        return claimed && ChatPageBackInteraction.shouldDismiss(
            width: width, predictedTranslation: predictedTranslation)
    }

    mutating func cancelled() { claimed = false }
}

/// Pure, bounded presentation math; the SwiftUI host owns the actual full-
/// screen clip, safe-area padding, and interactive animation.
enum ChatCardPresentation {
    struct Style {
        let cornerRadius: Double
        let shadowRadius: Double
        let shadowOpacity: Double
        let drawerParallax: Double
        let cardDim: Double
    }

    static func style(progress: Double, reduceMotion: Bool = false) -> Style {
        let p = progress.isFinite ? min(1, max(0, progress)) : 0
        // The card remains rectangular at rest and only rounds as it reveals
        // underlying navigation. Reduce Motion keeps the same geometry without
        // parallax, as movement can cause vestibular discomfort.
        return Style(cornerRadius: 44 * p,
                     shadowRadius: 20 * p,
                     shadowOpacity: 0.17 * p,
                     drawerParallax: reduceMotion ? 0 : -14 * (1 - p),
                     cardDim: 0.08 * p)
    }
}

/// A distinct navigation state machine for a real page stacked above chat.
/// Root drawer drag math must not be reused for this route: back reveals the
/// previous conversation, whereas the drawer reveals the session manager.
enum ChatPageBackInteraction {
    static func shouldTrack(startX: Double, horizontal: Double, vertical: Double,
                            allowFullCard: Bool = false) -> Bool {
        guard startX.isFinite, horizontal.isFinite, vertical.isFinite else { return false }
        return startX >= 0 && (allowFullCard || startX < 32)
            && ChatBackAxisPolicy.claimsReturn(horizontal: horizontal, vertical: vertical)
    }
    static func shouldDismiss(width: Double, predictedTranslation: Double) -> Bool {
        guard width.isFinite, width > 0, predictedTranslation.isFinite else { return false }
        return predictedTranslation > width * 0.4
    }
}

/// The root keeps an ordered browser stack and the actual parent surface.
/// Switching Hermes backends never changes these navigation identities.
/// Actual presented surface, not merely whether a browser route is retained.
/// When a session is pushed from the browser, the browser stays mounted behind
/// the chat, but must not suppress foreground conversation notifications.
enum UnifiedBrowserPresentation {
    /// The selected chat is above the mounted browser: its hamburger must
    /// still work. A bare browser page cannot bypass its own back route.
    static func canOpenSidebar(browserOpen: Bool, browserSessionOpen: Bool) -> Bool {
        !browserOpen || browserSessionOpen
    }

    static func shouldRetireBrowserForNewDraft(browserOpen: Bool,
                                               browserSessionOpen: Bool,
                                               currentSessionID: String?) -> Bool {
        browserOpen && browserSessionOpen && currentSessionID == nil
    }

    static func conversationVisible(active: Bool, sidebarOpen: Bool,
                                    browserOpen: Bool, browserSessionOpen: Bool,
                                    modalOpen: Bool, hasSession: Bool) -> Bool {
        active && !sidebarOpen && (!browserOpen || browserSessionOpen)
            && !modalOpen && hasSession
    }
}

enum UnifiedBrowserPage: Equatable { case single, all }
enum UnifiedBrowserSource: Equatable { case chat, drawer }

enum UnifiedBrowserBackNavigation {
    enum Destination: Equatable { case chat, drawer, singleInstance }

    static func destination(route: [UnifiedBrowserPage],
                            source: UnifiedBrowserSource) -> Destination {
        if route.count > 1 { return .singleInstance }
        return source == .drawer ? .drawer : .chat
    }
}

enum ChatTurnViewport {
    /// Runtime-only viewport reserve for a newly sent turn. Never a transcript row.
    static func contentHeight(baseBottom: Double, anchorTop: Double?, viewport: Double) -> Double {
        guard viewport.isFinite, viewport > 0 else { return max(0, baseBottom) }
        guard let anchorTop, anchorTop.isFinite, anchorTop >= 0 else {
            return max(viewport, baseBottom)
        }
        return max(viewport, baseBottom, anchorTop + viewport)
    }

    static func offset(baseBottom: Double, anchorTop: Double, viewport: Double) -> Double {
        guard baseBottom.isFinite, anchorTop.isFinite, viewport.isFinite,
              viewport > 0, anchorTop >= 0 else { return 0 }
        return max(anchorTop, baseBottom - viewport)
    }
}

/// The three-instance rail should fit before the movable card overlays the
/// drawer. Extra instances deliberately scroll, rather than shrinking labels
/// below a legible touch target.
enum ChatDrawerRailLayout {
    /// Keep short (numbered) hosts compact, but give descriptive names enough
    /// width to remain readable. A long rail scrolls horizontally instead of
    /// compressing every label to the same narrow width.
    static func readableChipWidth(for label: String) -> Double {
        let units = label.unicodeScalars.reduce(0) { partial, scalar in
            partial + (scalar.value >= 0x2E80 ? 2 : 1)
        }
        return min(180, max(76, 34 + Double(units) * 7))
    }

    static func chipWidth(availableWidth: Double, instanceCount: Int,
                          minimum: Double = 76, preferred: Double = 108,
                          gap: Double = 7, horizontalInsets: Double = 40) -> Double {
        guard availableWidth.isFinite, availableWidth > 0,
              instanceCount > 0 else { return preferred }
        let usable = max(0, availableWidth - horizontalInsets
                         - gap * Double(max(0, instanceCount - 1)))
        // Fit the visible chips when feasible; otherwise retain a legible
        // minimum and let the horizontal ScrollView scroll to the selection.
        return min(preferred, max(minimum, usable / Double(instanceCount)))
    }

    static func totalWidth(instanceCount: Int, chipWidth: Double = 90,
                           gap: Double = 7, horizontalInsets: Double = 40) -> Double {
        let count = max(0, instanceCount)
        return horizontalInsets + chipWidth * Double(count)
            + gap * Double(max(0, count - 1))
    }
}

/// Per-controller, transient reading intent. A new reply may grow without
/// moving the user question; a keyboard resize is not reply growth.
struct ChatTurnReadingState {
    enum Phase: Equatable {
        case idle
        case focusingTurn
        case streamingFollowing
        case settled
        case manualReading
    }

    private(set) var phase: Phase = .idle
    private(set) var rowID: String?
    private(set) var focusViewport: Double = 0
    private(set) var lastContentBottom: Double = 0
    private(set) var targetOffset: Double = 0
    private(set) var anchorTop: Double = 0

    mutating func focus(rowID: String, rowTop: Double,
                        contentBottom: Double, viewport: Double) {
        guard !rowID.isEmpty, rowTop.isFinite, rowTop >= 0,
              contentBottom.isFinite, viewport.isFinite, viewport > 0 else {
            reset()
            return
        }
        phase = .focusingTurn
        self.rowID = rowID
        anchorTop = rowTop
        focusViewport = viewport
        lastContentBottom = contentBottom
        targetOffset = rowTop
    }

    mutating func target(contentBottom: Double, rowTop: Double?,
                         viewport: Double, allowGrowth: Bool = true) -> Double? {
        guard rowID != nil else { return nil }
        guard contentBottom.isFinite, contentBottom >= 0,
              viewport.isFinite, viewport > 0,
              let rowTop, rowTop.isFinite, rowTop >= 0 else {
            reset()
            return nil
        }
        // Historical pagination may move the row's document coordinate.
        // Preserve its *screen* position without calling this reply growth.
        let displacement = rowTop - anchorTop
        if abs(displacement) > 0.5 {
            targetOffset = max(0, targetOffset + displacement)
            anchorTop = rowTop
            // Inserting older history is not new assistant output.
            lastContentBottom += displacement
        }
        if !allowGrowth {
            // Reflow from a width change, keyboard/safe-area transition or
            // rotation does not earn additional streaming-follow distance.
            lastContentBottom = contentBottom
            return targetOffset
        }
        if phase == .focusingTurn || phase == .streamingFollowing {
            if contentBottom > lastContentBottom + 0.5 {
                targetOffset = max(targetOffset, contentBottom - focusViewport)
                if targetOffset > anchorTop + 0.5 {
                    phase = .streamingFollowing
                }
            }
            lastContentBottom = max(lastContentBottom, contentBottom)
        }
        return targetOffset
    }

    func contentHeight(contentBottom: Double, viewport: Double) -> Double {
        guard contentBottom.isFinite, viewport.isFinite, viewport > 0 else { return 0 }
        // A runtime-only reserve is large enough for the focused offset,
        // even while the keyboard reduces the viewport.
        guard rowID != nil else { return max(viewport, contentBottom) }
        return max(viewport, contentBottom, targetOffset + viewport)
    }

    mutating func replyCompleted() {
        if phase == .focusingTurn || phase == .streamingFollowing {
            phase = .settled
        }
    }

    mutating func userBeganReading() {
        rowID = nil
        phase = .manualReading
    }

    mutating func reset() {
        rowID = nil
        phase = .idle
        focusViewport = 0
        lastContentBottom = 0
        targetOffset = 0
        anchorTop = 0
    }
}

/// Round only the measurement width to physical pixels. A fractional SwiftUI
/// proposal (e.g. during interactive keyboard/layout changes) must not trigger
/// repeated font layout if it still maps to the same device pixel.
enum ChatDraftWidthPolicy {
    static func canonical(_ width: Double, scale: Double) -> Double {
        guard width.isFinite, width > 0, scale.isFinite, scale > 0 else { return 0 }
        return (width * scale).rounded(.toNearestOrAwayFromZero) / scale
    }
}

/// Pure input-height policy. UIKit supplies the measured natural text height
/// at the final editor width; SwiftUI must not independently infer row counts.
enum ChatDraftHeightPolicy {
    static func lines(naturalHeight: Double, lineHeight: Double,
                      accessibility: Bool) -> Int {
        guard naturalHeight.isFinite, lineHeight.isFinite,
              naturalHeight > 0, lineHeight > 0 else { return 1 }
        let maximum = accessibility ? 3 : 6
        let count = Int(min(Double(maximum),
            max(1, ((naturalHeight / lineHeight) - 1e-6).rounded(.up))))
        return min(maximum, max(1, count))
    }

    static func height(lines: Int, lineHeight: Double) -> Double {
        guard lineHeight.isFinite, lineHeight > 0 else { return 22 }
        return Double(max(1, lines)) * lineHeight
    }
}
