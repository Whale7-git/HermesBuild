import SwiftUI
import UIKit
import Textual

/// Rendering snapshot. Typing in the composer must not reconfigure the transcript.
struct ChatListSnapshot: Equatable {
    var items: [ChatRowItem]
    /// Optional for synthetic snapshots; production supplies its exact
    /// projection revision so a token update avoids a second full array scan.
    var itemsStamp: ChatTimelineItemsStamp? = nil
    var states: [String: ChatCellState]
    var actionsEnabled: Bool
    /// 后端能力表。`actionsEnabled` 只回答「现在能不能操作」，能力表回答
    /// 「这个后端支不支持」——两者混在一个 Bool 里会让「不支持」退化成
    /// 「静默没有入口」，用户分不清是坏了还是本来没有。
    var capabilities: BackendCapabilities = .webUI
    var status: ChatStatusSnapshot
    var olderOffset: Int
    var loadingOlder: Bool
    var canLoadOlder: Bool
    /// 已到本地历史窗口上限。与 `canLoadOlder` 分开：后者回答「现在能不能点」，
    /// 这个回答「点了也不会再有更多」——到上限时按钮不该可点，也不该静默无反应。
    var olderLimitReached = false
    var dynamicTypeSize: DynamicTypeSize
    var colorScheme: ColorScheme
    var focusedRowID: String? = nil
    var findQuery: String = ""
    var findOrdinal: Int? = nil
    var canResendPending = false
    var pendingBusy = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        ChatTimelineItemsEquality.equal(lhs.items, stamp: lhs.itemsStamp,
                                        rhs.items, stamp: rhs.itemsStamp)
            && lhs.states == rhs.states
            && lhs.actionsEnabled == rhs.actionsEnabled
            && lhs.capabilities == rhs.capabilities
            && lhs.status == rhs.status
            && lhs.olderOffset == rhs.olderOffset
            && lhs.loadingOlder == rhs.loadingOlder
            && lhs.canLoadOlder == rhs.canLoadOlder
            && lhs.olderLimitReached == rhs.olderLimitReached
            && lhs.dynamicTypeSize == rhs.dynamicTypeSize
            && lhs.colorScheme == rhs.colorScheme
            && lhs.focusedRowID == rhs.focusedRowID
            && lhs.findQuery == rhs.findQuery
            && lhs.findOrdinal == rhs.findOrdinal
            && lhs.canResendPending == rhs.canResendPending
            && lhs.pendingBusy == rhs.pendingBusy
    }
}

struct ChatScrollCommand: Equatable {
    var sequence = 0
    var animated = false
    var targetID: String? = nil
    var offsetInRow: Double = 0
    var findOrdinal: Int? = nil
    var focusTurn = false
}

/// Upright UIKit scrolling with measured geometry and a bounded cache of hosts.
/// Evicting rich text never discards its measured height. Recreated hosts reserve
/// that exact space while Textual completes its initial empty parsing pass.
struct StableChatScrollView: UIViewControllerRepresentable {
    @Environment(\.isScrollEnabled) private var isScrollEnabled
    let snapshot: ChatListSnapshot
    let isGenerating: Bool
    let command: ChatScrollCommand
    let row: (ChatRowItem) -> AnyView
    let footer: () -> AnyView
    let onDistance: (Double) -> Void
    let onLoadOlder: () -> Void
    let onBackgroundTap: () -> Void
    let onReadingPosition: (ChatReadingPosition) -> Void
    let onUserScroll: () -> Void
    /// 仅用于性能埋点取句柄；默认 nil，不改变任何现有调用点。
    var onControllerReady: ((ChatScrollController) -> Void)? = nil
    var onFindLocationUnavailable: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> ChatScrollController {
        let controller = ChatScrollController()
        onControllerReady?(controller)
        return controller
    }

    static func dismantleUIViewController(_ controller: ChatScrollController, coordinator: ()) {
        controller.persistReadingPosition()
    }

