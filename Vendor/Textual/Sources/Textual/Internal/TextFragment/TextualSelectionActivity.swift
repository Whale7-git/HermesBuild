import Combine
import Foundation

/// 记录当前是否有原生文本视图正持有一段选区。
///
/// 合并相邻段落会重建文本视图，选区随之消失。视图层据此把「结构切换」
/// 推迟到选区结束之后：选字过程中不改变块的分组。
@MainActor
public final class TextualSelectionActivity: ObservableObject {
  /// Read-only UITextView selection does not enter editing, and modern edit
  /// menus do not emit UIMenuController notifications. Scroll containers use
  /// this transition to invalidate their cached interaction/anchor state.
  public static let didChangeNotification = Notification.Name("TextualSelectionActivityDidChange")

  @Published public private(set) var isSelecting = false

  private var active: Set<ObjectIdentifier> = []

  public init() {}

  /// 只在汇总状态变化时发布，避免拖动选择时每帧都触发 SwiftUI 更新。
  func update(_ view: AnyObject, selecting: Bool) {
    let id = ObjectIdentifier(view)
    if selecting { active.insert(id) } else { active.remove(id) }
    let next = !active.isEmpty
    guard next != isSelecting else { return }
    isSelecting = next
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }
}
