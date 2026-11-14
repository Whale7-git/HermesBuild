import SwiftUI
import UIKit
import Darwin

/// Opt-in, memory-only statistics. No timer or display link when disabled.
@MainActor
final class ChatPerformanceRecorder: NSObject, ObservableObject {
    static let shared = ChatPerformanceRecorder()
    struct Sample: Sendable {
        let generation: UInt64
        let time: TimeInterval
    }
    /// 采样点快照。除内存外都是计数，读取代价恒定；内存只在提交时采样。
    struct GaugeSnapshot: Sendable {
        var loadedRows = 0
        var loadedMessages = 0
        var measuredHeights = 0
        var mountedHosts = 0
        var attachedHosts = 0
        var currentFootprintMiB: Double?
        var peakFootprintMiB: Double?
    }
    @Published private(set) var isRecording = false
    private(set) var gauges = GaugeSnapshot()
    private var capture = ChatPerformanceCapture()
    private var statistics = ChatPerformanceStatistics()
    private var displayLink: CADisplayLink?
    // Geometry-only, bounded trace. Never retains message text, IDs, or secrets.
    private var scrollEvents: [String] = []
    private var scrollTraceStart: TimeInterval = 0

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(pauseFrames),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    func start() {
        stop()
        statistics = ChatPerformanceStatistics()
        gauges = GaugeSnapshot()
        scrollEvents.removeAll(keepingCapacity: true)
        scrollTraceStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        // This configures the sampler's callback request, not the actual screen
        // rate. ProMotion/system scheduling can choose a different cadence.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 240, preferred: 120)
        // preferredFrameRateRange.preferred is optional in the iOS SDK; fall back
        // to the value we just requested when the system does not report one.
        capture.start(requestedFrameRate: Double(link.preferredFrameRateRange.preferred ?? 120))
        isRecording = true
        // 记录起点足迹，避免只有首次提交之后才有内存峰值样本。
        noteFootprint()
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate(); displayLink = nil
        capture.stop()
        isRecording = false
        statistics.pauseFrames()
    }

    /// Captures unexpected UIKit adjustments while a session is being recorded.
    /// Explicit user drags are excluded by callers, so this traces layout churn.
    func recordScrollAdjustment(reason: String, from: Double, to: Double,
                                viewport: Double, following: Bool, moving: Bool) {
        guard isRecording, from.isFinite, to.isFinite, viewport.isFinite,
              abs(to - from) >= 12 else { return }
        let line = String(format: "t=%.2fs %@ offset %.1f→%.1f Δ%.1f viewport %.1f follow=%@ motion=%@",
                          CACurrentMediaTime() - scrollTraceStart, reason, from, to, to - from,
                          viewport, following ? "Y" : "N", moving ? "Y" : "N")
        appendScrollEvent(line)
    }

    func recordViewportChange(from: Double, to: Double, offset: Double, moving: Bool) {
        guard isRecording, from.isFinite, to.isFinite, offset.isFinite,
              from > 0, to > 0, abs(to - from) >= 12 else { return }
        let line = String(format: "t=%.2fs viewport %.1f→%.1f Δ%.1f offset %.1f motion=%@",
                          CACurrentMediaTime() - scrollTraceStart, from, to, to - from,
                          offset, moving ? "Y" : "N")
        appendScrollEvent(line)
    }

    private func appendScrollEvent(_ line: String) {
        scrollEvents.append(line)
        if scrollEvents.count > 60 { scrollEvents.removeFirst(scrollEvents.count - 60) }
    }

    func begin() -> Sample? {
        capture.isRecording ? Sample(generation: capture.generation, time: CACurrentMediaTime()) : nil
    }

    func finish(_ metric: ChatPerformanceStatistics.Metric, _ sample: Sample?) {
        guard let sample, capture.accepts(sample.generation) else { return }
        record(metric, milliseconds: (CACurrentMediaTime() - sample.time) * 1_000, sample: sample)
    }

    func record(_ metric: ChatPerformanceStatistics.Metric, milliseconds: Double, sample: Sample?) {
        guard capture.accepts(sample?.generation) else { return }
        statistics.record(metric, milliseconds: milliseconds)
    }

    /// Optional, generation-scoped bridge for work timed off-main. The producer
    /// records seconds only while this callback exists; no document enters it.
    func durationSink(for metric: ChatPerformanceStatistics.Metric) -> (@Sendable (Double) -> Void)? {
        guard capture.isRecording else { return nil }
        let sample = Sample(generation: capture.generation, time: 0)
        return { [weak self] seconds in
            guard seconds.isFinite, seconds >= 0 else { return }
            Task { @MainActor [weak self] in
                self?.record(metric, milliseconds: seconds * 1_000, sample: sample)
            }
        }
    }

    func hosts(mounted: Int, attached: Int) {
        guard isRecording else { return }
        statistics.hosts(mounted: mounted, attached: attached)
        gauges.mountedHosts = mounted
        gauges.attachedHosts = attached
    }

