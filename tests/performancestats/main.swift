import Foundation

var checks = 0
@MainActor func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError("FAIL: \(message)") }
}

var stats = ChatPerformanceStatistics()
for bad in [-1.0, .nan, .infinity] { stats.record(.parse, milliseconds: bad) }
expect(stats.samples[.parse]?.count == 0, "invalid clocks do not corrupt summaries")
for index in 0..<10_000 { stats.record(.parse, milliseconds: Double(index) / 1_000) }
let parse = stats.samples[.parse]!
expect(parse.count == 10_000, "bounded sampling retains the total event count")
expect(parse.recent.count == 128, "timing storage stays bounded in a long chat")
expect(abs(parse.total / Double(parse.count) - 4.9995) < 0.00001, "mean covers the whole capture")
expect(parse.maximum == 9.999, "maximum covers the whole capture")
expect(parse.percentile(0.95) >= 9.98 && parse.percentile(0.95) <= 9.999, "P95 describes the recent ring, not discarded samples")
stats.hosts(mounted: 48, attached: 32)
stats.hosts(mounted: 2, attached: 1)
expect(stats.peakMounted == 48 && stats.peakAttached == 32, "resource peaks do not decrease")
stats.frame(timestamp: 1, expectedInterval: 1.0 / 120)
stats.frame(timestamp: 1 + 1.0 / 60, expectedInterval: 1.0 / 60)
expect(stats.extendedIntervals == 0, "a 120-to-60 Hz transition is not called a dropped frame")
stats.frame(timestamp: 1.10, expectedInterval: 1.0 / 60)
expect(stats.extendedIntervals == 1, "a long callback interval is counted separately")
let count = stats.samples[.frame]!.count
stats.pauseFrames()
stats.frame(timestamp: 9, expectedInterval: 1.0 / 60)
expect(stats.samples[.frame]!.count == count, "foreground reset excludes the background interval")
stats.frame(timestamp: 100, expectedInterval: 1.0 / 60)
expect(stats.samples[.frame]!.count == count, "long inactive pauses are excluded")
stats.frame(timestamp: .nan, expectedInterval: 1.0 / 60)
stats.frame(timestamp: 101, expectedInterval: 1.0 / 60)
expect(stats.samples[.frame]!.count == count, "an invalid timestamp resets the baseline")
stats.frame(timestamp: 101 + 1.0 / 120, expectedInterval: 1.0 / 120)
expect(stats.samples[.frame]!.count == count + 1, "valid frame sampling resumes after a reset")
for index in 1...10_000 {
    stats.frame(timestamp: 102 + Double(index) / 60, expectedInterval: 1.0 / 60)
}
expect(stats.samples[.frame]!.recent.count <= 128, "frame sampling cannot grow an unbounded log")

var capture = ChatPerformanceCapture()
expect(!capture.isRecording && !capture.accepts(nil), "disabled capture accepts no timing callbacks")
let noCapture = ChatPerformanceStatistics().displaySummary(deviceMaximumRate: 120,
    requestedFrameRate: capture.requestedFrameRate, lowPowerMode: false)
expect(noCapture.contains("link 请求（本轮）：尚未采样"), "uncaptured request is not falsely reported as 0Hz")
expect(noCapture.contains("样本不足") && noCapture.contains("非屏幕 FPS"), "empty callback data makes no screen-rate claim")
capture.start(requestedFrameRate: 120)
let firstGeneration = capture.generation
expect(capture.isRecording && capture.accepts(firstGeneration), "active capture accepts its own timing token")
capture.stop()
expect(!capture.isRecording && !capture.accepts(firstGeneration), "stop rejects queued numeric callback from the stopped capture")
expect(capture.requestedFrameRate == 120, "stop preserves requested rate after display-link invalidation")
capture.stop()
expect(capture.requestedFrameRate == 120, "repeated stop cannot erase capture metadata")
let stoppedReport = stats.displaySummary(deviceMaximumRate: 120,
    requestedFrameRate: capture.requestedFrameRate, lowPowerMode: false)
expect(stoppedReport.contains("link 请求（本轮）：120Hz"), "the exact report formatter keeps 120Hz after stop")
expect(!stoppedReport.contains("link 请求（本轮）：0Hz"), "stopped report cannot regress to nil-link 0Hz")
expect(stoppedReport.contains("回调间隔换算频率") && stoppedReport.contains("非屏幕 FPS"), "converted callback cadence is labelled as an interval observation")
capture.start(requestedFrameRate: 60)
expect(capture.generation != firstGeneration && !capture.accepts(firstGeneration), "restarting rejects delayed work from previous capture")
expect(capture.accepts(capture.generation) && capture.requestedFrameRate == 60, "new capture records its own request")
capture.start(requestedFrameRate: .nan)
expect(capture.requestedFrameRate == nil, "non-finite request cannot enter a report")
capture.start(requestedFrameRate: -1)
expect(capture.requestedFrameRate == nil, "negative request cannot enter a report")

var stages = ChatPerformanceStatistics()
for metric in ChatPerformanceStatistics.Metric.allCases {
    for value in [1.0, 2, 3, 4, 5] { stages.record(metric, milliseconds: value) }
    let sample = stages.samples[metric]!
    expect(sample.count == 5 && sample.total == 15, "each real stage keeps independent event count and total")
    expect(sample.percentile(0.5) == 3 && sample.percentile(0.95) == 5 && sample.maximum == 5,
        "stage percentiles describe the recorded work samples")
}
expect(ChatPerformanceStatistics.Metric.measure == .rowMeasure, "legacy measure calls map to the real row-measure stage")
var history = ChatPerformanceStatistics.Samples()
history.add(10_000)
for value in 1...128 { history.add(Double(value)) }
expect(history.count == 129 && history.recent.count == 128, "ring replacement remains bounded")
expect(history.maximum == 10_000 && history.percentile(0.95) == 122, "whole-capture maximum is separate from recent p95")
expect(history.percentile(0.5) == 65, "even-count quantile uses documented upper rank")
expect(history.percentile(-1) == 1 && history.percentile(2) == 128, "quantiles clamp out-of-range fractions")
expect(history.percentile(.nan) == 1 && history.percentile(.infinity) == 1, "invalid quantile fractions remain finite")
var resets = ChatPerformanceStatistics()
for interval in [0.0, -0.1, .nan, .infinity] {
    resets.frame(timestamp: 1, expectedInterval: interval)
    resets.frame(timestamp: 2, expectedInterval: 1.0 / 120)
}
expect(resets.frameIntervals == 0, "invalid expected intervals reset rather than invent timing samples")
// build160: projection time must be reported as an independent stage.
// A lower geometry latency is not evidence of faster source projection.
var projectionStage = ChatPerformanceStatistics()
projectionStage.record(.timelineProjection, milliseconds: 1.25)
projectionStage.record(.timelineProjection, milliseconds: 3.75)
expect(projectionStage.samples[.timelineProjection]?.count == 2,
       "timeline projection is a distinct, separately counted metric")
expect(projectionStage.samples[.timelineProjection]?.total == 5,
       "timeline projection durations are not mixed into UIKit reconcile")

print("PERFORMANCE_STATS_PASS \(checks) assertions (bounded numeric statistics, variable refresh and lifecycle)")
