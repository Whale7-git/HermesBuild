# Hermes 2.26.0 / build166

HermesShell 是 Hermes 的原生 iOS 客户端，支持多实例、流式聊天、历史会话、附件和本地草稿恢复。

## 连接自己的服务

首次启动不预设任何服务器。点击「配置连接」，在设置中添加自己的网关地址与 API 密钥，或添加 WebUI 实例。网关密钥保存在 iOS Keychain；源码不含服务凭据。

已有安装保留原来的实例和凭据。应用 bundle ID 仍为 `com.whale7.hermes`，以支持覆盖升级。

## 源码与验证

本仓库是清理后的公开源码快照，应用基于 2.26.0 / build166。未导入上游私有仓库的 Git 历史、内部交接文档、构建输出或测试日志。

```sh
python3 tests/verify_source.py
python3 tests/check_swiftui_modifiers.py
python3 tests/test_swiftui_modifiers.py
bash tests/run_container.sh
```

离线测试需要 Swift 6.2 和 Python 3。远程辅助入口需要自行设置 `HERMES_TEST_TARGET=user@build-host`；本地执行离线套件不需要 SSH、网关、密钥或真实会话。

## 构建

GitHub Actions 在 pull request 和 main 更新时执行源码与离线回归。手动运行 **HermesShell source checks and iOS build** 可构建 unsigned iPhoneOS arm64 IPA；产物只作为 Actions Artifact 保存，不会自动创建 Release。设备安装需要自行签名。

也可在安装 Xcode、XcodeGen 的 macOS 上运行 `scripts/github-build-ipa.sh`，或在自行配置的 xtool 环境运行 `scripts/release-local.sh`。Windows 远程构建脚本需要本地设置 `HERMES_BUILD_TARGET` 和 `HERMES_BUILD_PROJECTS`。

## 第三方代码

保留 `Vendor/Textual/LICENSE`、上游来源/补丁记录和 `Resources/THIRD_PARTY_NOTICES.txt`。第三方代码的许可证以各自声明为准。