    func updateUIViewController(_ controller: ChatScrollController, context: Context) {
        // SwiftUI's scrollDisabled is not automatically forwarded to our
        // UIKit UIScrollView. Freeze it only while the horizontal card return
        // owns the gesture, without reconfiguring the transcript snapshot.
        if controller.scrollView.isScrollEnabled != isScrollEnabled {
            controller.scrollView.isScrollEnabled = isScrollEnabled
            // Disabling scrolling may cancel UIKit's pan without calling
            // scrollViewDidEndDragging; reset the axis guard on reenable.
            if isScrollEnabled { controller.horizontalBackPan = false }
        }
        controller.receive(self)
    }
}

struct ChatMeasuredContent: View {
    let content: AnyView
    let rendering: ChatRowRenderState
    let generation: UInt64
    let onHeight: (CGFloat) -> Void

    var body: some View {
        content
            .environment(\.chatRenderState, rendering)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
            .onChange(of: generation, initial: true) { _, token in rendering.didMount(token) }
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}

final class ChatScrollController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    final class MountedRow {
        let host: UIHostingController<ChatMeasuredContent>
        let rendering: ChatRowRenderState
        var generation: UInt64
        var restoring: Bool
        var lastUse: UInt64 = 0
        init(host: UIHostingController<ChatMeasuredContent>, rendering: ChatRowRenderState,
             generation: UInt64, restoring: Bool) {
            self.host = host
            self.rendering = rendering
            self.generation = generation
            self.restoring = restoring
        }
    }

