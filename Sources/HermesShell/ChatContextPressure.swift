import Foundation

/// Presentation-only warning derived from the latest server-reported prompt
/// size. A missing or malformed count never becomes a fabricated percentage.
struct ChatContextPressure: Equatable {
    enum Severity: Equatable {
        case elevated
        case critical
    }

    let fraction: Double
    let severity: Severity

    static let elevatedThreshold = 0.75
    static let criticalThreshold = 0.90

    init?(usage: ChatUsage?) {
        guard let fraction = usage?.contextFraction,
              fraction.isFinite, fraction >= Self.elevatedThreshold else { return nil }
        self.fraction = fraction
        self.severity = fraction >= Self.criticalThreshold ? .critical : .elevated
    }

    var percent: Int {
        let upper = Double(Int.max).nextDown
        return Int(min(max(fraction * 100, 0), upper))
    }

    var message: String {
        switch severity {
        case .elevated:
            return "上下文已使用 \(percent)%，继续长对话可能变慢。"
        case .critical:
            return "上下文已使用 \(percent)%，接近上限，建议请求服务端压缩。"
        }
    }
}
