import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !value() { print("FAIL: \(name)"); exit(1) }
}

/// 正文图片引用分类：纯字符串判定，离线可测。
/// 注意：HistoryAttachment.parse 在 UI 层（依赖 SwiftUI），不在此离线测试内。
func runInlineImageTests() {
    // 扩展名提取必须忽略 query/fragment，否则 CDN 图的 ?w=100 会把扩展名判错。
    check(InlineImageKind.pathExtension("https://a.com/x.PNG?w=100") == "png", "extension ignores query and lowercases")
    check(InlineImageKind.pathExtension("https://a.com/x.jpg#frag") == "jpg", "extension ignores fragment")
    check(InlineImageKind.pathExtension("/state/a.webp") == "webp", "absolute path extension")
    check(InlineImageKind.pathExtension("https://a.com/noext?x=1") == "", "extensionless stays empty")

    // 栅格判定：只认我们支持的格式。
    check(InlineImageKind.isRaster("https://cdn.example/a.png"), "png is raster")
    check(InlineImageKind.isRaster("https://cdn.example/a.jpeg?x=1"), "jpeg with query is raster")
    check(InlineImageKind.isRaster("https://cdn.example/a.HEIC"), "heic is raster")
    check(!InlineImageKind.isRaster("https://cdn.example/a.svg"), "svg is not raster")
    check(!InlineImageKind.isRaster("https://cdn.example/page.html"), "html is not raster")
    check(!InlineImageKind.isRaster("https://cdn.example/noext"), "extensionless is not raster")

    // HTTP 判定：只有 http(s) 才走远程加载。
    check(InlineImageKind.isHTTP("https://a.com/x.png"), "https is http")
    check(InlineImageKind.isHTTP("http://a.com/x.png"), "http is http")
    check(!InlineImageKind.isHTTP("/state/x.png"), "relative path is not http")
    check(!InlineImageKind.isHTTP("file:///etc/passwd"), "file scheme is not http")
    check(!InlineImageKind.isHTTP("javascript:alert(1)"), "javascript scheme is not http")

    // 危险 scheme 必须被识别出来，UI 层据此拒绝（不能当本地路径请求）。
    check(InlineImageKind.hasUnsafeScheme("file:///etc/passwd"), "file scheme is unsafe")
    check(InlineImageKind.hasUnsafeScheme("javascript:alert(1)"), "javascript scheme is unsafe")
    check(InlineImageKind.hasUnsafeScheme("data:text/html,x"), "data scheme is unsafe")
    check(!InlineImageKind.hasUnsafeScheme("https://a.com/x.png"), "https is safe")
    check(!InlineImageKind.hasUnsafeScheme("/state/x.png"), "relative path has no unsafe scheme")
    // Third-party Markdown images need an explicit tap before loading, and
    // even consent must not enable direct loopback/LAN image probes.
    let allowed = ["https://cdn.example.com/image.png", "https://8.8.8.8/image.png"]
    for raw in allowed { check(ExternalInlineImageURLPolicy.mayRequest(URL(string: raw)!), "public image allowed") }
    let blocked = ["http://127.0.0.1/x.png", "http://10.0.0.5/a.png",
        "http://172.16.0.1/a.png", "http://192.168.50.10/a.png",
        "http://169.254.169.254/latest/meta-data", "http://100.64.0.1/a.png",
        "http://localhost/x.png", "https://nas.local/pic.png",
        "http://[::1]/image.png", "http://127.1/pic.png",
        "http://0x7f000001/pic.png", "http://0177.0.0.1/pic.png"]
    for raw in blocked {
        check(!ExternalInlineImageURLPolicy.mayRequest(URL(string: raw)!),
              "local/private external image blocked: \\(raw)")
    }

}

runInlineImageTests()
print("INLINE_IMAGE_PASS \(checks) assertions")
