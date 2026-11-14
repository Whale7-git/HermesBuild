import Foundation

/// A deadline from the previous publication, never a debounce from the newest
/// token. Byte counts come from the worker's actual active parse, off MainActor.
struct ChatStreamPacing {
    private(set) var lastPublication: Double?
    private(set) var activeBytes = 0
    private(set) var parseSeconds = 0.0

    func interval(context: ChatRenderContext) -> Double {
        var result: Double
        switch activeBytes {
        case ..<2_048: result = 0.04
        case ..<12_288: result = 0.08
        default: result = 0.14
        }
        if parseSeconds.isFinite { result = max(result, min(0.20, max(0, parseSeconds) * 1.5)) }
        // A fling should stay visually stable. Coalesce streamed Markdown while
        // the finger or deceleration owns the viewport, then publish the latest
        // complete prefix immediately when scrolling ends.
        if context.isScrolling { result = max(result, 0.24) }
        if context.priority < .visible { result = max(result, 0.20) }
        return result
    }

    func delay(now: Double, finished: Bool, context: ChatRenderContext) -> Double {
        guard !finished, let lastPublication else { return 0 }
        return max(0, lastPublication + interval(context: context) - now)
    }

    mutating func published(at time: Double, activeBytes: Int, parseSeconds: Double) {
        lastPublication = time
        self.activeBytes = max(0, activeBytes)
        self.parseSeconds = parseSeconds
    }

    mutating func reset() { self = Self() }
}