    /// 规模 gauge：只在采集中更新，未开始录制时只多一次布尔判断。
    func gauges(loadedRows: Int, loadedMessages: Int, measuredHeights: Int) {
        guard isRecording else { return }
        gauges.loadedRows = loadedRows
        gauges.loadedMessages = loadedMessages
        gauges.measuredHeights = measuredHeights
    }

    /// 物理足迹（task_vm_info.phys_footprint）。系统没有暴露进程历史峰值，
    /// 这里的“峰值”是本轮采样点观测到的最大值，不是进程生命周期的绝对峰值。
    func sampleMemory() {
        guard isRecording else { return }
        noteFootprint()
    }

    private func noteFootprint() {
        guard let current = footprintMiB() else { return }
        gauges.currentFootprintMiB = current
        gauges.peakFootprintMiB = max(gauges.peakFootprintMiB ?? 0, current)
    }

    @objc private func pauseFrames() { statistics.pauseFrames() }
    @objc private func frame(_ link: CADisplayLink) {
        guard isRecording, UIApplication.shared.applicationState == .active else {
            statistics.pauseFrames(); return
        }
        statistics.frame(timestamp: link.timestamp, expectedInterval: link.targetTimestamp - link.timestamp)
    }

    func report() -> String {
        var lines = ["Hermes \(AppTheme.version) / build \(AppTheme.build)",
            "采样：\(isRecording ? "进行中" : "已停止")；仅本次进程内数字统计",
            "耗时单位 ms；p50/p95 取最近最多 128 次，max 取本轮全部样本。"]
        for metric in ChatPerformanceStatistics.Metric.allCases {
            let value = statistics.samples[metric] ?? .init()
            lines.append(String(format: "%@: n=%d p50=%.2f p95=%.2f max=%.2f", metric.rawValue,
                value.count, value.percentile(0.5), value.percentile(0.95), value.maximum))
        }
        let scheduler = ChatRenderScheduler.shared.snapshot
        lines += ["Host 峰值：挂载 \(statistics.peakMounted)，附着 \(statistics.peakAttached)",
            "解析调度当前：运行 \(scheduler.running)，等待 \(scheduler.waiting)；进程峰值 \(scheduler.peakRunning)",
            "规模快照：已加载行 \(gauges.loadedRows)，已加载消息 \(gauges.loadedMessages)，高度缓存 \(gauges.measuredHeights)；"
                + "当前挂载 \(gauges.mountedHosts)，附着 \(gauges.attachedHosts)",
            "显示间隔：\(statistics.frameIntervals) 次；超过相邻预期间隔 1.5×：\(statistics.extendedIntervals) 次"]
        lines.append(statistics.displaySummary(deviceMaximumRate: UIScreen.main.maximumFramesPerSecond,
            requestedFrameRate: capture.requestedFrameRate, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled))
        if let current = gauges.currentFootprintMiB {
            lines.append(String(format: "内存足迹：当前 %.1f MiB，采样点峰值 %.1f MiB（不是进程历史绝对峰值）",
                current, gauges.peakFootprintMiB ?? current))
        }
        if let memory = residentMiB() { lines.append(String(format: "当前常驻内存：%.1f MiB（不是峰值）", memory)) }
        lines.append("阶段说明：Host创建只计新建与首次挂载；行测量计实际sizeThatFits；几何布局不含视口窗口更新。解析调用包括worker actor内部等待，并非纯Foundation CPU时间。代码分词只计Prism与token转换，不含排队、主题样式或布局；这些阶段可能嵌套，不可相加作为一帧耗时。")
        lines.append("新阶段说明：reconcile 只计差异协调；commitLayout 只计布局阶段（宿主预布局、逐行 layoutIfNeeded 与本函数收尾），不再包含快照发布；publishToCommit 的起点取最近一次快照发布（updateUIView），终点与 commitLayout 相同，因此代表「发布→提交」延迟；pagination 仅在视图层成对调用 notePaginationBegan/Ended 时采样；firstPaint 起点为首个快照下发（updateUIView），若当时未开始采样则不记录。")
        lines.append("滚动几何事件（仅采样开启时，最近最多60条；阈值12pt；不包含消息内容）:")
        lines.append(contentsOf: scrollEvents.isEmpty ? ["无达到阈值的布局或视口事件"] : scrollEvents)
        lines.append("显示回调间隔受 ProMotion、系统调度和前后台影响，不等同于掉帧率或实际屏幕FPS，也不能证明每次回调都绘制了一帧。未包含正文、会话标识、地址、Cookie 或凭据；不会自动保存或上传。")
        return lines.joined(separator: "\n")
    }

    private func residentMiB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : nil
    }

    /// 明细里的 resident_size 会低估压缩页与 GPU 相关占用；task_vm_info 的
    /// phys_footprint 更接近系统统计的应用内存。取不到时返回 nil，报告回退到
    /// 常驻内存，不伪造峰值。
    private func footprintMiB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }
}
