# Hermes 2.46.1 / build206

Hermes 是原生 iOS 客户端，支持多实例、流式聊天、历史会话、附件和本地草稿恢复。为兼容现有工程，Swift package、target 和 product 仍保留 `HermesShell` 名称。

## 连接自己的服务

首次启动不预设任何服务器。点击「配置连接」，在设置中添加自己的网关地址与 API 密钥，或添加 WebUI 实例。网关密钥保存在 iOS Keychain；源码不含服务凭据。

已有安装保留原来的实例和凭据。应用 bundle ID 仍为 `com.whale7.hermes`，以支持覆盖升级。

## 源码与验证

本仓库是清理后的公开源码快照。未导入上游私有仓库的 Git 历史、内部交接文档、构建输出或测试日志。

```sh
python3 tests/gen_release_scope.py
python3 tests/gen_release_scope.py
python3 tests/verify_source.py
python3 tests/check_swiftui_modifiers.py
python3 tests/test_swiftui_modifiers.py
python3 -m unittest discover -s tests/releaseautomation -p 'test_*.py' -v
bash tests/run_container.sh
```

离线测试需要兼容项目的 Swift 工具链、Python 3 和仓库内 fixture；GitHub Actions 使用 runner 预装的 Swift，记录实际版本并以完整回归结果验证兼容性。完整离线套件不需要网关、密钥或真实会话。

## 构建

正式发布只使用以下两个 workflow：

1. `.github/workflows/hermesshell-single-build.yml` 在 pull request 上并行运行源码检查、完整 Swift 离线回归及 `macos-26` IPA 编译。只编译一次 unsigned iPhoneOS arm64 IPA，三个任务全部通过才可发布。候选包和来源信息作为不可变 Actions Artifact 保存 14 天。
2. `.github/workflows/hermesshell-single-promote.yml` 在版本变化合入 main 后选择整个 CI 已通过的同一个 PR 候选 Artifact，核对 tree、digest、manifest 与远端字节，然后发布。不会重复编译或运行回归。

普通维护提交合入 main 后只判断版本是否变化，不编译或发版。手动运行 single-build 会编译并保留候选 Artifact，但不会发布。正式版本使用 `release-<version>-build<build>` 标签；已发布 tag 和资产不可覆盖。候选 Artifact 包含 IPA、`build-info.json`、`validation.json`、`candidate-manifest.json` 和 `SHA256SUMS.txt`；正式 Release 发布前四项，`SHA256SUMS.txt` 留在候选 Artifact 内用于校验。

候选编译还会在未被取消时单独上传 `hermes-candidate-diagnostics-<run>-<attempt>`，保留 7 天。它包含工具链记录、脱敏后的安装与编译日志、`build-report.json`，以及成功时复制进来的候选身份文件，用于成功与失败排障；它不是候选包，也不进入正式 Release。诊断上传失败不会把已验证候选误判为失败。

当前构建入口只有上述两个 GitHub Actions 工作流。旧的外部构建、远程测试和本地发布入口均已移除；历史清单只用于审计，不是操作指引。

PR 的 `source`、`offline`、`candidate` 都必须在将要合入的精确 head 上通过。main 的 tree 必须与候选 manifest 中的 tree 一致。候选丢失、过期、tree 不符或发布失败时，该 build 已消耗，应递增 build 后重新走 PR；不得用本地或另一台构建机的包替代。

可在本仓库 Actions Secret 配置 `BARK_URL` 以接收发布成功链接或失败运行链接；缺失或通知失败会明确提示，不改变实际发布结果。设备安装仍需要自行签名。

## 第三方代码

保留 `Vendor/Textual/LICENSE`、上游来源/补丁记录和 `Resources/THIRD_PARTY_NOTICES.txt`。第三方代码的许可证以各自声明为准。
