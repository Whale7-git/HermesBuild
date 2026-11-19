import Foundation

@main
struct AttachProgressTests {
    static func main() {

    // W6 上传进度文案测试。核心规则：知道总量才给百分比，不知道就只报字节数。

    var failures: [String] = []
    var checks = 0

    func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }

    func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
        checks += 1
        if lhs != rhs { failures.append("\(message): 期望 \(rhs)，实际 \(lhs)") }
    }

    // MARK: - 知道总量：给百分比

    let half = AttachmentTransferProgress(receivedBytes: 512, expectedBytes: 1024)
    expectEqual(AttachmentProgressPresentation.text(for: half), "上传 50%", "一半时显示 50%")
    expect(AttachmentProgressPresentation.hasDeterminateProgress(half), "有总量时应画进度条")

    let zero = AttachmentTransferProgress(receivedBytes: 0, expectedBytes: 1024)
    expectEqual(AttachmentProgressPresentation.text(for: zero), "上传 0%", "刚开始显示 0%")

    // 向下取整：99.6% 不能显示成 100%，否则看起来已完成但实际没有。
    let almost = AttachmentTransferProgress(receivedBytes: 1020, expectedBytes: 1024)
    expectEqual(AttachmentProgressPresentation.text(for: almost), "上传 99%",
                "接近完成但未完成时不能显示 100%")

    // 超出总量（服务端给的 expected 偏小）时封顶 100%，不能出现 120%。
    let over = AttachmentTransferProgress(receivedBytes: 2048, expectedBytes: 1024)
    expectEqual(AttachmentProgressPresentation.text(for: over), "上传 100%", "超出总量封顶 100%")

    // MARK: - 不知道总量：只报字节数，绝不编百分比

    let unknown = AttachmentTransferProgress(receivedBytes: 1_234_567, expectedBytes: nil)
    let unknownText = AttachmentProgressPresentation.text(for: unknown)
    expect(unknownText != nil, "无总量时仍应有文案")
    expect(!(unknownText ?? "").contains("%"), "无总量时绝不能出现百分比")
    expect((unknownText ?? "").contains("已上传"), "无总量时显示已上传字节数")
    expect(!AttachmentProgressPresentation.hasDeterminateProgress(unknown),
           "无总量时不画确定进度条")

    // expectedBytes 为 0：约定为已完成，fraction 返回 1。
    let zeroExpected = AttachmentTransferProgress(receivedBytes: 100, expectedBytes: 0)
    expectEqual(AttachmentProgressPresentation.text(for: zeroExpected), "上传 100%",
                "总量为 0 视为已完成")

    // 负总量在生产中不可达：三个调用点（AttachmentModels.swift:573/578/850）
    // 都写成 `length >= 0 ? Int(length) : nil`，负数已经归一成 nil。
    // 所以这里不断言负数行为——断言一个不可达状态只会制造假缺陷。

    // MARK: - 下载进度：未知总量不编造百分比，已知总量展示边界
    let unknownDownload = AttachmentProgressPresentation.downloadText(
        receivedBytes: 4096, expectedBytes: nil)
    expect(unknownDownload.contains("正在下载") && unknownDownload.contains("已接收"),
           "下载总量未知时只报告已接收字节数")
    expect(!unknownDownload.contains("%"), "未知下载总量不能出现百分比")
    expect(AttachmentProgressPresentation.downloadText(
        receivedBytes: 512, expectedBytes: 1024).contains("50%"),
        "下载量已知时显示真实进度")
    expect(!AttachmentProgressPresentation.downloadText(
        receivedBytes: 20, expectedBytes: 0).contains("%"),
        "零或无效总量不可伪造下载进度")
    expect(AttachmentProgressPresentation.downloadText(
        receivedBytes: Int.max, expectedBytes: 1).contains("100%"),
        "异常接收字节数不会使进度转换溢出")
    expect(AttachmentProgressPresentation.downloadText(
        receivedBytes: -5, expectedBytes: nil).contains("已接收"),
        "异常负接收值按零处理")
    // MARK: - 尚未开始

    expect(AttachmentProgressPresentation.text(for: nil) == nil, "无进度时不显示文案")

    // MARK: - 节流

    // 100/1000 = 10.0%，105/1000 = 10.5%，向下取整后同为 10%。
    let p10 = AttachmentTransferProgress(receivedBytes: 100, expectedBytes: 1000)
    let p10b = AttachmentTransferProgress(receivedBytes: 105, expectedBytes: 1000)
    let p20 = AttachmentTransferProgress(receivedBytes: 200, expectedBytes: 1000)

    expect(AttachmentProgressPresentation.shouldUpdate(previous: nil, next: p10),
           "首次进度必须更新")
    expect(!AttachmentProgressPresentation.shouldUpdate(previous: p10, next: p10b),
           "百分比未变（10%→10%）不更新")
    expect(AttachmentProgressPresentation.shouldUpdate(previous: p10, next: p20),
           "百分比变化（10%→20%）应更新")

    // 无总量时按字节变化更新，但相邻同值不更新。
    let u1 = AttachmentTransferProgress(receivedBytes: 100, expectedBytes: nil)
    let u2 = AttachmentTransferProgress(receivedBytes: 100, expectedBytes: nil)
    let u3 = AttachmentTransferProgress(receivedBytes: 200, expectedBytes: nil)
    expect(!AttachmentProgressPresentation.shouldUpdate(previous: u1, next: u2),
           "无总量且字节数未变时不更新")
    expect(AttachmentProgressPresentation.shouldUpdate(previous: u1, next: u3),
           "无总量且字节数变化时更新")

    // MARK: - P1：恢复已上传附件（编辑队列项时回填）

    do {
        var batch = AttachmentBatch(sessionID: "s1")
        let p1 = ChatAttachmentPayload(name: "a.png", path: "/files/a", mime: "image/png", size: 1024, isImage: true)
        let p2 = ChatAttachmentPayload(name: "b.pdf", path: "/files/b", mime: "application/pdf", size: 2048, isImage: false)
        batch.restoreReady([p1, p2])

        expectEqual(batch.items.count, 2, "两条引用都恢复成了草稿")
        expect(batch.canSend, "恢复后全部处于 ready，可直接发送")
        let payloads = try! batch.payload(for: "s1")
        expectEqual(payloads.count, 2, "payload 能取回全部引用")
        expectEqual(payloads.first?.path, "/files/a", "path 原样保留，发送时不会丢附件")
        expectEqual(payloads.first?.size, 1024, "size 保留")
    }

    // 超上限时截断而不是越界。
    do {
        var batch = AttachmentBatch(sessionID: "s1", maxCount: 1)
        let p1 = ChatAttachmentPayload(name: "a.png", path: "/files/a", mime: "image/png", size: 1, isImage: true)
        let p2 = ChatAttachmentPayload(name: "b.png", path: "/files/b", mime: "image/png", size: 1, isImage: true)
        batch.restoreReady([p1, p2])
        expectEqual(batch.items.count, 1, "超过 maxCount 的引用被截断")
    }

    // MARK: - 结果

    if failures.isEmpty {
        print("_PASS attachprogress \(checks) checks")
    } else {
        for failure in failures { print("FAIL attachprogress: \(failure)") }
        print("_FAIL attachprogress \(failures.count)/\(checks) checks failed")
        exit(1)
    }
    }
}
