import SwiftUI

/// 模型选择器：按 provider 分组的平铺列表，当前项打勾。
/// 选中即调用会话级更新接口，失败保留原选择并明说原因。
struct ModelPickerView: View {
    let catalog: ModelCatalog
    let currentModel: String?
    /// Session model provider when the server reports it; nil makes a shared
    /// model name ambiguous instead of ticking several rows.
    let currentProvider: String?
    let busy: Bool
    let onPick: (ModelOption?) -> Void
    let onReload: () async -> Void
    /// A failed or unverified server read-back must remain visible in the
    /// model picker. The sheet must not dismiss before confirmation.
    var errorMessage: String? = nil
    /// Omitted on WebUI and other backends that have no request-scoped wire.
    var reasoningEffort: Binding<String>? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var grouped: [(provider: String, options: [ModelOption])] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = needle.isEmpty ? catalog.options : catalog.options.filter {
            $0.label.localizedCaseInsensitiveContains(needle)
                || $0.model.localizedCaseInsensitiveContains(needle)
                || $0.providerLabel.localizedCaseInsensitiveContains(needle)
        }
        var order: [String] = []
        var buckets: [String: [ModelOption]] = [:]
        for option in filtered {
            if buckets[option.providerLabel] == nil { order.append(option.providerLabel) }
            buckets[option.providerLabel, default: []].append(option)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var needle: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Exact identity is provider + model. Without a session provider, a name
    /// that exists under several providers is reported as unknown, not guessed.
    private var currentIdentity: String? {
        guard let currentModel else { return nil }
        if let currentProvider, !currentProvider.isEmpty {
            return currentProvider + "/" + currentModel
        }
        let matches = catalog.options.filter { $0.model == currentModel }
        return matches.count == 1 ? matches[0].id : nil
    }

    private var currentModelIsAmbiguous: Bool {
        guard let currentModel else { return false }
        if let currentProvider, !currentProvider.isEmpty { return false }
        return catalog.options.filter { $0.model == currentModel }.count > 1
    }

    var body: some View {
        NavigationStack {
            Group {
                if catalog.options.isEmpty {
                    HermesEmptyState(symbol: "cpu",
                                     title: "没有可用模型",
                                     message: "模型目录为空，或读取失败。请检查后端 provider 配置，然后重新读取。",
                                     primaryTitle: "重新读取",
                                     primaryAction: { Task { await onReload() } })
                        .padding(.horizontal, 28)
                        .frame(maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("搜索模型", text: $query)
                                .autocorrectionDisabled()
                            if !query.isEmpty {
                                Button {
                                    query = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityLabel("清除搜索")
                            }
                        }
                        .padding(11)
                        .background(AppTheme.softFill,
                                    in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    List {
                        if let errorMessage, !errorMessage.isEmpty {
                            Section {
                                Label(errorMessage, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(AppTheme.warning)
                                    .font(.footnote)
                            }
                        }
                        if let reasoningEffort {
                            Section {
                                Picker("单轮推理强度", selection: reasoningEffort) {
                                    Text("默认（服务端配置）").tag("")
                                    ForEach(ReasoningEffortPolicy.levels, id: \.self) { level in
                                        Text(level).tag(level)
                                    }
                                }
                                .pickerStyle(.menu)
                            } header: {
                                Text("推理强度")
                            } footer: {
                                Text("仅用于之后发出的 Gateway Run，不修改服务端会话或全局配置。每个模型/Provider 支持的档位不同，服务端可能拒绝；不会自动重发。")
                            }
                        }
                        if grouped.isEmpty {
                            Section {
                                HermesEmptyState(symbol: "magnifyingglass",
                                                 title: "没有匹配的模型",
                                                 message: "没有模型包含「\(needle)」。换个关键词，或重新读取目录。",
                                                 primaryTitle: "重新读取",
                                                 primaryAction: { Task { await onReload() } })
                                    .padding(.vertical, 40)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                        } else {
                            if currentModelIsAmbiguous {
                                Section {
                                    Text("当前模型的 provider 未知，同名模型无法区分；此处不标记选中项。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            ForEach(grouped, id: \.provider) { group in
                                    Section(group.provider) {
                                        ForEach(group.options) { option in
                                            Button {
                                                // Parent closes only after an exact server
                                                // history confirmation. Errors stay readable.
                                                onPick(option)
                                            } label: {
                                                row(option)
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(busy)
                                        }
                                    }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    }
                }
            }
            // 横屏与未来 iPad：内容最多 640 并居中。
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .background(AppTheme.canvas)
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await onReload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("重新读取模型目录")
                    if reasoningEffort != nil {
                        Button("完成") { dismiss() }
                    }
                }
            }
        }
    }

    private func row(_ option: ModelOption) -> some View {
        let isCurrent = option.id == currentIdentity
        return HStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isCurrent ? AppTheme.accent : Color.secondary)
                // 28pt 图标容器：行高不再被图标撑高，整行 Button 仍提供 >=44pt 点击区。
                .frame(width: 28, height: 28)
                .background(isCurrent ? AppTheme.userFill : AppTheme.softFill,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(option.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                if option.label != option.model {
                    Text(option.model)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

/// 思考过程：默认收起，点开看本轮 reasoning。只读、可选择、不进入正文与复制内容。
struct ReasoningPanel: View {
    let text: String
    let running: Bool
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 90 else { return trimmed }
        return String(trimmed.prefix(90)) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: expanded)
                    Image(systemName: "sparkle").foregroundStyle(AppTheme.accent)
                    Text(running ? "正在思考" : "思考过程")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if !expanded, !preview.isEmpty {
                        Text(preview)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(running ? "正在思考，点开查看" : "思考过程，点开查看")

            if expanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .lineSpacing(3)
                    .padding(.bottom, 10)
            }
        }
    }
}
