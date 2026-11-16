import Foundation

/// Capture metadata survives stop. A display-link object is only a live event
/// source; it must not be used as the storage for a finished capture's request.
struct ChatPerformanceCapture {
    private(set) var generation: UInt64 = 0
    private(set) var isRecording = false
    private(set) var requestedFrameRate: Double?

    mutating func start(requestedFrameRate: Double) {
        generation &+= 1
        isRecording = true
        self.requestedFrameRate = requestedFrameRate.isFinite && requestedFrameRate > 0 ? requestedFrameRate : nil
    }
    mutating func stop() { isRecording = false }
    func accepts(_ generation: UInt64?) -> Bool { isRecording && generation == self.generation }
}

/// Fixed-size numeric samples only. No message, session, URL or credential fields.
struct ChatPerformanceStatistics {
    enum Metric: String, CaseIterable, Sendable {
        case queue = "解析排队", parse = "解析调用（含内部等待）", publish = "主线程发布"
        case hostCreate = "行Host创建", rowMeasure = "行尺寸测量", geometryLayout = "消息几何布局"
        case highlight = "代码分词", window = "视口窗口更新", frame = "显示回调间隔"
        // Appended after the original cases so existing ordering/索引 stays stable.
        case firstPaint = "首屏提交（页出现→首次非空帧）", reconcile = "差异协调"
        case commitLayout = "提交布局（含逐行 layoutIfNeeded）", pagination = "翻页端到端"
        // 本轮新增：发布（updateUIView）→ 提交布局收尾，独立于只含布局阶段的
        // .commitLayout。追加在末尾，既有 ordering / 索引保持稳定。
        case publishToCommit = "发布→提交"
        // build160: end-to-end cost of the MainActor timeline projection;
        // separate from UIKit reconcile/geometry and device callback cadence.
        case timelineProjection = "时间线投影"
        /// Disk-to-model warmup only, not time until UIKit first paint.
        case historyWarmup = "本地历史预热"
        // Source compatibility for the older sizeThatFits instrumentation.
        static var measure: Metric { .rowMeasure }
    }
    struct Samples {
        private(set) var count = 0
        private(set) var total = 0.0
        private(set) var maximum = 0.0
        private(set) var recent: [Double] = []
        private var cursor = 0
        mutating func add(_ value: Double) {
            guard value.isFinite, value >= 0 else { return }
            count += 1; total += value; maximum = max(maximum, value)
            if recent.count < 128 { recent.append(value) }
            else { recent[cursor] = value; cursor = (cursor + 1) % 128 }
        }
        func percentile(_ fraction: Double) -> Double {
            guard !recent.isEmpty else { return 0 }
            let sorted = recent.sorted()
            let safe = fraction.isFinite ? min(1, max(0, fraction)) : 0
            return sorted[Int((Double(sorted.count - 1) * safe).rounded(.up))]
        }
    }
    private(set) var samples: [Metric: Samples] = [:]
    private(set) var peakMounted = 0
    private(set) var peakAttached = 0
    private(set) var frameIntervals = 0
    private(set) var extendedIntervals = 0
    private var lastFrame: Double?
    private var lastExpected = 0.0

    mutating func record(_ metric: Metric, milliseconds: Double) {
        samples[metric, default: Samples()].add(milliseconds)
    }
    mutating func hosts(mounted: Int, attached: Int) {
        peakMounted = max(peakMounted, mounted); peakAttached = max(peakAttached, attached)
    }
    mutating func frame(timestamp: Double, expectedInterval: Double) {
        guard timestamp.isFinite, expectedInterval.isFinite, expectedInterval > 0 else {
            pauseFrames(); return
        }
        defer { lastFrame = timestamp; lastExpected = expectedInterval }
        guard let previous = lastFrame else { return }
        let elapsed = timestamp - previous
        // Suspension/resume and clock resets are not rendering measurements.
        guard elapsed > 0, elapsed < 0.5 else { return }
        record(.frame, milliseconds: elapsed * 1_000)
        frameIntervals += 1
        // Conservative across changes between 60/80/120Hz. This is an
        // interval observation, never a dropped-frame or refresh-rate claim.
        if elapsed > max(lastExpected, expectedInterval) * 1.5 { extendedIntervals += 1 }
    }
    mutating func pauseFrames() { lastFrame = nil; lastExpected = 0 }

    func displaySummary(deviceMaximumRate: Int, requestedFrameRate: Double?, lowPowerMode: Bool) -> String {
        let requested = requestedFrameRate.flatMap { value -> String? in
            value.isFinite && value > 0 ? String(format: "%.0fHz", value) : nil
        } ?? "尚未采样"
        let medianInterval = samples[.frame]?.percentile(0.5) ?? 0
        let callbackRate = medianInterval > 0 ? String(format: "%.1fHz", 1_000 / medianInterval) : "样本不足"
        return "设备标称刷新上限：\(deviceMaximumRate)Hz；当前低电量：\(lowPowerMode ? "开" : "关")；"
            + "link 请求（本轮）：\(requested)；回调间隔换算频率：\(callbackRate)（非屏幕 FPS）"
    }
}
