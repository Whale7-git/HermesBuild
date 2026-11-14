import SwiftUI

struct ContextUsageView: View {
    let usage: ChatUsage?
    let contextStatus: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("上下文窗口", systemImage: "square.stack.3d.up")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        if let usage, let fraction = usage.contextFraction,
                           let prompt = usage.promptTokens, let capacity = usage.contextLength {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(Self.percentLabel(fraction))
                                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                                Text("%").font(.title3).foregroundStyle(.secondary)
                                Spacer()
                                Text(usage.estimated ? "服务端估算" : "最近一次请求")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ProgressView(value: min(1, max(0, fraction)))
                                .tint(fraction > 0.85 ? .orange : AppTheme.accent)
                            Text("\(prompt.formatted()) / \(capacity.formatted()) tokens")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        } else {
                            Text("尚未报告").font(.title2.weight(.medium))
                            Text("收到可用的上下文计数后，将显示用量。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                } footer: { Text("上下文占用来自最近一次请求，不是累计输入量。") }
                Section("本轮用量") {
                    LabeledContent("输入", value: usage?.inputTokens?.formatted() ?? "未报告")
                    LabeledContent("输出", value: usage?.outputTokens?.formatted() ?? "未报告")
                    LabeledContent("估算费用", value: usage?.cost.map { String(format: "$%.5f USD", $0) } ?? "未报告")
                }
                if let contextStatus {
                    Section {
                        Text(contextStatus).font(.footnote)
                    } header: { Text("历史预填充") }
                      footer: { Text("此状态说明历史是否已注入，不代表 token 余量。") }
                }
            }
            .scrollContentBackground(.hidden)
            // 横屏与未来 iPad：内容最多 640 并居中。
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .background(AppTheme.canvas)
            .navigationTitle("上下文与用量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }

    /// 极端/非有限用量不能让 Int(_:) trap；先钳到 Int.max 以下再取整。
    static func percentLabel(_ fraction: Double) -> String {
        let scaled = fraction * 100
        guard scaled.isFinite else { return "—" }
        let upper = Double(Int.max).nextDown
        let safe = min(max(scaled, 0), upper)
        return String(Int(safe))
    }
}
