import Foundation

/// `GET /api/model/options` → `ModelCatalog`。
///
/// 网关的 `/v1/models` 只回一个 `hermes-agent` 占位，真正的目录在
/// `/api/model/options`：`providers[].models` 是字符串数组，顶层 `model` /
/// `provider` 是当前会话的模型与 provider。
///
/// `ModelCatalog` 只有 `init(data:)`（按 WebUI `/api/models` 的
/// `groups[].{provider, provider_id, models}` 解析），所以这里把网关响应
/// 组装成同一形状再交给它，复用它的去重、trim、label 回落逻辑，不新造类型。
enum GatewayModelCatalog {

    /// 把 `GET /api/model/options` 的响应解析成 App 的模型目录。
    ///
    /// - `providers` 缺失或不是数组 → `.missingArray`；
    /// - 顶层有 `error` → `.server`；
    /// - 单个 provider 的 `models` 缺失/类型不对 → 跳过该 provider，不整体失败；
    /// - `models` 为空的 provider 一律丢弃：UI 里点进去是空白页，没有价值；
    /// - 所有 provider 都被过滤掉 → `.malformed`，绝不返回空目录冒充「没有模型」，
    ///   否则会掩盖「provider 没配 API key / 没拉取」这类真实原因。
    static func options(_ data: Data) throws -> ModelCatalog {
        let root = try catalogRoot(data, what: "模型目录")
        // 空字符串 error 视为没有错误（与 ModelCatalog 的处理保持一致）。
        if let raw = root["error"], !(raw is NSNull) {
            let text = catalogString(raw)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { throw GatewayDecodeError.server(text) }
        }
        guard let providers = root["providers"] as? [Any] else {
            throw GatewayDecodeError.missingArray("模型目录 providers")
        }

        var groups: [[String: Any]] = []
        groups.reserveCapacity(providers.count)
        // 已被保留的 provider+model，用来确认顶层 model/provider 真能定位到某一项。
        var indexed = Set<String>()

        for raw in providers {
            guard let provider = raw as? [String: Any] else { continue }
            let models = catalogModels(provider["models"])
            guard !models.isEmpty else { continue }

            let slug = catalogIdentifier(provider["slug"])
            let name = catalogIdentifier(provider["name"])
            let providerID = slug ?? name
            var entries: [[String: Any]] = []
            entries.reserveCapacity(models.count)
            for model in models {
                guard indexed.insert(catalogKey(provider: providerID, model: model)).inserted else { continue }
                // 网关只给模型名，没有 label；用模型名兜底展示。
                entries.append(["id": model, "label": model])
            }
            guard !entries.isEmpty else { continue }
            var group: [String: Any] = ["models": entries]
            if let providerID { group["provider_id"] = providerID }
            // 展示名优先 name，没有就用 slug；都缺就退化成 providerID。
            group["provider"] = name ?? slug ?? ""
            groups.append(group)
        }

        guard !groups.isEmpty else {
            throw GatewayDecodeError.malformed(
                "模型目录里没有任何可用模型（所有 provider 的 models 都为空，先检查 provider 的 API key 或模型列表是否已拉取）")
        }

        var out: [String: Any] = ["groups": groups]
        // 顶层 model + provider 指向的那一项才标成当前：定位不到就不标，
        // 免得输入栏显示一个目录里不存在的模型。
        if let model = catalogString(root["model"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            let provider = catalogIdentifier(root["provider"])
            if indexed.contains(catalogKey(provider: provider, model: model)) {
                out["default_model"] = model
                if let provider { out["active_provider"] = provider }
            }
        }

        do {
            let assembled = try JSONSerialization.data(withJSONObject: out)
            return try ModelCatalog(data: assembled)
        } catch let error as GatewayDecodeError {
            throw error
        } catch {
            throw GatewayDecodeError.malformed("模型目录组装失败")
        }
    }

    /// 判断该响应是否值得信任：至少有一个 provider 带非空 `models`。
    ///
    /// 纯判定，不抛错。用于「网关有目录接口但全是空 provider」时回落到 WebUI。
    static func hasUsableModels(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let providers = root["providers"] as? [Any] else {
            return false
        }
        for raw in providers {
            guard let provider = raw as? [String: Any] else { continue }
            if !catalogModels(provider["models"]).isEmpty { return true }
        }
        return false
    }
}

// MARK: - 宽松取值

/// 顶层必须是对象；非法 JSON 归一成可读错误，不把 DecodingError 漏给 UI。
private func catalogRoot(_ data: Data, what: String) throws -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
        throw GatewayDecodeError.malformed("\(what)不是合法 JSON")
    }
    guard let root = object as? [String: Any] else {
        throw GatewayDecodeError.notObject(what)
    }
    return root
}

/// 字符串字段；数字也顺手转一下，缺省一律 nil。
private func catalogString(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

/// provider 标识位，空白字符串当缺省。
private func catalogIdentifier(_ value: Any?) -> String? {
    guard let text = catalogString(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else { return nil }
    return text
}

/// `models` 是字符串数组；不是数组或为空都返回空表，由调用方跳过该 provider。
/// 数组里的非字符串/空白项逐条丢弃，不让单个坏值毁掉整个 provider。
private func catalogModels(_ value: Any?) -> [String] {
    guard let value, !(value is NSNull), let list = value as? [Any] else { return [] }
    var result: [String] = []
    result.reserveCapacity(list.count)
    for entry in list {
        guard let text = entry as? String else { continue }
        let model = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { continue }
        result.append(model)
    }
    return result
}

/// `provider + model` 的唯一键，与 `ModelOption.id` 的拼接口径一致。
private func catalogKey(provider: String?, model: String) -> String {
    (provider ?? "") + "/" + model
}
