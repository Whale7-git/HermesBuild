import SwiftUI
import UIKit

/// Uses the production editor without a model, API, persistence or send request.
struct ChatKeyboardTestView: View {
    @State private var draft = ""
    @State private var focused = false
    @State private var composing = false
    @State private var sent = 0
    @State private var events: [String] = []
    private var returnKeyMode: String { returnSends ? "发送" : "换行" }
    @AppStorage("chatReturnSends") private var returnSends = true

    private var canSubmit: Bool {
        !composing && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                Text("此页只在本地测试，不会发到聊天会话。连续输入时键盘应保持打开；换行键只应换行，发送键应让下方次数增加一次。记录只包含 Return 控制码、键盘类型和处理动作。")
                    .font(.subheadline)
                Toggle("回车键发送消息", isOn: $returnSends)
                ChatDraftEditor(text: $draft, focused: $focused, editable: true,
                    returnSends: returnSends, canSubmit: canSubmit,
                    onSubmit: { sent += 1; draft = "" },
                    onComposition: { composing = $0 }, onInputEvent: record)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 72, alignment: .top)
                    .padding(.vertical, 10)
            } header: { Text("输入区") }
            Section {
                LabeledContent("本地发送次数", value: "\(sent)")
                LabeledContent("当前行数", value: "\(draft.components(separatedBy: .newlines).count)")
                LabeledContent("输入状态", value: composing ? "正在选词" : (focused ? "输入中" : "已结束输入"))
                LabeledContent("回车键模式", value: returnKeyMode)
                LabeledContent("最近事件", value: events.first ?? "尚无")
                Button("复制测试记录") {
                    UIPasteboard.general.string = "Hermes \(AppTheme.version) (\(AppTheme.build)) · iOS \(UIDevice.current.systemVersion)\n本地发送次数：\(sent)\n" + events.joined(separator: "\n")
                }
            } header: { Text("结果") }
              footer: { Text("记录只含焦点变化、换行控制码和处理动作，不包含输入正文。复制后可用于反馈输入法兼容问题。") }
            if !events.isEmpty {
                Section("最近操作") {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        Text(event).font(.caption.monospaced())
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.canvas)
        .navigationTitle("键盘测试")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func record(_ event: String) {
        // Delegate callbacks can also occur during a UIKit/SwiftUI update.
        DispatchQueue.main.async {
            events.append(event)
            if events.count > 16 { events.removeFirst(events.count - 16) }
        }
    }
}
