import SwiftUI

/// 添加实例。两种后端形态字段不同，所以用同一个表单按选择切换，
/// 而不是给网关单独做一个入口——用户心智里「加一个服务器」只有一件事。
struct AddInstanceView: View {
    @ObservedObject var app: AppState
    let onClose: () -> Void
    /// Edit mode uses an immutable identity, not a potentially shifted index.
    private let editingID: UUID?

    @State private var name: String
    @State private var baseURL: String
    @State private var backend: BackendKind
    @State private var apiKey = ""
    @State private var webuiBaseURL: String
    @State private var gatewayDataPath: String
    @State private var errorText: String?
    @State private var saving = false
    @State private var saveTask: Task<Void, Never>?

    init(app: AppState, editing: HermesInstance? = nil, onClose: @escaping () -> Void) {
        self.app = app
        self.editingID = editing?.id
        self.onClose = onClose
        _name = State(initialValue: editing?.name ?? "")
        _baseURL = State(initialValue: editing?.baseURL ?? "")
        _backend = State(initialValue: editing?.backend ?? .gateway)
        _webuiBaseURL = State(initialValue: editing?.webuiBaseURL ?? "")
        _gatewayDataPath = State(initialValue: editing?.gatewayDataPath ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("连接方式", selection: $backend) {
                        ForEach(BackendKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(editingID != nil)
                    Text(backend.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: { Text("后端") }

                Section {
                    TextField("实例名称", text: $name)
                    TextField(backend == .gateway ? "https://网关地址:8642" : "https://…", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                } header: { Text("地址") }
                  footer: {
                    Text(backend == .gateway
                         ? "填 Hermes 网关（api_server）的地址与端口，不是 WebUI 的地址。"
                         : "填 WebUI 的完整地址。")
                }

                if backend == .gateway {
                    Section {
                        SecureField(editingID == nil ? "API_SERVER_KEY" : "新 API_SERVER_KEY（留空不变）", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                     // No WebUI fallback field for newly created Gateway instances.
                    } header: { Text("访问凭证与附件") }
                      footer: {
                        if editingID != nil {
                            Text("不填写则保留钥匙串中的原密钥；更改网关地址必须重新输入密钥。新地址或新密钥会在保存前验证。更换账号密钥会轮换旧账号缓存。")
                        } else {
                            Text("Gateway 原生接口支持聊天、模型目录与文件。服务端必须提供 /v1/files，客户端不会因 404 转发到 WebUI。当前网关暂不支持归档和定点分支。")
                        }
                    }

                    Section {
                        TextField("/opt/data", text: $gatewayDataPath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: { Text("网关侧数据目录（可选）") }
                      footer: {
                        Text("仅用于旧附件路径兼容。使用 Gateway Files API 上传的新附件不需要转换路径。")
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText).font(.caption).foregroundStyle(AppTheme.danger)
                    }
                }
            }
            .navigationTitle(editingID == nil ? "添加实例" : "编辑实例")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { saveTask?.cancel(); onClose() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "正在验证…" : (editingID == nil ? "添加" : "保存")) { submit() }
                        .fontWeight(.medium)
                        .disabled(saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func submit() {
        guard !saving else { return }
        errorText = nil
        if let editingID {
            saving = true
            saveTask = Task {
                let result = await app.editInstance(
                    id: editingID, name: name, url: baseURL,
                    replacementAPIKey: apiKey, gatewayDataPath: gatewayDataPath)
                guard !Task.isCancelled else { return }
                saving = false
                saveTask = nil
                switch result {
                case .success: onClose()
                case .failure(let message): errorText = message
                }
            }
            return
        }
        let result = app.addInstance(name: name, url: baseURL, backend: backend,
                                     apiKey: apiKey, webuiBaseURL: webuiBaseURL,
                                     gatewayDataPath: gatewayDataPath)
        switch result {
        case .success: onClose()
        case .failure(let message): errorText = message
        }
    }
}
