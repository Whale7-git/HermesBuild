import Foundation

/// 附件传输进度的展示文案。
///
/// 只在真的知道总量时给百分比：`expectedBytes` 缺失或非正时编一个百分比，
/// 会让进度条在传输中途乱跳，比不显示更糟。这种情况只报已传字节数。
enum AttachmentProgressPresentation {

    /// 一行短文案。`nil` 表示还没有任何进度可报（尚未开始）。
    static func text(for progress: AttachmentTransferProgress?) -> String? {
        guard let progress else { return nil }
        if let fraction = progress.fraction {
            let percent = Int((fraction * 100).rounded(.down))
            return "上传 \(percent)%"
        }
        return "已上传 " + bytes(progress.receivedBytes)
    }

    /// 是否有确定的进度比例，决定要不要画进度条。
    static func hasDeterminateProgress(_ progress: AttachmentTransferProgress?) -> Bool {
        progress?.fraction != nil
    }

    /// Download progress uses the same known-size rule as uploads.
    /// Unknown or invalid expected bytes must never fabricate a percentage.
    static func downloadText(receivedBytes: Int, expectedBytes: Int?) -> String {
        let received = max(0, receivedBytes)
        guard let expected = expectedBytes, expected > 0 else {
            return "正在下载 · 已接收 " + bytes(received)
        }
        // Clamp *before* converting to Int. Malformed expected lengths must
        // never overflow the progress presentation.
        let ratio = (Double(received) / Double(expected) * 100).rounded(.down)
        let percentage = Int(min(100.0, max(0.0, ratio)))
        return "正在下载 \(percentage)% · " + bytes(received) + " / " + bytes(expected)
    }

    /// 节流：整数百分比变化才值得刷新 UI。
    ///
    /// 传输回调可能每几 KB 就来一次；按字节比较会让整棵子树反复失效。
    static func shouldUpdate(previous: AttachmentTransferProgress?,
                             next: AttachmentTransferProgress) -> Bool {
        guard let previous else { return true }
        // 完成或失败等边界由调用方直接刷新，不走这里。
        if previous.fraction == nil || next.fraction == nil {
            return previous.receivedBytes != next.receivedBytes
        }
        return percent(previous) != percent(next)
    }

    private static func percent(_ progress: AttachmentTransferProgress) -> Int {
        guard let fraction = progress.fraction else { return -1 }
        return Int((fraction * 100).rounded(.down))
    }

    /// 字节数按量级取一位小数，避免「已上传 1234567 字节」这种读不出量级的文案。
    static func bytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(count))
    }
}
