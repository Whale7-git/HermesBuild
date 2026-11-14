import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatPerformanceView: View {
    @ObservedObject private var recorder = ChatPerformanceRecorder.shared
    @State private var report = "尚未采样"
    @State private var exportedReport: ExportedPerformanceReport?

    /// 足迹只在采样时写入：从未采过就是 nil，用来区分「还没跑过」与「跑完但指标为零」。
    private var hasSamples: Bool { recorder.gauges.currentFootprintMiB != nil || recorder.isRecording }

    var body: some View {
        Form {
            Section {
                Text("开始采样后返回聊天，打开同一长会话、滚动和生成回复，再回到这里停止并查看统计。也可在渲染检查页播放固定本地示例。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    bullet("① 同一长会话：连续上下滑动 20 秒。")
                    bullet("② 同一输入法：多行输入、换行、键盘交互收起各 5 次。")
                    bullet("③ 渲染检查：播放同一本地流式示例，再折叠/展开长篇与工具。")
                }
                .padding(.vertical, 4)
                Button(recorder.isRecording ? "停止并查看统计" : "开始新的采样") { toggleSampling() }
                    .buttonStyle(.bordered)
                Button("刷新统计") { report = recorder.report() }
                    .buttonStyle(.bordered)
                Button("导出报告…") { exportReport() }
                    .buttonStyle(.bordered)
                    .disabled(!hasSamples)
            } header: {
                Text("采样")
            } footer: {
                Text("每项开始一次新的采样；保持字号、低电量模式与设备温度条件接近。")
            }

            Section {
                gaugeRow("已加载行", "\(recorder.gauges.loadedRows) 行")
                gaugeRow("已加载消息", "\(recorder.gauges.loadedMessages) 条")
                gaugeRow("高度缓存", "\(recorder.gauges.measuredHeights) 条")
                gaugeRow("当前挂载 / 附着 Host",
                         "\(recorder.gauges.mountedHosts) / \(recorder.gauges.attachedHosts)")
                gaugeRow("内存足迹 当前 / 采样峰值", memoryText)
            } header: {
                Text("规模与内存")
            } footer: {
                Text("规模快照只反映最近一次采样点；内存峰值仅覆盖采样点，不是进程历史最高。")
            }

            Section {
                if hasSamples {
                    Text(report)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("复制统计") { UIPasteboard.general.string = recorder.report() }
                        .buttonStyle(.bordered)
                } else {
                    HermesEmptyState(symbol: "speedometer",
                                     title: "尚无采样",
                                     message: "点上方「开始新的采样」，返回聊天滚动一段，再回来查看统计。")
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text("报告")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    bullet("只记录本次进程内有上限的数字样本，不记录正文、会话标识或登录信息，也不自动上传。")
                    bullet("停止后保留本轮 link 请求值；显示回调间隔及其换算频率都不是实际屏幕 FPS，也不是掉帧率。")
                    bullet("阶段耗时可能嵌套，不能直接相加；首屏从首个快照下发起算，未采样则不记录；翻页只在视图层成对调用时采样。")
                    bullet("采样会增加少量开销，用完请停止；比较时请使用相同设备、字号和会话。")
                }
                .padding(.top, 4)
            }
        }
        .scrollContentBackground(.hidden)
        // 横屏与未来 iPad：内容最多 640 并居中。
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(AppTheme.canvas)
        .navigationTitle("体验诊断")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { report = recorder.report() }
        .fileExporter(isPresented: Binding(
            get: { exportedReport != nil },
            set: { if !$0 { exportedReport = nil } }
        ), document: exportedReport.map { PerformanceReportDocument(text: $0.text) },
           contentType: .plainText, defaultFilename: exportedReport?.filename) { _ in
            exportedReport = nil
        }
    }

    private var memoryText: String {
        guard let current = recorder.gauges.currentFootprintMiB else { return "尚未采样" }
        let peak = recorder.gauges.peakFootprintMiB ?? current
        return String(format: "%.1f / %.1f MiB", current, peak)
    }

    private func toggleSampling() {
        if recorder.isRecording { recorder.stop() } else { recorder.start() }
        report = recorder.report()
    }

    private func exportReport() {
        let stamp = Int(Date().timeIntervalSince1970)
        exportedReport = ExportedPerformanceReport(
            filename: "Hermes-experience-\(stamp).txt",
            text: recorder.report() + "\n\n"
                + RuntimeLogRecorder.shared.diagnosticProblemSummary())
    }

    private func gaugeRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).font(.footnote)
            Spacer(minLength: 8)
            Text(value).font(.footnote).monospacedDigit()
        }
    }

    private func bullet(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ExportedPerformanceReport {
    let filename: String
    let text: String
}

private struct PerformanceReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
