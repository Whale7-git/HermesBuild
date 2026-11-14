import Foundation

/// 几何提交路径的选择。**纯决策，不碰 UIKit**。
///
/// 从 `ChatScrollController.refreshGeometry()` 里抽出来的那段 if/guard 链。
/// 抽出的理由：这是「跳一下」「卡住」这类 bug 的判定中枢，却因为方法体里
/// 夹着 `scrollView.bounds` 而完全无法离线测——1400 行滚动代码零覆盖。
///
/// 现在决策只看入参（版本号、视口高、待应用高度增量、底部留白、已提交帧），
/// 返回值是一个枚举，控制器照着执行即可。判定与执行分离后，每条分支都能断言。
enum ChatGeometryPlan: Equatable {
    /// 结构没变、也没有待应用增量：什么都不用做。
    case unchanged
    /// 整表重算一次。
    case rebuild
    /// 只改高度真正变化的已提交行，其后的行整体平移。
    case applyDeltas

    /// No allocated height dictionary on the hot streaming path. The caller
    /// supplies the already-maintained frame index to check delta membership.
    static func plan(structureChanged: Bool, bottomPadding: Double,
                     pendingIDs: [String], maxIncrementalRows: Int,
                     isCommitted: (String) -> Bool) -> ChatGeometryPlan {
        if structureChanged || bottomPadding > 0 { return .rebuild }
        guard !pendingIDs.isEmpty else { return .unchanged }
        guard pendingIDs.count <= maxIncrementalRows,
              pendingIDs.allSatisfy(isCommitted) else { return .rebuild }
        return .applyDeltas
    }

    /// 决定这次提交走哪条路。
    ///
    /// 顺序即优先级，每一条都对应一个曾经踩过的坑：
    ///
    /// 1. **结构变化**（行序 / 测量集合 / 视口高变了）→ 整表重建。
    ///    就地平移假设「行集合不变」，结构一变这个假设就破了。
    /// 2. **底部留白非零**（内容不足一屏）→ 整表重建。所有 top 都随留白平移，
    ///    就地更新会算错。
    /// 3. **没有待应用增量** → 什么都不做（最常见的空转路径）。
    /// 4. **变化行过多** → 整表重建。逐行平移会退化成 O(n²)：每改一行都要
    ///    扫一遍尾巴。超过阈值时两次线性扫描比一次平方便宜。
    /// 5. **变化行里有尚未进入已提交帧表的**（历史中间的空洞）→ 整表重建。
    ///    增量路径只能改已存在的行，覆盖不到缺失的行，硬走会丢掉这次高度。
    /// 6. **短会话收缩** → 仍可做增量更新：build151 已移除底部留白，
    ///    内容不足一屏时不再需要整表重排，避免产生无谓的滚动锚点调整。
    ///
    /// - Parameters:
    ///   - structureChanged: 行序、测量集合或视口高度是否变了。
    ///   - viewport: 当前视口高度。
    ///   - bottomPadding: 上次提交算出的底部留白（内容不足一屏时为正）。
    ///   - pendingDeltas: 待应用的高度增量（id → 新高度）。
    ///   - committedHeights: 已提交帧里每一行的高度（id → 高度）。
    ///   - contentBottom: 当前已提交内容的底部（最后一帧的 bottom）。
    ///   - maxIncrementalRows: 允许走增量路径的最大变化行数。
    static func plan(structureChanged: Bool,
                     viewport: Double,
                     bottomPadding: Double,
                     pendingDeltas: [String: Double],
                     committedHeights: [String: Double],
                     contentBottom: Double,
                     maxIncrementalRows: Int) -> ChatGeometryPlan {
        if structureChanged || bottomPadding > 0 { return .rebuild }
        guard !pendingDeltas.isEmpty else { return .unchanged }
        guard pendingDeltas.count <= maxIncrementalRows else { return .rebuild }
        // 有变化行还没有已提交高度：增量路径覆盖不到，交给整表重建。
        guard pendingDeltas.keys.allSatisfy({ committedHeights[$0] != nil }) else { return .rebuild }
        // Short conversations are top-aligned. Crossing the viewport-height
        // boundary no longer changes a global bottom spacer, so it must not
        // invalidate every measured row during streaming or tool disclosure.
        return .applyDeltas
    }
}
