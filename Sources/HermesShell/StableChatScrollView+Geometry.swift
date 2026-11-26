import SwiftUI
import UIKit

extension ChatScrollController {
    func captureAnchors() -> [ChatViewportLayout.Anchor] {
        ChatViewportLayout.anchors(in: frames, offset: Double(scrollView.contentOffset.y),
                                   viewport: Double(scrollView.bounds.height))
    }

    func commitLayout(anchors: [ChatViewportLayout.Anchor], previous: CGFloat) {
        let beforeCommitOffset = Double(scrollView.contentOffset.y)
        let geometrySample = ChatPerformanceRecorder.shared.begin()
        // .commitLayout 只含布局阶段：起点取宿主预布局（prepareBatch）与本次
        // 收尾中最早者。发布→提交现在是独立的 .publishToCommit 样本。
        let commitSample = commitPassSample ?? geometrySample
        commitPassSample = nil
        let publish = publishSample
        publishSample = nil
        refreshGeometry()
        for id in attached { position(id) }
        let viewport = Double(scrollView.bounds.height)
        let baseBottom = frames.last?.bottom ?? 0
        // A missing frame may only be a transient height measurement. A
        // missing transcript ID, however, must release its viewport reserve.
        if let id = turnReading.rowID, itemByID[id] == nil {
            turnReading.reset()
        }
        let focusedTop = turnReading.rowID.flatMap { frame(for: $0)?.top }
        let turnTarget = turnReading.target(
            contentBottom: baseBottom, rowTop: focusedTop, viewport: viewport,
            allowGrowth: !resizingViewport)
        scrollView.contentSize = CGSize(width: scrollView.bounds.width,
            height: turnReading.contentHeight(contentBottom: baseBottom, viewport: viewport))
        // New paragraphs may appear below a selected fragment while it holds
        // its own text stable. Preserve the reading anchor during that range
        // interaction, rather than moving the handles to the growing bottom.
        let selecting = hasSelectionInVisibleBand()
        let offset: Double
        if let turnTarget, !inMotion && !selecting {
            offset = turnTarget
        } else if !inMotion && !selecting && !policy.following
                    && turnReading.phase == .manualReading,
                  let anchor = manualTurnAnchor,
                  let frame = frame(for: anchor.id),
                  let retained = ChatManualTurnAnchor.target(
                      rowTop: frame.top, screenTop: anchor.screenTop,
                      contentHeight: Double(scrollView.contentSize.height), viewport: viewport) {
            // Preserve the user's measured question screen coordinate across
            // streaming reflow ABOVE the anchor, without controlling dragging.
            offset = retained
        } else {
            offset = resolvedOffset(anchors: anchors, previous: Double(previous),
                following: policy.following && navigationTarget == nil && !inMotion && !selecting)
        }
        // Do not reassign the same contentOffset on every streaming row
        // measurement. Reentrant UIKit scroll notifications can otherwise
        // feed SwiftUI's following state back into another geometry commit.
        // During a live drag/deceleration/interactive keyboard pan, UIScrollView
        // is authoritative; the pending layout is reconciled when motion ends.
        // UIKit can clamp contentOffset synchronously when contentSize changes.
        // Re-read the actual offset after resizing: comparing against the
        // pre-resize value can incorrectly skip restoring a manual anchor.
        let offsetAfterResize = Double(scrollView.contentOffset.y)
        publishScrollTrace(reason: "commit.beforeOffsetAssignment", resolvedTarget: offset,
                           anchorID: anchors.first?.id, beforeOffset: beforeCommitOffset,
                           offsetAfterResize: offsetAfterResize)
        if ChatOffsetCommitPolicy.shouldAssign(
            current: offsetAfterResize, target: offset, interacting: inMotion) {
            ChatPerformanceRecorder.shared.recordScrollAdjustment(
                reason: "commit", from: offsetAfterResize, to: offset,
                viewport: Double(scrollView.bounds.height),
                following: policy.following && navigationTarget == nil, moving: inMotion)
            scrollView.contentOffset = CGPoint(x: 0, y: offset)
        }
        publishScrollTrace(reason: "commit.afterOffsetAssignment", resolvedTarget: offset,
                           anchorID: anchors.first?.id, beforeOffset: beforeCommitOffset,
                           offsetAfterResize: offsetAfterResize)
        // 首次非空 frames 提交即首屏完成，且只上报一次。若首屏发生在开始采样
        // 之前（样本为 nil），同样置位，避免把后续流式更新误当首屏。
        if !hasReportedFirstPaint, !frames.isEmpty {
            hasReportedFirstPaint = true
            ChatPerformanceRecorder.shared.finish(.firstPaint, firstPaintSample)
            firstPaintSample = nil
        }
        ChatPerformanceRecorder.shared.finish(.geometryLayout, geometrySample)
        updateWindow()
        applyNavigationIfReady()
        ChatPerformanceRecorder.shared.finish(.commitLayout, commitSample)
        // 超过 1s 的「发布→提交」意味着中间夹着空闲等待（例如只有键盘引起的
        // 布局），不能算作提交延迟。
        if let publish, CACurrentMediaTime() - publish.time <= 1 {
            ChatPerformanceRecorder.shared.finish(.publishToCommit, publish)
        }
        ChatPerformanceRecorder.shared.sampleMemory()
    }

