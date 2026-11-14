import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { print("FAIL: \(message)"); exit(1) }
}
typealias Command = ChatSlashCommand

// MARK: - 识别：命令 vs 普通文本

expect(Command.parse("/compress")?.kind == .compress, "/compress is a compress command")
expect(Command.parse("/compress")?.name == "/compress", "the literal name keeps its slash")
expect(Command.parse("/COMPRESS")?.kind == .compress, "command names are case insensitive")
expect(Command.parse("/compact")?.kind == .compress, "/compact is the same family as /compress")
expect(Command.parse("/clear")?.kind == .reset, "/clear is a reset command")
expect(Command.parse("/new")?.kind == .reset, "/new is a reset command")
expect(Command.parse("/help")?.kind == .other("help"),
       "unknown commands are still recognised, keyed by the bare lowercased name")
expect(Command.parse("/help")?.name == "/help", "unknown commands keep their literal name")

// 参数解析：命令名到第一个空白为止，其余原样保留（去首尾空白）。
expect(Command.parse("/compress now")?.arguments == "now", "trailing arguments are captured")
expect(Command.parse("/compress   ")?.arguments == "", "trailing whitespace is not an argument")
expect(Command.parse("/compress   a  b")?.arguments == "a  b", "inner spacing is preserved")

// 不该被误判成命令的输入：普通文本、缩进、路径、斜杠在中间。
for text in ["", " ", "/", "/ ", "hello", "hello /compress", " /compress",
             "/usr/bin/env", "/1abc", "/中文", "压缩上下文", "a/b",
             "/opt/data", "/a/b/c"] {
    expect(Command.parse(text) == nil, "\(text.debugDescription) is not a slash command")
}

// 单个词后面没有 `/` 时仍是命令候选：`/usr` 与 `/usr/bin/env` 的区别就在这里。
expect(Command.parse("/usr")?.kind == .other("usr"),
       "a single leading word after the slash is still a command candidate")
expect(Command.parse("/usr/bin") == nil,
       "a path is never treated as a command, even with a known-looking prefix")

// MARK: - 提示文案：不能谎称「正在压缩」

let compress = Command.parse("/compress")!
let compressNotice = Command.submissionNotice(for: compress) ?? ""
expect(compressNotice.contains("已提交"), "the submission notice states it was submitted")
expect(!compressNotice.contains("正在压缩"),
       "the notice never claims compression is running: only the server can know")
expect(compressNotice.contains("/compress"), "the notice names the command")

let unknown = Command.parse("/whatever")!
let unknownNotice = Command.submissionNotice(for: unknown) ?? ""
expect(unknownNotice.contains("服务端"),
       "unknown commands say the server interprets them, not the client")

// MARK: - 无效果兜底：解释「客户端只能转发」

let noEffect = Command.noEffectNotice(for: compress)
expect(noEffect.contains("服务端"), "the no-effect notice points at the server")
expect(noEffect.contains("无法代为压缩"),
       "the no-effect notice states plainly that the client cannot compress")
expect(!noEffect.isEmpty, "the no-effect notice is never empty")

let reset = Command.parse("/clear")!
expect(Command.noEffectNotice(for: reset).contains("重置"),
       "the reset fallback mentions resetting")

// MARK: - 输入面板

let allSuggestions = Command.menuSuggestions(for: "/", caretUTF16Offset: 1)
expect(allSuggestions.map(\.command) == Command.suggestions.map(\.command),
       "a bare slash lists every discoverable command")
let compactPrefix = Command.menuSuggestions(for: "/co", caretUTF16Offset: 3)
expect(compactPrefix.map(\.command) == ["/compress", "/compact"],
       "a command prefix filters without changing order")
let chineseCompress = Command.menuSuggestions(for: "/压", caretUTF16Offset: 2)
expect(chineseCompress.map(\.command).contains("/compress"),
       "typing a localized summary fragment finds the matching command")
expect(Command.menuSuggestions(for: "/compress ", caretUTF16Offset: 10).isEmpty,
       "whitespace closes the command menu")
expect(Command.menuSuggestions(for: "hello /co", caretUTF16Offset: 9).isEmpty,
       "the menu only opens for a leading slash token")
expect(Command.menuSuggestions(for: "/co", caretUTF16Offset: 99).isEmpty,
       "an invalid UTF-16 caret yields no suggestion")
expect(Command.suggestions.allSatisfy { $0.insertion == $0.command + " " },
       "selecting a suggestion only inserts command text")

// MARK: - 结构性不变量

// 所有 kind 都必须能产出非空提示，避免某条分支静默。
for name in ["/compress", "/compact", "/clear", "/new", "/reset", "/other-cmd"] {
    let match = Command.parse(name)!
    expect(!(Command.submissionNotice(for: match) ?? "").isEmpty,
           "\(name) always yields a submission notice")
    expect(!Command.noEffectNotice(for: match).isEmpty,
           "\(name) always yields a no-effect notice")
}

print("SLASH_COMMAND_PASS \(checks) assertions (pure parsing and copy, no network)")
