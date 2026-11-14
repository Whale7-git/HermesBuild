import SwiftUI
import UIKit

/// Local fixtures only: no chat model, network service, draft or disk storage.
struct MarkdownRenderCheckView: View {
    @State private var report = "尚未运行"
    @State private var checking = false
    @State private var source = ""
    @State private var playing = false
    @State private var playback: Task<Void, Never>?
    @State private var checkTask: Task<Void, Never>?
    @State private var fixture = Fixture.mixed

    private enum Fixture: String, CaseIterable, Identifiable {
        case mixed = "段落与代码", longReply = "长回复", longParagraph = "超长单段", complex = "复杂 Markdown"
        case listLayout = "编号列表对齐"
        var id: String { rawValue }
    }
    private static let example = """
    ## 本地流式示例

    这段文字逐步出现。长按当前段落直接拖动手柄选择和复制，不再弹出面板。

    ```swift
    let greeting = "你好，Hermes"
    print(greeting)
    ```

    已完成的内容保持在上方，接着生成列表与表格：

    - 第一项
    - 第二项

    | 项目 | 状态 |
    | --- | --- |
    | 本地示例 | 完成 |
    """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("使用内置内容检查 Markdown 语义、流式排版和原地选字。独立段落、代码块和表格单元格各自选择；不会向会话发送消息。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    checking = true
                    checkTask = Task {
                        let worker = Task.detached(priority: .utility) { await ChatMarkdownWorker.diagnostic() }
                        let result = await withTaskCancellationHandler {
                            await worker.value
                        } onCancel: { worker.cancel() }
                        guard !Task.isCancelled else { return }
                        report = result
                        checking = false
                    }
                } label: {
                    HStack {
                        Text(checking ? "正在检查…" : "运行语义检查")
                        if checking { ProgressView() }
                    }.frame(minHeight: 44)
                }
                .disabled(checking)
                Text(report).font(.caption.monospaced()).textSelection(.enabled)
                Button("复制检查结果") {
                    UIPasteboard.general.string = "Hermes \(AppTheme.version) (\(AppTheme.build))\n" + report
                }
                Divider()
                Picker("固定本地示例", selection: $fixture) {
                    ForEach(Fixture.allCases) { Text($0.rawValue).tag($0) }
                }
                Button(playing ? "停止本地示例" : "播放本地流式示例") {
                    if playing { playback?.cancel(); playing = false }
                    else { startPlayback() }
                }.frame(minHeight: 44)
                if !source.isEmpty {
                    NativeMarkdownView(text: source, cacheable: !playing)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppTheme.canvas)
        .navigationTitle("渲染检查")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: fixture) { _, _ in
            playback?.cancel(); playing = false; source = ""
        }
        .onDisappear {
            playback?.cancel(); playing = false
            checkTask?.cancel(); checking = false
        }
    }

    private func startPlayback() {
        source = ""
        playing = true
        playback = Task {
            let example = Self.example(for: fixture)
            let characters = Array(example)
            let step = max(8, min(256, characters.count / 120))
            for end in stride(from: step, to: characters.count, by: step) {
                guard !Task.isCancelled else { return }
                source = String(characters.prefix(end))
                do { try await Task.sleep(nanoseconds: 50_000_000) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            source = example
            playing = false
        }
    }

    private static func example(for fixture: Fixture) -> String {
        switch fixture {
        case .mixed: return example
        case .longReply:
            return (0..<120).map { index in
                "## 固定段落 \(index + 1)\n\n" + String(repeating: "已完成前文保持稳定，支持当前段落内选择。", count: 8)
                    + "\n\n```swift\nlet value = \(index)\n```\n\n"
            }.joined()
        case .longParagraph:
            return String(repeating: "这是没有段落边界的本地长文本，包含中文、English 与表情🙂。", count: 600)
        case .complex:
            return example + "\n\n> 固定引用\n>\n> - 嵌套列表 **粗体**\n> - [引用链接][local]\n\n"
                + "[local]: https://example.com\n\n~~~text\n未闭合围栏\n"
        case .listLayout:
            let long = String(repeating: "编号应紧贴正文第一行；长段落换行、滚动和选择不应制造额外空白。", count: 12)
            return """
            ## 编号与正文顶部对齐

            9. \(long)
            10. 第二项短段落。

                这是同一项的第二段，应保留正常段落间距。

                - 嵌套项目，长按这里选择文字。
                - 嵌套项目二。

            11. \(long)

            - 无序列表：\(long)
            - 短项目。
            """
        }
    }
}