    /// 几何提交。分两条路：
    ///
    /// - 结构变化（行序、测量集合、底部留白变化）→ 整表重算一次。
    /// - 只有已提交行的高度变化 → 就地改这一行并平移其后的 top。
    ///
    /// 为什么改：原实现每次高度提交都做 `Set(heights.keys)`（2000 次哈希）、
    /// `admitted` 过滤、两次 2000 元素数组 map，再建一个 2000 项字典。
    /// 流式回答每秒提交数次，等于每秒分配上万个 Frame/元组。现在常见路径
    /// （正在流式的最后一行变高）只是改一个元素，尾部平移长度为零。
    private func refreshGeometry() {
        let viewport = Double(scrollView.bounds.height)
        // 判定逻辑抽到 `ChatGeometryPlan`（纯函数、可离线测），这里只负责取值与执行。
        // 原先这段 if/guard 链夹着 `scrollView.bounds`，导致 1400 行滚动代码
        // 零测试覆盖——「跳一下」「卡住」这类 bug 只能靠 watchdog 事后补救。
        let plan = ChatGeometryPlan.plan(
            structureChanged: committedGeometryVersion != geometryStructureVersion,
            bottomPadding: bottomPadding,
            pendingIDs: Array(pendingGeometryDeltas.keys),
            maxIncrementalRows: Self.maxIncrementalRows,
            isCommitted: { id in
                guard let index = frameIndexByID[id], index < frames.count else { return false }
                return frames[index].id == id
            })
        switch plan {
        case .unchanged: return
        case .rebuild: rebuildGeometry()
        case .applyDeltas: applyGeometryDeltas()
        }
    }

    /// 超过这个行数就直接整表重建。实测常见路径是 1 行（流式末条），
    /// 少量折叠/展开也只有个位数行。
    private static let maxIncrementalRows = 8

    private func rebuildGeometry() {
        let admitted = ChatPreparationQueue.admitted(order: order, measured: Set(heights.keys),
                                                     committed: committed)
        committed = Set(admitted)
        var rows: [ChatViewportLayout.Row] = []
        rows.reserveCapacity(admitted.count)
        for id in admitted {
            guard let height = heights[id] else { continue }
            rows.append(.init(id: id, height: Double(height)))
        }
        let raw = ChatViewportLayout.frames(for: rows)
        let viewport = Double(scrollView.bounds.height)
        geometryViewportHeight = viewport
        // Chat-first short histories begin at the reading origin, not at the
        // bottom of a blank viewport. Stream growth must not shift every old
        // row down by a synthetic bottom spacer.
        bottomPadding = 0
        frames = raw
        frameIndexByID = Dictionary(frames.enumerated().map { ($0.element.id, $0.offset) },
                                    uniquingKeysWith: { first, _ in first })
        committedGeometryVersion = geometryStructureVersion
        pendingGeometryDeltas.removeAll(keepingCapacity: true)
    }

    /// 只改高度真正变化的已提交行；其后的行整体平移。
    private func applyGeometryDeltas() {
        // 按下标从小到大处理，保证前面的平移已落定，后面只需再平移剩余量。
        let changed = pendingGeometryDeltas.compactMap { id, height -> (Int, Double)? in
            guard let index = frameIndexByID[id], index < frames.count,
                  frames[index].id == id else { return nil }
            let delta = Double(height) - frames[index].height
            guard abs(delta) > 0.01 else { return nil }
            return (index, delta)
        }.sorted { $0.0 < $1.0 }
        pendingGeometryDeltas.removeAll(keepingCapacity: true)
        guard !changed.isEmpty else { return }
        // One cumulative suffix pass is identical to repeatedly shifting
        // tails, but bounded to O(n + changedRows). Single-tail streaming
        // still touches only its final row.
        ChatViewportLayout.applyHeightDeltas(
            to: &frames, sortedChanges: changed.map { (index: $0.0, delta: $0.1) })
    }

    /// 与 `ChatViewportLayout.offset(after:frameByID:...)` 等价，但用下标表定位，
    /// 不再为每次提交构造一份 2000 项的 [String: Frame] 字典。
    private func resolvedOffset(anchors: [ChatViewportLayout.Anchor], previous: Double,
                                following: Bool) -> Double {
        // A focused turn can reserve space below the last measured row to keep
        // the user's question stable. Do not clamp a manual reading offset to
        // row-only height after streamed reply growth or the offset snaps.
        return ChatViewportLayout.readingOffset(anchors: anchors, previous: previous,
            contentHeight: Double(scrollView.contentSize.height),
            viewport: Double(scrollView.bounds.height), following: following,
            frameForID: { self.frame(for: $0) })
    }

    func position(_ id: String) {
        guard let frame = frame(for: id), let row = mounted[id] else { return }
        let rect = CGRect(x: 0, y: frame.top, width: Double(scrollView.bounds.width), height: frame.height)
        if row.host.view.frame != rect { row.host.view.frame = rect }
    }

    func frame(for id: String) -> ChatViewportLayout.Frame? {
        guard let index = frameIndexByID[id], index < frames.count, frames[index].id == id else { return nil }
        return frames[index]
    }
}
