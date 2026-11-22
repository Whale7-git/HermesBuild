import SwiftUI
import UIKit
import Textual

extension ChatScrollController {
    /// 这些事件是选中/菜单/编辑状态唯一的外部信号：命中后只需要在下一次查询
    /// 重新扫描一遍可见band，而不是每个滚动 tick 递归整棵宿主树。
    ///
    /// A-10：全部改成 block 观察并保存 token。原先 7 处 `addObserver(self, selector:)`
    /// 没有任何 `removeObserver`，也没有 `deinit`；而 `loadView` 在宿主重建/内存回收后
    /// 可能重入，于是同一通知会注册多份：进入后台重复写盘、每次编辑重复置脏并重复调度。
    func observeInteractionEvents() {
        removeObservers()
        let center = NotificationCenter.default
        let queue = OperationQueue.main
        func observe(_ name: Notification.Name, _ handler: @escaping () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: queue) { _ in handler() }
            notificationTokens.append(token)
        }
        // 进入后台：只落一次阅读位置（保持原 selector 的行为，不额外触发重排）。
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] in
            self?.persistReadingPosition()
        }
        observe(UITextView.textDidBeginEditingNotification) { [weak self] in
            self?.interactionEventOccurred()
        }
        // UIKit 没有「选区变化」通知；文本变化先置脏，真正需要暂停重排的时刻
        // （长按菜单出现、拖动、滚动开始）由下面的事件覆盖。
        observe(UITextView.textDidChangeNotification) { [weak self] in
            self?.interactionEventOccurred()
        }
        observe(UITextField.textDidBeginEditingNotification) { [weak self] in
            self?.interactionEventOccurred()
        }
        // UIMenuController 自 iOS 16 起被 UIEditMenuInteraction 取代；引用常量会
        // 触发废弃警告，这里按其通知原始名称监听。
        observe(Notification.Name("UIMenuControllerWillShowMenuNotification")) { [weak self] in
            self?.interactionEventOccurred()
        }
        observe(Notification.Name("UIMenuControllerDidHideMenuNotification")) { [weak self] in
            self?.interactionEventOccurred()
        }
        // The visible read-only text owns its selection directly. UIKit's
        // editing/legacy menu notifications alone miss these transitions.
        observe(TextualSelectionActivity.didChangeNotification) { [weak self] in
            self?.interactionEventOccurred()
        }
    }

    /// 注销全部通知观察者。deinit 与重复注册前都调用，保证幂等。
    private func removeObservers() {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens.removeAll()
    }

    @objc private func interactionEventOccurred() {
        interactionDirty = true
        selectionDirty = true
        // A selection can end after the last stream frame. Refresh the window
        // even then so pinned hosts and deferred following do not stay stale.
        scheduleFlush()
    }

    /// 置脏标记，让下一次查询重扫可见 band。
    ///
    /// 不是 `private`：`beginAnimatedJump` 的超时兜底在 `StableChatScrollView.swift`
    /// 里，跨文件访问需要模块内可见。同一类型拆成多个文件后，`private` 只对
    /// 声明所在文件生效。
    func markInteractionDirty() {
        interactionDirty = true
        selectionDirty = true
    }

    func enqueueMeasurement(_ id: String) {
        dirty.insert(id)
        if heights[id] == nil, unmeasured[id] == nil { unmeasured[id] = Date() }
        preparation.enqueue(id)
    }

    private func mount(id: String, content: AnyView, restoring: Bool) {
        generation &+= 1
        let token = generation
        // Even after width/font invalidation an evicted host starts with an
        // empty document. Keep its previous measured frame as a transition;
        // calibrate at the new width only after the queued document is ready.
        let restoring = heights[id] != nil && (restoring || mounted[id] == nil)
        let rendering = mounted[id]?.rendering ?? ChatRowRenderState()
        rendering.beginMount(token)
        rendering.onReadinessChange = { [weak self] in self?.scheduleWork() }
        rendering.update(ChatRenderContext(priority: interactionHosts.contains(id) ? .interactive
            : (visibleHosts.contains(id) ? .visible : .prefetch), isScrolling: inMotion, isActive: true))
        let root = ChatMeasuredContent(content: content, rendering: rendering, generation: token) { [weak self] height in
            self?.heightChanged(id: id, generation: token, height: height)
        }
        if let existing = mounted[id] {
            existing.generation = token
            existing.restoring = restoring
            existing.host.rootView = root
        } else {
            let sample = ChatPerformanceRecorder.shared.begin()
            defer { ChatPerformanceRecorder.shared.finish(.hostCreate, sample) }
            let host = UIHostingController(rootView: root)
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            host.view.clipsToBounds = true
            addChild(host)
            scrollView.addSubview(host.view)
            host.didMove(toParent: self)
            mounted[id] = MountedRow(host: host, rendering: rendering, generation: token, restoring: restoring)
            attached.insert(id)
        }
        ChatPerformanceRecorder.shared.hosts(mounted: mounted.count, attached: attached.count)
        accessClock &+= 1
        mounted[id]?.lastUse = accessClock
        if let row = mounted[id], row.host.view.superview == nil {
            scrollView.addSubview(row.host.view)
            attached.insert(id)
        }
        if frame(for: id) != nil { position(id) }
        else if let row = mounted[id] {
            // An offscreen staging surface has the real width, but contributes
            // nothing to frames/contentSize until a ready document is fitted.
            row.host.view.frame = CGRect(x: 0,
                y: max(scrollView.contentSize.height, scrollView.contentOffset.y + scrollView.bounds.height) + scrollView.bounds.height,
                width: scrollView.bounds.width, height: 1)
        }
        scheduleWork()
    }

    func measureAll() {
        guard scrollView.bounds.width > 0 else { needsMeasurement = true; return }
        // Old real measurements remain transitional geometry. No evicted host
        // is rebuilt here; the queue prioritizes the visible band in batches.
        pendingHeights.removeAll()
        // 首屏/换宽后的第一批测量：可见区及其上下各 2 行先进优先带，其余行
        // 仍按原来的 2 行/16ms 节奏补齐。不引入任何估算高度。
        measurementBand = visibleBandNeighbourhood()
        for id in order { enqueueMeasurement(id) }
        scheduleWork()
        needsMeasurement = false
    }

    /// Drop optional render-cost entries only. Actual scalar heights/frames
    /// must survive host eviction: deleting them collapses long history and
    /// makes an offscreen Find target unreachable. Reconcile removes geometry
    /// when its actual row leaves the model's bounded message window.
    func trimGeometryCache(keeping limit: Int = 400) {
        guard order.count > limit * 2 else { return }
        let keep = Set(order.suffix(limit))
        for id in costs.keys where !keep.contains(id) && !attached.contains(id) {
            costs.removeValue(forKey: id)
        }
    }

    /// 可见区上下各 2 行的 id。第一帧还没有 frames 时为空，此时沿用既有的
    /// 「跟随最新 → 底部优先」行为。
    private func visibleBandNeighbourhood() -> Set<String> {
        let offset = Double(scrollView.contentOffset.y)
        let viewport = max(1, Double(scrollView.bounds.height))
        let visible = ChatViewportLayout.intersecting(in: frames, lower: offset, upper: offset + viewport)
            .map { frames[$0].id }
        guard let first = visible.first, let last = visible.last,
              let low = indexByID[first], let high = indexByID[last] else { return [] }
        let lower = max(0, low - 2)
        let upper = min(order.count - 1, high + 2)
        guard lower <= upper else { return [] }
        return Set((lower...upper).map { order[$0] })
    }

    private func fittedHeight(_ row: MountedRow, width: CGFloat) -> CGFloat {
        let sample = ChatPerformanceRecorder.shared.begin()
        defer { ChatPerformanceRecorder.shared.finish(.rowMeasure, sample) }
        return roundedHeight(row.host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    func roundedHeight(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else { return 1 }
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        return max(1, ceil(height * max(1, scale)) / max(1, scale))
    }

    private func heightChanged(id: String, generation: UInt64, height: CGFloat) {
        guard attached.contains(id), let row = mounted[id], row.generation == generation,
              height.isFinite, height > 0 else { return }
        let height = roundedHeight(height)
        if preparation.active.contains(id) || dirty.contains(id) || !row.rendering.isReadyForMeasurement {
            scheduleWork()
            return
        }
        guard abs((pendingHeights[id] ?? heights[id] ?? 1) - height) > 0.25 else { return }
        pendingHeights[id] = height
        // Geometry callbacks run INSIDE SwiftUI layout. Never recurse into
        // UIKit layout or update the SwiftUI parent from this callback.
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.flush()
        }
    }

    func scheduleWork() {
        guard !workScheduled else { return }
        workScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self else { return }
            self.workScheduled = false
            self.prepareBatch()
        }
    }

    private func preparationPriority() -> [String] {
        let pivot = navigationTarget?.targetID ?? (policy.following ? nil : captureAnchors().first?.id)
        // 优先带只对尚未测量的行生效，量完即退出，不长期抢占调度顺序。
        if !measurementBand.isEmpty { measurementBand = measurementBand.filter { heights[$0] == nil } }
        var local = wantedHosts.union(visibleHosts).union(interactionHosts).union(measurementBand)
        if let target = navigationTarget?.targetID { local.insert(target) }
        let localPriority = preparationIndex.priority(candidates: local, pivot: pivot)
        if inMotion { return localPriority }
        let remainder = preparationIndex.priority(
            candidates: preparation.queued.union(preparation.active).subtracting(local), pivot: pivot)
        return localPriority + remainder
    }

    func prepareBatch() {
        guard current != nil, scrollView.bounds.width > 0 else { return }
        let priorities = preparationPriority()
        // Admission and fitting have independent per-turn limits. A row waiting
        // on a worker keeps its bounded slot until a readiness event or suspend.
        for id in preparation.take(prioritized: priorities, limit: 2) {
            recreate(id, restoring: heights[id] != nil)
        }
        let ready = priorities.filter {
            preparation.active.contains($0) && !preparation.queued.contains($0)
                && attached.contains($0) && mounted[$0]?.rendering.isReadyForMeasurement == true
        }
        if inMotion {
            // An unchanged restored row can show its ready document in the old
            // exact frame. Dirty geometry waits until UIKit releases the offset.
            for id in ready where !dirty.contains(id) { preparation.finish(id) }
        } else {
            var layoutTimingStarted = false
            for id in ready.prefix(2) {
                guard let row = mounted[id] else { continue }
                if !layoutTimingStarted {
                    layoutTimingStarted = true
                    // 这段宿主布局此前完全未计时。样本从这里起，commitLayout
                    // 收尾时并入同一个 .commitLayout 样本（含 layoutIfNeeded）。
                    commitPassSample = ChatPerformanceRecorder.shared.begin()
                }
                row.host.view.setNeedsLayout()
                row.host.view.layoutIfNeeded()
                guard row.rendering.isReadyForMeasurement else { continue }
                pendingHeights[id] = fittedHeight(row, width: scrollView.bounds.width)
                dirty.remove(id)
                row.restoring = false
                preparation.finish(id)
            }
            if !pendingHeights.isEmpty { flush() }
            if commitPassSample != nil {
                // flush() 未走到 commitLayout（例如内容没变），单独记录本次宿主布局。
                ChatPerformanceRecorder.shared.finish(.commitLayout, commitPassSample)
                commitPassSample = nil
            }
        }
        let moreReady = !inMotion && preparation.active.contains {
            !preparation.queued.contains($0) && attached.contains($0)
                && mounted[$0]?.rendering.isReadyForMeasurement == true
        }
        if moreReady || preparation.canTake(from: preparationPriority()) { scheduleWork() }
    }

    func updateWindow() {
        let sample = ChatPerformanceRecorder.shared.begin()
        defer { ChatPerformanceRecorder.shared.finish(.window, sample) }
        let viewport = Double(scrollView.bounds.height)
        guard viewport > 0 else { return }
        let offset = Double(scrollView.contentOffset.y)
        // Search only the local frame band. Scroll work is independent of the
        // number of cached heights; the controller cache itself is bounded.
        let visibleRange = ChatViewportLayout.intersecting(in: frames,
            lower: offset, upper: offset + viewport)
        let range = ChatViewportLayout.intersecting(in: frames,
            lower: offset - viewport * 1.5, upper: offset + viewport * 2.5)
        let visible = Set(frames[visibleRange].map(\.id))
        // Selection and menus own their view until the interaction ends.
        let interacting = activeInteractionHosts()
        let required = visible.union(interacting)
        let centre = offset + viewport / 2
        let candidates = frames[range].sorted {
            abs(($0.top + $0.bottom) / 2 - centre) < abs(($1.top + $1.bottom) / 2 - centre)
        }.map { budgetEntry($0.id) }
        let wanted = ChatRenderBudget.window(required: required.map(budgetEntry), candidates: candidates,
            limits: .init(count: memoryConstrained ? 16 : 32, cost: memoryConstrained ? 4_194_304 : 12_582_912))
        wantedHosts = wanted
        visibleHosts = visible
        interactionHosts = interacting
        // Keep pending staging hosts attached while idle, independently of an
        // arbitrary warm-up deadline. During a fling only the current band is
        // useful; suspended work goes back to the queue and restarts on demand.
        for id in Array(preparation.active) where inMotion && !wanted.contains(id) {
            releaseHost(id, requeue: dirty.contains(id))
        }
        let attachedIDs = wanted.union(preparation.active)
        for id in attached.subtracting(attachedIDs) {
            guard let row = mounted[id] else { continue }
            row.host.view.removeFromSuperview()
            attached.remove(id)
        }
        for id in wanted {
            if mounted[id] == nil { preparation.enqueue(id); continue }
            guard let row = mounted[id] else { continue }
            // Set the cached frame before entering the hierarchy. Late height
            // refinements wait until scrolling ends, preserving the anchor.
            if !attached.contains(id) {
                position(id)
                scrollView.addSubview(row.host.view)
                attached.insert(id)
            }
            if visible.contains(id) {
                accessClock &+= 1
                row.lastUse = accessClock
            }
        }
        for (id, row) in mounted {
            row.rendering.update(ChatRenderContext(
                priority: interacting.contains(id) ? .interactive : (visible.contains(id) ? .visible : .prefetch),
                isScrolling: inMotion, isActive: attachedIDs.contains(id)))
        }
        let evictions = ChatRenderBudget.victims(in: mounted.map { id, _ in budgetEntry(id) },
            keeping: attachedIDs,
            limits: .init(count: memoryConstrained ? 24 : 48, cost: memoryConstrained ? 8_388_608 : 16_777_216))
        for id in evictions { releaseHost(id) }
        ChatPerformanceRecorder.shared.hosts(mounted: mounted.count, attached: attached.count)
        publishGauges()
        resumePreparationIfNeeded()
    }

    /// 规模 gauge 只在采集中计算并写入；未采样时只做一次布尔判断。
    private func publishGauges() {
        let recorder = ChatPerformanceRecorder.shared
        guard recorder.isRecording else { return }
        recorder.gauges(loadedRows: order.count, loadedMessages: loadedMessageCount,
                        measuredHeights: heights.count)
    }

    /// Rows that finished parsing during a drag are still dirty: an empty queue
    /// must not strand them. Scroll-end callbacks reach here through flush(), so
    /// an idle measurement pass resumes even when nothing new was enqueued.
    private func resumePreparationIfNeeded() {
        guard !inMotion else { return }
        if !preparation.queued.isEmpty || preparation.active.contains(where: { dirty.contains($0) }) {
            scheduleWork()
        }
    }

    private func budgetEntry(_ id: String) -> ChatRenderBudget.Entry {
        .init(id: id, cost: costs[id] ?? 65_536, lastUse: mounted[id]?.lastUse ?? 0)
    }

    func renderCost(_ item: ChatRowItem) -> Int {
        // Weight attributed text/layout storage plus a fixed host allowance.
        // This is a cache admission weight, not an assertion of exact RAM use.
        let bytes: Int
        switch item.row.kind {
        case .message(let message): bytes = message.content.utf8.count
        case .tools(let tools): bytes = tools.reduce(0) { $0 + $1.args.utf8.count + $1.result.utf8.count }
        case .process(let group):
            bytes = group.messages.reduce(0) { $0 + $1.content.utf8.count }
                + group.tools.reduce(0) { $0 + $1.args.utf8.count + $1.result.utf8.count }
        case .notice(let notice): bytes = notice.message.utf8.count
        case .day, .time: bytes = 0
        }
        return 65_536 + bytes * 8
    }

    /// 「加载更早」按钮的文案。上限与加载中互斥，两者都优先于默认文案。
    private func historyLabel(_ snapshot: ChatListSnapshot) -> String {
        if snapshot.loadingOlder { return "加载更早的消息…" }
        if snapshot.olderLimitReached {
            // 与 NativeChatModel 写入的 notice 同口径，避免同一件事两套说法。
            return "已到本地历史窗口上限，更早内容可用「导出 Markdown」查看"
        }
        return "加载更早的消息"
    }

    private func recreate(_ id: String, restoring: Bool) {
        guard let input = current else { return }
        if let item = itemByID[id] {
            mount(id: id, content: input.row(item), restoring: restoring)
        } else if id == Self.footerID {
            mount(id: id, content: input.footer(), restoring: restoring)
        } else if id == Self.historyID {
            // Reuse the same builder used by snapshot reconciliation.
            let snapshot = input.snapshot
            mount(id: id, content: AnyView(
                Button { [weak self] in self?.current?.onLoadOlder() } label: {
                    HStack(spacing: 8) {
                        if snapshot.loadingOlder { ProgressView().controlSize(.small) }
                        // 到上限时说清「没有更多」，不要只把按钮禁掉——禁用态下
                        // 用户会反复点，看到的是「点了没反应」，与「加载失败」分不开。
                        Text(historyLabel(snapshot))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.plain).disabled(!snapshot.canLoadOlder || snapshot.loadingOlder)
            ), restoring: restoring)
        }
    }

    func releaseHost(_ id: String, requeue: Bool = false) {
        guard let row = mounted.removeValue(forKey: id) else { return }
        row.rendering.onReadinessChange = nil
        row.rendering.update(ChatRenderContext(priority: .background, isActive: false))
        row.host.willMove(toParent: nil)
        row.host.view.removeFromSuperview()
        row.host.removeFromParent()
        attached.remove(id)
        if requeue || dirty.contains(id) { preparation.suspend(id) }
        else { preparation.remove(id) }
        // Heights, item identity and fold state survive this release. A stale
        // geometry callback is ignored using the host's generation token.
    }

    private func hasSelectedText(_ candidate: UIView) -> Bool {
        if let text = candidate as? any UITextInput, let range = text.selectedTextRange, !range.isEmpty { return true }
        return candidate.subviews.contains { hasSelectedText($0) }
    }

    func hasActiveInteraction(_ candidate: UIView) -> Bool {
        if candidate.isFirstResponder { return true }
        // Textual uses its own UIView conforming to UITextInput, not UITextView.
        if let text = candidate as? any UITextInput, let range = text.selectedTextRange, !range.isEmpty { return true }
        if candidate.interactions.contains(where: {
            ($0 as? UIContextMenuInteraction).map { $0.menuAppearance != .unknown } ?? false
        }) { return true }
        if candidate.gestureRecognizers?.contains(where: { $0.state == .began || $0.state == .changed }) == true {
            return true
        }
        return candidate.subviews.contains(where: hasActiveInteraction)
    }

    /// 缓存查询：未置脏时直接返回上次结果。置脏后才扫描一次可见band（外加
    /// 上一轮仍在交互的宿主，保证菜单/选中不会因为轻微滚出而丢宿主）。
    private func activeInteractionHosts() -> Set<String> {
        var result = Set<String>()
        for id in attached where mounted[id]?.host.presentedViewController != nil {
            result.insert(id)
        }
        if interactionDirty {
            interactionDirty = false
            var found = Set<String>()
            for id in visibleHosts.union(interactionHosts).union(result) {
                guard let row = mounted[id], hasActiveInteraction(row.host.view) else { continue }
                found.insert(id)
            }
            cachedInteractionHosts = found
        }
        return result.union(cachedInteractionHosts.intersection(attached))
    }

    /// 选中文字会阻止跟随最新消息重排；同样只在事件之后扫描一次。
    func hasSelectionInVisibleBand() -> Bool {
        guard selectionDirty else { return cachedSelectionActive }
        selectionDirty = false
        cachedSelectionActive = visibleHosts.union(interactionHosts).contains { id in
            guard let row = mounted[id] else { return false }
            return hasSelectedText(row.host.view)
        }
        return cachedSelectionActive
    }

    func withoutAnimations(_ action: () -> Void) {
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            action()
            CATransaction.commit()
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        let velocity = scrollView.panGestureRecognizer.velocity(in: scrollView)
        horizontalBackPan = ChatBackAxisPolicy.claimsReturn(
            horizontal: Double(velocity.x), vertical: Double(velocity.y))
        // Horizontal card navigation is not a user request to read history.
        // It must not detach the current streaming turn, rebuild visible
        // hosts, or persist a shifted reading anchor.
        if horizontalBackPan { return }
        // 用户按下即打断程序化动画：统一走 endAnimatedJump，顺带取消兜底计时器。
        endAnimatedJump()
        navigationTarget = nil
        navigationDetached = false
        turnReading.userBeganReading()
        // A short pan must not hand the new streamed row back to its
        // bottom-following owner immediately after finger release.
        policy.beginManualReading()
        publishDistance()
        current?.onUserScroll()
        hasInteracted = true
        markInteractionDirty()
        updateWindow()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !applying, !horizontalBackPan else { return }
        // No measurement, timeline rebuild, or content-geometry changes here.
        updateWindow()
        let distance = max(0, scrollView.contentSize.height - scrollView.bounds.height - scrollView.contentOffset.y)
        // UIKit sends this delegate for keyboard reflow, row measurement
        // and programmatic offset correction as well as finger scrolling.
        // Only a genuine vertical pan/deceleration can change follow intent.
        if navigationTarget == nil && !navigationDetached,
           ChatScrollState.isUserScroll(
               tracking: scrollView.isTracking, dragging: scrollView.isDragging,
               decelerating: scrollView.isDecelerating,
               horizontalBackPan: horizontalBackPan,
               animatedJump: animatedJump, resizingViewport: resizingViewport) {
            // Scroll pan translation, not a programmatic offset correction,
            // supplies the intent to return to latest. A downward finger
            // swipe (reading earlier) remains detached even near the bottom.
            let fingerTravel = scrollView.panGestureRecognizer.translation(in: scrollView).y
            let hadReadingOwnership = !policy.following
            policy.updateDuringManualDrag(
                distanceFromBottom: Double(distance),
                movingTowardLatest: fingerTravel < -12
            )
            if hadReadingOwnership && policy.following {
                // The user intentionally returned to the newest reply.
                // Retire the temporary question-top reserve, otherwise it
                // leaves blank scrollable space after the answer finishes.
                turnReading.reset()
            }
        }
        publishDistance()
        checkPagination()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if horizontalBackPan {
            horizontalBackPan = false
            return
        }
        markInteractionDirty()
        if !decelerate { scheduleFlush(); persistReadingPosition() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        horizontalBackPan = false
        markInteractionDirty()
        scheduleFlush(); persistReadingPosition()
    }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        endAnimatedJump()
        markInteractionDirty()
        flush()
        publishDistance()
        persistReadingPosition()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        // Treat the status-bar animation like a user scroll, deferring content
        // mutations until UIKit reports it has finished.
        guard scrollView.contentOffset.y > 0 else { return false }
        beginAnimatedJump()
        navigationTarget = nil
        navigationDetached = false
        // Tapping the status bar is a deliberate reading gesture, just like
        // dragging the transcript. Do not let the still-active streamed turn
        // recapture the scroll offset on the next Markdown/tool measurement.
        turnReading.userBeganReading()
        policy.update(distanceFromBottom: ChatScrollState.detachThreshold + 1)
        current?.onUserScroll()
        hasInteracted = true
        markInteractionDirty()
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        endAnimatedJump()
        scheduleFlush()
        checkPagination()
        persistReadingPosition()
    }

    func publishDistance() {
        guard !publishingDistance else { return }
        publishingDistance = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishingDistance = false
            guard self.navigationTarget == nil else { return }
            let distance = max(0, self.scrollView.contentSize.height - self.scrollView.bounds.height
                               - self.scrollView.contentOffset.y)
            // This asynchronous callback can follow a keyboard/viewport resize,
            // with no user pan. Never allow it to reattach a detached reader.
            // The genuine scroll delegate above still controls reattachment.
            let reported = ChatScrollState.geometryReportedDistance(
                Double(distance), following: self.policy.following,
                navigationDetached: self.navigationDetached)
            self.policy.update(distanceFromBottom: reported)
            self.current?.onDistance(reported)
        }
    }

    func checkPagination() {
        guard let snapshot = current?.snapshot, hasInteracted else { return }
        if scrollView.contentOffset.y > 300 { requestedPage = nil; return }
        // 未测量行不再无条件阻塞：等够宽限时间就放行（见 ChatPaginationGate）。
        guard scrollView.contentOffset.y < 180,
              ChatPaginationGate.allowsAutoLoad(unmeasured: unmeasured, now: Date(),
                                                canLoadOlder: snapshot.canLoadOlder,
                                                loadingOlder: snapshot.loadingOlder,
                                                olderOffset: snapshot.olderOffset,
                                                requestedPage: requestedPage) else { return }
        requestedPage = snapshot.olderOffset
        DispatchQueue.main.async { [weak self] in self?.current?.onLoadOlder() }
    }

    // MARK: - 翻页端到端埋点（由视图层成对调用）

    /// 发起「加载更早」时调用一次。未开始采样时 begin() 返回 nil，零分配。
    func notePaginationBegan() {
        guard paginationSample == nil else { return }
        paginationSample = ChatPerformanceRecorder.shared.begin()
    }

    /// 更早的消息提交并完成布局后调用一次；没有对应 begin 时直接返回。
    func notePaginationEnded() {
        guard let sample = paginationSample else { return }
        paginationSample = nil
        ChatPerformanceRecorder.shared.finish(.pagination, sample)
    }

    func applyNavigationIfReady() {
        guard let command = navigationTarget, let id = command.targetID,
              let frame = frame(for: id), !dirty.contains(id), !inMotion else { return }
        if command.focusTurn {
            // Wait for a real measured message row, not optimistic text size.
            let viewport = Double(scrollView.bounds.height)
            guard viewport > 0 else { return }
            turnReading.focus(rowID: id, rowTop: frame.top,
                              contentBottom: frames.last?.bottom ?? 0,
                              viewport: viewport)
            navigationTarget = nil
            navigationDetached = false
            policy.jumpToLatest()
            let bottom = frames.last?.bottom ?? 0
            scrollView.contentSize = CGSize(width: scrollView.bounds.width,
                height: turnReading.contentHeight(contentBottom: bottom, viewport: viewport))
            scrollView.setContentOffset(CGPoint(x: 0,
                y: turnReading.target(contentBottom: bottom, rowTop: frame.top,
                                      viewport: viewport) ?? frame.top),
                animated: false)
            updateWindow()
            publishDistance()
            return
        }
        var within = command.offsetInRow
        if let ordinal = command.findOrdinal {
            guard let row = mounted[id], row.rendering.isReadyForMeasurement else {
                retryFind(command); return
            }
            row.host.view.layoutIfNeeded()
            guard let (text, rect) = ChatFindGeometry.occurrence(ordinal, in: row.host.view) else {
                retryFind(command); return
            }
            ChatFindGeometry.revealHorizontally(rect, in: text, stoppingAt: row.host.view)
            let local = text.convert(rect, to: row.host.view)
            within = min(max(0, Double(local.minY) - Double(scrollView.bounds.height) * 0.25),
                         max(0, frame.height - 1))
        }
        guard
              let offset = ChatViewportLayout.navigationOffset(in: frames, id: id,
                offsetInRow: within, viewport: Double(scrollView.bounds.height),
                measurementPending: !unmeasured.isEmpty) else { return }
        navigationTarget = nil
        scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        updateWindow()
        publishDistance()
    }

    private func retryFind(_ command: ChatScrollCommand) {
        guard !findRetryScheduled else { return }
        guard findRetries < 40 else {
            navigationTarget = nil
            current?.onFindLocationUnavailable?()
            return
        }
        findRetries += 1
        findRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.findRetryScheduled = false
            // An older timer may wake after a new query. Drive only the
            // current target so the successor cannot lose its retry wakeup.
            guard self.navigationTarget != nil else { return }
            self.applyNavigationIfReady()
        }
    }

    func cancelFindNavigation() {
        if navigationTarget?.findOrdinal != nil { navigationTarget = nil }
    }

    /// Snapshot the *visible* row and row-relative offset without persisting it.
    /// Search uses this transient value so an exploratory jump cannot overwrite
    /// the normal resume bookmark of this conversation.
    func captureCurrentReadingPosition() -> ChatReadingPosition? {
        guard navigationTarget == nil, let anchor = captureAnchors().first(where: {
            itemByID[$0.id] != nil
        }) else { return nil }
        return ChatReadingPosition(rowID: anchor.id,
            offsetInRow: max(0, anchor.offsetInRow),
            following: policy.following && !navigationDetached)
    }

    @objc func persistReadingPosition() {
        guard let position = captureCurrentReadingPosition() else { return }
        current?.onReadingPosition(position)
    }

    @objc func backgroundTapped() { current?.onBackgroundTap() }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 手指落下即可能改变选中/菜单状态：只置脏，真正扫描推迟到查询时。
        markInteractionDirty()
        // Let buttons, text selection, links and context menus own their touches.
        var target = touch.view
        while let candidate = target, candidate !== scrollView {
            // Textual's selectable overlay is a custom UIView conforming to
            // UITextInput. It owns taps just as UITextView/the composer do.
            if candidate is UIControl || candidate is any UITextInput { return false }
            target = candidate.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
