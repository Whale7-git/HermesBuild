import Foundation

/// 附件路径在 WebUI 与网关容器之间的换算。
///
/// 两个容器挂的是**同一个宿主机目录**，但挂载点不同：WebUI 是
/// `/home/hermeswebui/.hermes`，官方镜像的网关是 `/opt/data`。上传接口返回的是
/// WebUI 侧绝对路径，原样交给 agent 会指向一个它自己容器里不存在的文件，
/// 而失败现场只是「工具报找不到文件」，很难归因到挂载点差异上。
///
/// 纯函数，不碰网络，可离线测试。
enum GatewayAttachmentPaths {

    /// WebUI 侧数据目录的固定片段。上传落在 `~/.hermes/attachments/<session>/<file>`，
    /// 这里只认 `/.hermes/` 这一段，前缀（`/home/hermeswebui` 或别的 HOME）不参与匹配。
    static let webuiMarker = "/.hermes/"

    /// 换成网关容器里的等价路径。
    ///
    /// - 认不出 `.hermes` 前缀时**原样返回**：宁可让附件可能读不到，也不要把路径
    ///   改到一个看起来合理但实际不对的位置——那种错误比直接失败更难查。
    /// - `gatewayDataPath` 为空表示不做映射（实例没配）。
    static func rewrite(_ path: String, gatewayDataPath: String) -> String {
        let root = gatewayDataPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !root.isEmpty else { return path }
        guard let range = path.range(of: webuiMarker) else { return path }
        return "/" + root + "/" + path[range.upperBound...]
    }
}