    let scrollView = UIScrollView()
    var mounted: [String: MountedRow] = [:]
    // Only these small numbers survive host eviction. They are actual UIKit /
    // SwiftUI measurements for this content, fold state, width and text size.
    var heights: [String: CGFloat] = [:]
    var itemByID: [String: ChatRowItem] = [:]
    var costs: [String: Int] = [:]
    var order: [String] = []
    // 增量维护的行序：order == orderLeading + itemIDs + orderTrailing。
    // 内容流式更新（id 序列不变）不再重建任何全表结构。
    private var itemIDs: [String] = []
    private var orderLeading: [String] = []
    private var orderTrailing: [String] = []
    var indexByID: [String: Int] = [:]
    var frames: [ChatViewportLayout.Frame] = []
    /// id → frames 下标。原先这里是 `[String: Frame]` 全表字典：每次高度提交都要
    /// 重新插入 2000 条记录（哈希 + 扩容）。改成下标后，只有「已提交行序」变化时
    /// 才重建，纯流式高度更新完全不碰它；查 Frame 仍然 O(1)。
    var frameIndexByID: [String: Int] = [:]
    /// 当前施加的底部留白：内容不足一屏时把内容压到底部。
    var bottomPadding: Double = 0
    /// 上次重建几何时的视口高度。视口变化（键盘/旋转）可能让底部留白从 0
    /// 变成正值或反之，那种情况下所有 top 都会平移，必须整表重算。
    var geometryViewportHeight: Double = 0
    /// 已提交行序 / 已测量集合 / committed 集合三者任一变化的版本号。
    /// 只有它变化才需要整表重算 admitted 与 frames。
    var geometryStructureVersion: UInt64 = 0
    var committedGeometryVersion: UInt64 = .max
    /// 本轮待应用的「已提交行高度变化」。典型规模 1–3 行，绝不整表重建。
    var pendingGeometryDeltas: [String: CGFloat] = [:]
    // 事件观察 token：必须成对移除，否则 loadView 重入会重复注册，
    // 同一次事件触发多次写盘/置脏。
    // nonisolated(unsafe)：deinit 不在 MainActor 上，需要能读这份 token 列表；
    // 它只在主线程写入/清空，deinit 时已无并发访问者。
    nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []
    var attached = Set<String>()
    var preparation = ChatPreparationQueue(pendingLimit: 6)
    var preparationIndex = ChatPreparationIndex()
    var dirty = Set<String>()
    /// 未完成测量的行 → 首次进入未测量状态的时间。
    ///
    /// 带时间戳是为了超时兜底：解析卡住时这一项永不收缩，
    /// 而 `checkPagination` 曾要求集合为空才自动翻页，会永久停摆。
    var unmeasured: [String: Date] = [:]
    var committed = Set<String>()
    var wantedHosts = Set<String>()
    var visibleHosts = Set<String>()
    var interactionHosts = Set<String>()
    // 事件驱动的脏标记：滚动热路径不再递归宿主子树。只有触摸/编辑/选中/菜单
    // 事件才置位，查询时扫一次可见band并把结果缓存到下一次事件。
    var interactionDirty = false
    var selectionDirty = false
    var cachedInteractionHosts = Set<String>()
    var cachedSelectionActive = false
    // 首屏测量优先级：visible 及其上下各 2 行先入队，其余沿用 2 行/16ms。
    var measurementBand = Set<String>()
    var workScheduled = false
    var current: StableChatScrollView?
    var pending: StableChatScrollView?
    var policy = ChatScrollState()
    var horizontalBackPan = false
    private var lastCommand = 0
    var navigationTarget: ChatScrollCommand?
    var navigationDetached = false
    var turnReading = ChatTurnReadingState()
    /// Captured only AFTER the user's deceleration completes, and released
    /// before any new drag/navigation. No programmatic correction during pan.
    var manualTurnAnchor: (id: String, screenTop: Double)?
    var resizingViewport = false
    var findRetryScheduled = false
    var findRetries = 0
    var applying = false
    var scheduled = false
    var pendingHeights: [String: CGFloat] = [:]
    private var lastSize = CGSize.zero
    var needsMeasurement = false
    private var viewportDirty = false
    var animatedJump = false
    /// `animatedJump` 的兜底计时器。
    ///
    /// `animatedJump` 靠 `scrollViewDidEndScrollingAnimation` 复位，但那个回调
    /// 在两种情况下会**不触发**：一是动画期间 `contentSize` 持续增长（流式回答
    /// 正在写），UIKit 会把目标 offset 重新夹取，动画被中断而不回调；二是目标
    /// offset 与当前 offset 只差不到 1pt（代码里直接跳过动画，但标志已经置位）。
    /// 一旦漏掉，`inMotion` 就永久为 true：
    ///   - `flush()` 全部早退 → 新内容不再提交；
    ///   - `applyNavigationIfReady()` 早退 → 后续跳转命令失效；
    ///   - 用户只能再滑一下，靠 `scrollViewWillBeginDragging` 复位标志。
    /// 这正好对应「点回到最新没反应，过一会/再滑一下才好」。
    var animatedJumpWatchdog: DispatchWorkItem?
    /// 动画超时上限。UIKit 的滚动动画在长距离下约 0.3–0.5s，留一倍余量。
    static let animatedJumpTimeout: TimeInterval = 1.0
    var hasInteracted = false
    var requestedPage: Int?
    var publishingDistance = false
    var accessClock: UInt64 = 0
    var generation: UInt64 = 0
    var memoryConstrained = false
    // 性能埋点专用状态。全部是可空 Sample / 标量；未开始采样时 begin() 返回
    // nil，保存 nil 不产生分配，finish() 也会直接返回。
    var publishSample: ChatPerformanceRecorder.Sample?
    var commitPassSample: ChatPerformanceRecorder.Sample?
    var firstPaintSample: ChatPerformanceRecorder.Sample?
    var hasReportedFirstPaint = false
    var paginationSample: ChatPerformanceRecorder.Sample?
    var loadedMessageCount = 0

    static let footerID = "__chat_status"
    static let historyID = "__chat_history"
    var inMotion: Bool {
        scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating || animatedJump
    }

