import Foundation

/// 斜杠命令的客户端处理策略。
///
/// 背景：`/compress`（以及 `/compact` 之类）是**服务端 agent 自己解析的命令**，
/// 网关与 WebUI 都没有对应的 HTTP 端点（见 `docs/gateway-backend-spec.md` 的路由表：
/// `/v1/runs`、`/api/chat/start` 只接受自然语言 `input` / `message`）。
/// 所以客户端不能、也不该"实现压缩"——把命令改写或拦截都会让它彻底失效。
///
/// 客户端真正该做的是三件事：
///   1. **原样转发**，不做任何 trim 之外的改写（`/compress` 必须保持字面量）；
///   2. **识别出这是命令**，从而给出"已提交，等待服务端处理"这类反馈，
///      而不是当成普通消息静默等待；
///   3. **对本地有等价能力的状态给出解释**，避免用户以为命令没生效。
///
/// 这个类型只做纯字符串判定，不依赖 UI 与服务端，便于离线测试锁住语义。
enum ChatSlashCommand {
    /// 已识别的命令种类。
    enum Kind: Equatable {
        /// 压缩 / 整理上下文。
        case compress
        /// 清空上下文或新建会话。
        case reset
        /// 其它命令：原样转发，但客户端不解释其语义。
        case other(String)
    }

    /// 识别结果。`nil` 表示这不是命令（普通文本）。
    struct Match: Equatable {
        let kind: Kind
        /// 命令字面量（含前导 `/`，已小写），用于日志与提示。
        let name: String
        /// 命令行剩余的参数部分（已 trim）。没有参数时为空串。
        let arguments: String
    }

    /// One discoverable entry for the composer's slash menu. These are local
    /// suggestions only; selecting one inserts text and never executes it.
    struct Suggestion: Identifiable, Equatable {
        let command: String
        let summary: String
        let insertion: String
        var id: String { command }
    }

    static let suggestions: [Suggestion] = [
        Suggestion(command: "/compress", summary: "请求服务端压缩当前上下文",
                   insertion: "/compress "),
        Suggestion(command: "/compact", summary: "compact 的别名，由服务端解释",
                   insertion: "/compact "),
        Suggestion(command: "/clear", summary: "请求服务端清空或重置上下文",
                   insertion: "/clear "),
        Suggestion(command: "/new", summary: "请求服务端开始新的上下文",
                   insertion: "/new "),
        Suggestion(command: "/reset", summary: "请求服务端重置当前上下文",
                   insertion: "/reset ")
    ]

    /// Return suggestions only while the caret is editing a leading slash
    /// token. Once a space is typed, the menu closes so ordinary prose is not
    /// interrupted.
    static func menuSuggestions(for text: String, caretUTF16Offset: Int) -> [Suggestion] {
        let ns = text as NSString
        guard ns.length > 0, caretUTF16Offset >= 0, caretUTF16Offset <= ns.length else { return [] }
        let prefix = ns.substring(to: caretUTF16Offset)
        guard prefix.hasPrefix("/"), !prefix.contains(where: \.isWhitespace) else { return [] }
        let needle = String(prefix.dropFirst()).lowercased()
        guard !needle.isEmpty else { return suggestions }
        return suggestions.filter {
            $0.command.dropFirst().lowercased().hasPrefix(needle)
                || $0.summary.localizedCaseInsensitiveContains(needle)
        }
    }

    /// 判定并解析一条输入。
    ///
    /// 规则（有意保守，避免误伤普通文本）：
    ///   - 必须**以 `/` 开头**，且 `/` 前不能有空白（`  /compress` 不算）；
    ///   - `/` 后必须是 ASCII 字母开头，避免把 `/1abc` 这类当成命令；
    ///   - **命令名里不能出现 `/`**：`/usr/bin/env` 是路径，不是命令。
    ///     这条同时挡掉了 `/a/b`、`/opt/x` 这类误判。
    ///   - 命令名与参数之间用空白分隔，命令名大小写不敏感。
    ///
    /// 不满足以上条件时返回 `nil`，调用方按普通消息处理。
    static func parse(_ text: String) -> Match? {
        // 前导空白会让 `/` 不在首位：这是缩进文本，不是命令。
        guard text.first == "/" else { return nil }
        let body = text.dropFirst()
        guard let first = body.first, first.isASCII, first.isLetter else { return nil }

        // 命令名到第一个空白或 `/` 为止。后者让路径（`/usr/bin/env`）不被当成命令。
        var name = ""
        var rest = ""
        var consumed = 0
        for character in body {
            if character.isWhitespace || character == "/" { break }
            name.append(character)
            consumed += 1
        }
        // 命令名里出现 `/` 说明这是路径：整条按普通文本处理。
        if body.count > consumed, body[body.index(body.startIndex, offsetBy: consumed)] == "/" {
            return nil
        }
        if consumed < body.count {
            rest = String(body.dropFirst(consumed))
        }
        guard !name.isEmpty else { return nil }
        let lowered = name.lowercased()
        let arguments = rest.trimmingCharacters(in: .whitespacesAndNewlines)

        switch lowered {
        case "compress", "compact": return Match(kind: .compress, name: "/" + lowered, arguments: arguments)
        case "clear", "new", "reset": return Match(kind: .reset, name: "/" + lowered, arguments: arguments)
        default: return Match(kind: .other(lowered), name: "/" + lowered, arguments: arguments)
        }
    }

    /// 提交命令后显示在状态行上的提示。
    ///
    /// 措辞有意区分"已提交"与"已完成"：客户端只能确认请求发出去了，
    /// 压缩是否真的发生只有服务端知道。写成"正在压缩"会在服务端不支持时骗人。
    static func submissionNotice(for match: Match) -> String? {
        switch match.kind {
        case .compress:
            return "已提交 \(match.name)，正在等待服务端处理上下文。"
        case .reset:
            return "已提交 \(match.name)，等待服务端返回结果。"
        case .other:
            // 未知命令不编造语义：只说明已原样转发。
            return "已提交 \(match.name)。该命令由服务端解释，客户端不做处理。"
        }
    }

    /// 本轮结束时如果服务端没有任何可见回应，给出的兜底说明。
    ///
    /// 为什么需要它：命令被当成普通消息转发后，服务端若不认识它，可能只回一句
    /// 普通答复或干脆不回。用户看到"发出去了但没压缩"，却不知道是服务端不支持。
    /// 这条提示把"客户端已转发、语义由服务端决定"讲清楚。
    static func noEffectNotice(for match: Match) -> String {
        switch match.kind {
        case .compress:
            return "服务端未报告上下文压缩结果。该命令由服务端 agent 执行；若当前网关版本不支持，客户端无法代为压缩。"
        case .reset:
            return "服务端未报告重置结果。该命令由服务端 agent 执行；若当前网关版本不支持，客户端无法代为处理。"
        case .other(let name):
            return "服务端未对 \(name) 给出结果。该命令由服务端 agent 解释。"
        }
    }
}
