# Hermes 2.28.0 / build171

本版用于验证 main 新版本合入后的完整自动发布链；应用功能与 build166 保持一致。

HermesShell 是 Hermes 的原生 iOS 客户端，支持多实例、流式聊天、历史会话、附件和本地草稿恢复。

## 连接自己的服务

首次启动不预设任何服务器。点击「配置连接」，在设置中添加自己的网关地址与 API 密钥，或添加 WebUI 实例。网关密钥保存在 iOS Keychain；源码不含服务凭据。

已有安装保留原来的实例和凭据。应用 bundle ID 仍为 `com.whale7.hermes`，以支持覆盖升级。

## 源码与验证

本仓库是清理后的公开源码快照，应用基于 2.26.1 / build167。未导入上游私有仓库的 Git 历史、内部交接文档、构建输出或测试日志。

```sh
python3 tests/verify_source.py
python3 tests/check_swiftui_modifiers.py
python3 tests/test_swiftui_modifiers.py
bash tests/run_container.sh
```

离线测试需要兼容项目的 Swift 工具链和 Python 3；GitHub Actions 使用 runner 预装的 Swift，记录实际版本并以完整回归结果验证兼容性。远程辅助入口需要自行设置 `HERMES_TEST_TARGET=user@build-host`；本地执行离线套件不需要 SSH、网关、密钥或真实会话。

## 构建

GitHub Actions 在 pull request 和 main 更新时并行执行源码检查与完整 Swift 离线回归。

当 `release.json` 的 version/build 相比推送前的 main 发生变化，且 build 递增、版本不回退时，两项检查通过后自动启动 `macos-26` runner 的默认 Xcode（实际 macOS、Xcode、Swift 与 iPhoneOS SDK 版本写入构建来源信息），使用 Incremental `-O` 编译一次 unsigned iPhoneOS arm64 IPA。工作流在同一 runner 校验包与来源，直接上传草稿 Release，下载核对四项资产的 SHA256 后转为正式 Release，并再次核对。没有临时 Actions Artifact，也不依赖私有仓库或自托管机器。

普通维护提交只检查，不编译或发版。`workflow_dispatch` 保留仅编译验证的入口，不创建 Release、不保存 Artifact；该模式的包随临时 runner 清理。正式版本使用 `release-<version>-build<build>` 标签；已有正式 Release / tag 不覆盖，失败留下的草稿只允许同一个工作流运行恢复上传，且已上传资产必须逐字节一致。同一 Job 对瞬时上传/API 故障最多重试三次；整个 Job 重跑后若产物改变，将拒绝混用草稿资产。Latest 由 GitHub 根据来源提交日期和版本自动选择，避免旧版本后完成时强制抢占。

可在本仓库 Actions Secret 配置 `BARK_URL` 以接收发布成功链接或失败运行链接；缺失或通知失败会明确提示，不改变实际发布结果。设备安装仍需要自行签名。

也可在安装 Xcode、XcodeGen 的 macOS 上运行 `scripts/github-build-ipa.sh`，或在自行配置的 xtool 环境运行 `scripts/release-local.sh`。Windows 远程构建脚本需要本地设置 `HERMES_BUILD_TARGET` 和 `HERMES_BUILD_PROJECTS`。

## 第三方代码

保留 `Vendor/Textual/LICENSE`、上游来源/补丁记录和 `Resources/THIRD_PARTY_NOTICES.txt`。第三方代码的许可证以各自声明为准。
