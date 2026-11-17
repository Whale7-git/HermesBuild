import Foundation
import SwiftUI
import UIKit

/// F-45：路由的身份不能只有 `sessionID`。
///
/// 服务端会话 ID 在切实例、换账号（账号域轮换）之后可能被复用，而 SwiftUI 的
/// `navigationDestination(for:)` 只用 `Hashable` 值判断「是不是同一页」。只按
/// sessionID 比较时，切换后端/账号后会复用上一作用域已经挂载的视图（连同它持有的
/// api、草稿、历史缓存引用）。这里把作用域一并纳入相等性/哈希，让旧作用域的路由
/// 与新作用域的路由天然不相等，`NavigationStack` 必须重建目标视图。
///
/// 作用域值来自 `ChatRouteScope.current`（由 AppState 在切实例、退账号、
/// 清缓存时写入），所以既有的 `ChatRoute(sessionID:)` 调用点无需改动。
struct ChatRoute: Hashable {
    let sessionID: String
    /// `instanceID + accountScope + activeChangeToken` 的快照，见 `ChatRouteScope`。
    let scope: String

    init(sessionID: String, scope: String = ChatRouteScope.current) {
        self.sessionID = sessionID
        self.scope = scope
    }
}

/// 进程内「当前路由作用域」快照。只由 `AppState` 在作用域真正变化时写入。
///
/// 用锁而不是 `@MainActor`：`ChatRoute(sessionID:)` 的默认参数可能在非隔离上下文
/// 求值（例如 SwiftUI 的 diffing 代码路径），这里必须是无隔离可读的。
/// 值放在 `static let` 的盒子里，避免可变全局状态触发并发检查告警。
enum ChatRouteScope {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""

        var current: String {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private static let box = Box()

    static var current: String {
        get { box.current }
        set { box.current = newValue }
    }
}

/// 页面隐藏了系统导航栏（聊天页有自己的头部），这会让 UIKit 关掉
/// `interactivePopGestureRecognizer`。这里只做一件事：把它重新打开，
/// 并且只在栈深 > 1 时允许触发，避免在列表页边缘右滑把栈拉空导致假死。
struct NavigationPopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Controller() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            install()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        private func install() {
            guard let nav = navigationController ?? parent?.navigationController else { return }
            let gesture = nav.interactivePopGestureRecognizer
            gesture?.isEnabled = true
            gesture?.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let nav = navigationController, nav.viewControllers.count > 1 else { return false }
            // Replacing UIKit's default delegate must retain its transition
            // guard: a second edge pan cannot begin during an ongoing push/pop.
            return nav.transitionCoordinator == nil
        }
    }
}

/// Lightweight in-conversation navigation. It reads the already loaded
/// transcript and asks the existing scroll controller to reveal an exact row.
/// The sheet contains no text editing or network work.
struct ChatNavigationView: View {
    let nodes: [ChatNavigationNode]
    var canLoadOlder = false
    var onLoadOlder: (() async -> Void)? = nil
    let onSelect: (String) -> Void
    let onLatest: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var loadingOlder = false

    @State private var selectedKind: ChatNavigationKind?

    private var filtered: [ChatNavigationNode] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return nodes.filter {
            (selectedKind == nil || $0.kind == selectedKind)
                && (needle.isEmpty || $0.preview.localizedCaseInsensitiveContains(needle))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onLatest()
                        dismiss()
                    } label: {
                        Label("回到最新消息", systemImage: "arrow.down.to.line")
                            .frame(minHeight: 44)
                    }
                }

                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            kindChip("全部", kind: nil, count: nodes.count)
                            ForEach(ChatNavigationKind.allCases) { kind in
                                let count = nodes.filter { $0.kind == kind }.count
                                if count > 0 { kindChip(kind.title, kind: kind, count: count) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("关键节点 · \(filtered.count)") {
                    if filtered.isEmpty {
                        ContentUnavailableView(
                            "没有匹配的关键节点",
                            systemImage: "text.magnifyingglass",
                            description: Text(query.isEmpty
                                ? "当前已加载消息中没有此类节点，可继续加载更早历史。"
                                : "试试其他关键词，或加载更早历史。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 130)
                        .listRowBackground(Color.clear)
                    }
                    ForEach(filtered) { node in
                        Button {
                            onSelect(node.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label {
                                    Text(node.preview)
                                } icon: {
                                    Image(systemName: node.kind.icon)
                                }
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(3)
                                if let stamp = node.timestamp {
                                    Text(ChatPresentation.timeLabel(
                                        Date(timeIntervalSince1970: stamp)))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("定位到\(node.kind.title)：\(node.preview)")
                    }
                }

                Section {
                    if canLoadOlder, let onLoadOlder {
                        Button {
                            guard !loadingOlder else { return }
                            loadingOlder = true
                            Task {
                                await onLoadOlder()
                                loadingOlder = false
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if loadingOlder {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "clock.arrow.circlepath")
                                }
                                Text(loadingOlder ? "正在加载更早问题…" : "加载更早问题")
                                Spacer()
                            }
                            .frame(minHeight: 44)
                        }
                        .disabled(loadingOlder)
                    } else {
                        Label("已包含当前会话可加载的全部关键节点",
                              systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("导航范围")
                } footer: {
                    Text("列出已加载的问题、最终回答、工具过程和异常终态；加载更早消息后会继续出现。")
                }
            }
            .searchable(text: $query, prompt: "查找问题")
            // Empty state is inside its Section, never above navigation actions.
            .navigationTitle("消息导航")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func kindChip(_ title: String, kind: ChatNavigationKind?, count: Int) -> some View {
        Button {
            selectedKind = kind
        } label: {
            Text("\(title) \(count)")
                .font(.caption.weight(selectedKind == kind ? .semibold : .regular))
                .foregroundStyle(selectedKind == kind ? AppTheme.onAction : Color.secondary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(selectedKind == kind ? AppTheme.action : AppTheme.softFill, in: Capsule())
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedKind == kind ? .isSelected : [])
    }
}