    private let scrollTraceLabel = UILabel()
    var scrollTraceEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--hermes-scroll-trace")
    }

    /// Test-only accessibility diagnostics. No message text or credentials are recorded.
    /// The value is updated at real UIKit gesture and geometry boundaries.
    func publishScrollTrace(reason: String, resolvedTarget: Double? = nil,
                            anchorID: String? = nil, beforeOffset: Double? = nil,
                            offsetAfterResize: Double? = nil) {
        guard scrollTraceEnabled else { return }
        let selectedID = turnReading.rowID ?? anchorID ?? navigationTarget?.targetID
        let contentFrame = selectedID.flatMap { frame(for: $0) }
        let userFrame: CGRect?
        if let selectedID, let host = mounted[selectedID]?.host.view {
            userFrame = host.convert(host.bounds, to: nil)
        } else {
            userFrame = nil
        }
        let transcriptFrame = scrollView.convert(scrollView.bounds, to: nil)
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "none" }
            return String(format: "%.2f", value)
        }
        func rect(_ value: CGRect?) -> String {
            guard let value else { return "none" }
            return String(format: "(%.2f,%.2f,%.2f,%.2f)",
                          Double(value.minX), Double(value.minY),
                          Double(value.width), Double(value.height))
        }
        let rowContent = contentFrame.map {
            String(format: "(top=%.2f,height=%.2f,bottom=%.2f)", $0.top, $0.height, $0.bottom)
        } ?? "none"
        let focusApplied = turnReading.rowID != nil && navigationTarget == nil
        scrollTraceLabel.accessibilityValue = [
            "reason=\(reason)",
            "focus=\(focusApplied ? "applied" : "pending")",
            "offset=\(number(Double(scrollView.contentOffset.y)))",
            "target=\(number(resolvedTarget))",
            "turnTarget=\(number(turnReading.targetOffset))",
            "turnAnchor=\(turnReading.rowID ?? "none")",
            "viewportAnchor=\(anchorID ?? "none")",
            "rowContent=\(rowContent)",
            "userFrame=\(rect(userFrame))",
            "transcriptFrame=\(rect(transcriptFrame))",
            "contentSize=\(number(Double(scrollView.contentSize.height)))",
            "viewport=\(number(Double(scrollView.bounds.height)))",
            "inMotion=\(inMotion)",
            "phase=\(String(describing: turnReading.phase))",
            "navigationTarget=\(navigationTarget?.targetID ?? "none")",
            "beforeCommitOffset=\(number(beforeOffset))",
            "offsetAfterResize=\(number(offsetAfterResize))",
            "following=\(policy.following)"
        ].joined(separator: ";")
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        // UIKit locks to the first strong pan axis. A card-right drag must
        // not simultaneously move the transcript up or down.
        scrollView.isDirectionalLockEnabled = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)
        if scrollTraceEnabled {
            scrollTraceLabel.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            scrollTraceLabel.alpha = 0.1
            scrollTraceLabel.isAccessibilityElement = true
            scrollTraceLabel.accessibilityIdentifier = "HermesScrollTrace"
            scrollTraceLabel.accessibilityLabel = "Hermes scroll trace"
            scrollTraceLabel.isUserInteractionEnabled = false
            view.addSubview(scrollTraceLabel)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        scrollView.addGestureRecognizer(tap)
        observeInteractionEvents()
    }

    deinit {
        // 直接读存储属性并移除：deinit 不是 main actor 隔离的，
        // 这里只碰 NotificationCenter 的 token 与 GCD 计时器，不涉及 UI 状态。
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        // 兜底计时器持的是 weak self，但控制器已销毁时没必要再醒来一次。
        animatedJumpWatchdog?.cancel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 首屏起点优先取首个快照下发（receive，见下）；这里只兜底：
        // 若出现回调前还没拿到样本且内容仍未提交，就从出现时刻开始计。
        // 若出现时已有非空 frames，说明首屏发生在采样/出现之前，直接作废，
        // 不伪造 0ms 样本。
        guard !hasReportedFirstPaint else { return }
        if frames.isEmpty {
            if firstPaintSample == nil { firstPaintSample = ChatPerformanceRecorder.shared.begin() }
        } else {
            hasReportedFirstPaint = true
        }
    }

    func receive(_ input: StableChatScrollView) {
        loadViewIfNeeded()
        // 快照发布时间点（SwiftUI → UIViewRepresentable 的 updateUIView）。
        // 每次下发都刷新，commitLayout 收尾时结算一次 .publishToCommit；
        // 只有真正发生提交才记录，空闲等待的样本会被丢弃。
        if ChatPerformanceRecorder.shared.isRecording {
            publishSample = ChatPerformanceRecorder.shared.begin()
        }
        // 首屏起点：首个快照下发时刻（updateUIView，≈会话页开始装配）。
        // 终点是 commitLayout 第一次提交非空 frames；只上报一次。
        if !hasReportedFirstPaint, firstPaintSample == nil,
           ChatPerformanceRecorder.shared.isRecording {
            firstPaintSample = ChatPerformanceRecorder.shared.begin()
        }
        if current?.isGenerating == true && !input.isGenerating {
            turnReading.replyCompleted()
        }
        pending = input
        // An explicit user command may interrupt momentum. Ordinary content
        // updates wait until UIKit relinquishes the drag/deceleration offset.
        if input.command.sequence != lastCommand {
            manualTurnAnchor = nil
            if !input.command.focusTurn { turnReading.reset() }
            findRetries = 0
            endAnimatedJump()
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            navigationTarget = input.command.targetID == nil ? nil : input.command
            navigationDetached = navigationTarget != nil
            if navigationTarget != nil {
                policy.update(distanceFromBottom: ChatScrollState.detachThreshold + 1)
            }
            flush(force: true)
            lastCommand = input.command.sequence
            if input.command.targetID != nil {
                applyNavigationIfReady()
                scheduleWork()
            } else {
                navigationTarget = nil
                turnReading.reset()
                policy.jumpToLatest()
                let bottom = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                let needsAnimation = input.command.animated && abs(scrollView.contentOffset.y - bottom) > 1
                if needsAnimation {
                    beginAnimatedJump()
                }
                scrollView.setContentOffset(CGPoint(x: 0, y: bottom), animated: needsAnimation)
                // 即使这次没走动画，也要立刻提交一次：`flush()` 在命令路径上必须
                // 生效，否则「回到最新」点完界面要等到下一次内容更新才动。
                flush(force: true)
            }
            publishDistance()
        } else if !inMotion {
            flush()
        }
    }

    /// 开始一次「程序化动画跳转」，并挂上超时兜底。
    ///
    /// 见 `animatedJumpWatchdog` 的注释：`scrollViewDidEndScrollingAnimation` 不保证
    /// 一定到达，一旦漏掉 `inMotion` 会永久为 true，跳转按钮和内容提交都卡住。
    func beginAnimatedJump() {
        animatedJump = true
        animatedJumpWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.animatedJump else { return }
            self.animatedJump = false
            self.animatedJumpWatchdog = nil
            // 超时后补一次提交与位置发布：动画期间被推迟的几何与距离都补上。
            self.markInteractionDirty()
            self.flush()
            self.publishDistance()
            self.persistReadingPosition()
        }
        animatedJumpWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.animatedJumpTimeout, execute: work)
    }

    /// 结束程序化动画跳转（正常回调、用户打断、新命令都走这里）。
    func endAnimatedJump() {
        animatedJumpWatchdog?.cancel()
        animatedJumpWatchdog = nil
        animatedJump = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !applying else { return }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if ChatViewportSizePolicy.changed(
            previousWidth: Double(lastSize.width), previousHeight: Double(lastSize.height),
            width: Double(size.width), height: Double(size.height),
            scale: Double(view.traitCollection.displayScale)) {
            // Capture against the OLD viewport before resizing for the keyboard
            // or orientation. SwiftUI already reserves header/composer space.
            let anchors = captureAnchors()
            let previous = scrollView.contentOffset.y
            let widthChanged = abs(size.width - lastSize.width) > 0.5
            ChatPerformanceRecorder.shared.recordViewportChange(
                from: Double(lastSize.height), to: Double(size.height),
                offset: Double(previous), moving: inMotion)
            lastSize = size
            applying = true
            withoutAnimations {
                scrollView.frame = view.bounds
                if inMotion {
                    // Interactive keyboard dismissal changes the viewport on
                    // every pan tick. Resize the viewport, but let UIScrollView
                    // own its offset until the gesture/coast has finished.
                    needsMeasurement = needsMeasurement || widthChanged
                    viewportDirty = true
                } else {
                    resizingViewport = true
                    if widthChanged || needsMeasurement { measureAll() }
                    commitLayout(anchors: anchors, previous: previous)
                    resizingViewport = false
                    viewportDirty = false
                }
            }
            applying = false
            publishDistance()
        }
        if !inMotion { flush() }
    }

    func flush(force: Bool = false) {
        guard !applying, force || !inMotion else { return }
        let input = pending ?? current
        guard let input else { return }
        let old = current?.snapshot
        let changed = old != input.snapshot
        guard changed || !pendingHeights.isEmpty || needsMeasurement || viewportDirty else {
            current = input // Refresh action closures without touching hosted views.
            pending = nil
            // 内容未变，不会提交布局；丢弃发布样本，别把空闲等待算成提交延迟。
            publishSample = nil
            updateWindow() // Resume normal pacing after a scroll with no data changes.
            return
        }
        let anchors = captureAnchors()
        let previous = scrollView.contentOffset.y
        applying = true
        withoutAnimations {
            current = input
            pending = nil
            if changed { reconcile(input, previous: old) }
            for (id, height) in pendingHeights {
                if indexByID[id] != nil {
                    let rounded = roundedHeight(height)
                    let previousHeight = heights[id]
                    heights[id] = rounded
                    unmeasured.removeValue(forKey: id)
                    if previousHeight == nil {
                        // 新行首次被测量：admitted 集合可能因此扩张，走整表重建。
                        geometryStructureVersion &+= 1
                    } else if rounded != previousHeight {
                        // 已提交行变高/变矮：只登记这一行，提交时增量平移。
                        pendingGeometryDeltas[id] = rounded
                    }
                }
            }
            pendingHeights.removeAll()
            let wasResizing = viewportDirty
            resizingViewport = wasResizing
            if needsMeasurement { measureAll() }
            commitLayout(anchors: anchors, previous: previous)
            resizingViewport = false
            viewportDirty = false
        }
        applying = false
        publishDistance()
        checkPagination()
    }

    private func reconcile(_ input: StableChatScrollView, previous: ChatListSnapshot?) {
        let sample = ChatPerformanceRecorder.shared.begin()
        defer { ChatPerformanceRecorder.shared.finish(.reconcile, sample) }
        let snapshot = input.snapshot
        let environmentChanged = previous?.dynamicTypeSize != snapshot.dynamicTypeSize
            || previous?.colorScheme != snapshot.colorScheme
        // 单次遍历得到去重后的新 id 序列；不再为每个节拍重建全表字典。
        // 重复 id 会让一行拥有两份几何，保留首次出现。
        var newIDs: [String] = []
        newIDs.reserveCapacity(snapshot.items.count)
        var duplicated = false
        var seen = Set<String>(minimumCapacity: snapshot.items.count)
        for item in snapshot.items {
            if seen.insert(item.id).inserted { newIDs.append(item.id) } else { duplicated = true }
        }
        let leading = snapshot.olderOffset > 0 ? [Self.historyID] : []
        let trailing = snapshot.status.isVisible ? [Self.footerID] : []
        let delta = applyOrder(newIDs, leading: leading, trailing: trailing)
        if delta.structureChanged {
            // 只有行序结构变化才需要集合运算；纯内容更新零分配。
            committed = committed.filter { indexByID[$0] != nil }
            preparation.retain(Set(order))
            // 行序变化 → 帧下标整体前移/后移，提交时必须整表重算。
            geometryStructureVersion &+= 1
        }
        for id in delta.removed {
            dirty.remove(id); unmeasured.removeValue(forKey: id)
            releaseHost(id)
            heights.removeValue(forKey: id)
            pendingHeights.removeValue(forKey: id)
            costs.removeValue(forKey: id)
            itemByID.removeValue(forKey: id)
            // 行被移出：帧表必须整表重算（下标会整体前移）。
            geometryStructureVersion &+= 1
            pendingGeometryDeltas.removeValue(forKey: id)
        }
        // Middle reordering can leave the count and both endpoints unchanged.
        // Its surviving hosts stay mounted, but priority indices must move.
        if delta.structureChanged {
            preparationIndex.update(order: order)
        }
        if snapshot.olderOffset != previous?.olderOffset { requestedPage = nil }
        var visited = Set<String>()
        var messages = 0
        let recording = ChatPerformanceRecorder.shared.isRecording
        for item in snapshot.items {
            if duplicated, !visited.insert(item.id).inserted { continue }
            let contentChanged = itemByID[item.id] != item
            if contentChanged { itemByID[item.id] = item }
            if recording, case .message = item.row.kind { messages += 1 }
            if costs[item.id] == nil || contentChanged { costs[item.id] = renderCost(item) }
            let geometryChanged = heights[item.id] == nil || contentChanged
                || previous?.states[item.id] != snapshot.states[item.id]
                || previous?.dynamicTypeSize != snapshot.dynamicTypeSize
            let findChanged = previous?.findQuery != snapshot.findQuery
                || ((item.id == previous?.focusedRowID || item.id == snapshot.focusedRowID)
                    && (previous?.findOrdinal != snapshot.findOrdinal || previous?.focusedRowID != snapshot.focusedRowID))
            let deliveryChanged = item.row.delivery == .unconfirmed
                && (previous?.canResendPending != snapshot.canResendPending || previous?.pendingBusy != snapshot.pendingBusy)
            if geometryChanged || (mounted[item.id] != nil && (findChanged || deliveryChanged)) {
                enqueueMeasurement(item.id)
            } else if mounted[item.id] != nil,
                      previous?.actionsEnabled != snapshot.actionsEnabled
                          || previous?.capabilities != snapshot.capabilities || environmentChanged
                        || (previous?.focusedRowID != snapshot.focusedRowID
                            && (item.id == previous?.focusedRowID || item.id == snapshot.focusedRowID)) {
                preparation.enqueue(item.id)
            }
        }
        if snapshot.status.isVisible,
           heights[Self.footerID] == nil || previous?.status != snapshot.status || environmentChanged {
            costs[Self.footerID] = 65_536 + snapshot.status.reasoning.utf8.count * 8
            enqueueMeasurement(Self.footerID)
        }
        if snapshot.olderOffset > 0,
           heights[Self.historyID] == nil || previous?.loadingOlder != snapshot.loadingOlder
            || previous?.canLoadOlder != snapshot.canLoadOlder || environmentChanged {
            costs[Self.historyID] = 65_536
            enqueueMeasurement(Self.historyID)
        }
        // 规模 gauge 需要「消息」数量；只在采样时统计，未采样保持 0 且不改行为。
        loadedMessageCount = recording ? messages : 0
        trimGeometryCache()
        scheduleWork()
    }

    /// 增量维护 order / itemIDs / indexByID。返回被移除的 id 与结构是否变化。
    /// 纯追加或纯删除只处理尾部；历史前插或中间变化才重建该段之后的索引。
    private func applyOrder(_ newIDs: [String], leading: [String],
                            trailing: [String]) -> (removed: [String], structureChanged: Bool) {
        let wrapperChanged = leading != orderLeading || trailing != orderTrailing
        let change = ChatRowOrderChange(previous: itemIDs, next: newIDs, wrappersChanged: wrapperChanged)
        guard change.structureChanged else { return ([], false) }
        let start = change.firstChangedIndex
        let removed = change.removed
        for id in removed { indexByID.removeValue(forKey: id) }
        itemIDs = newIDs
        orderLeading = leading
        orderTrailing = trailing
        order = leading + itemIDs + trailing
        if wrapperChanged {
            indexByID = ChatPreparationQueue.indices(for: order)
        } else {
            let offset = leading.count
            if start < newIDs.count {
                for index in start..<newIDs.count { indexByID[newIDs[index]] = offset + index }
            }
            // 尾部哨兵（页脚）的位置随行数变化，必须跟随后移。
            for (index, id) in orderTrailing.enumerated() {
                indexByID[id] = offset + newIDs.count + index
            }
        }
        return (removed, true)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        memoryConstrained = true
        let viewport = Double(scrollView.bounds.height)
        let offset = Double(scrollView.contentOffset.y)
        let visible = Set(frames[ChatViewportLayout.intersecting(in: frames,
            lower: offset, upper: offset + viewport)].map(\.id))
        for id in Array(mounted.keys) where !visible.contains(id) {
            guard let row = mounted[id], row.host.presentedViewController == nil,
                  !hasActiveInteraction(row.host.view) else { continue }
            releaseHost(id, requeue: dirty.contains(id))
        }
        // No relayout, content-size mutation or offset adjustment on pressure.
    }

}
