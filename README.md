# Hermes 2.28.1 / build171

HermesShell 是 Hermes 的原生 iOS 客户端，支持多实例、流式聊天、历史会话、附件和本地草稿恢复。这里的版本号是当前 GPT 分支继承的应用元数据，不代表这次仅改构建链的提交是新版本。

## 当前 GPT 开发与 IPA 构建入口

**在 `gpt/**` 分支，唯一自动构建入口是 `.github/workflows/gpt-cloud-build.yml`。**每次向该分支 Push 后，GitHub Actions：

1. 在 Ubuntu 并行执行源码完整性、SwiftUI 检查和 Swift 离线回归；
2. 两项通过后，在 GitHub 托管 macOS Runner 使用 XcodeGen + Xcode 真编译 Release / iPhoneOS arm64 / unsigned IPA；
3. 检查 IPA 结构、版本、Bundle ID、未签名状态、源码 SHA、哈希和构建来源；
4. 将候选 IPA、`build-info.json`、`validation.json`、`SHA256SUMS.txt`、构建摘要和诊断日志保存为 **Actions Artifacts**。

**GPT 分支不会创建标签、GitHub Release、发送 Bark，也不需要 9 号机、SSH、xtool、Windows 远程构建环境或私有仓库。**构建通过不代表 iPhone 真机 UI 已验收；设备安装需要用户自行签名。

GitHub Actions 入口：`https://github.com/Whale7-git/HermesBuild/actions/workflows/gpt-cloud-build.yml`。

详细操作约定：`docs/gpt-cloud-build.md`；代理开发规则：`AGENTS.md`。

### 开发新版本

从已包含 GPT 构建工作流的 GPT 基线（当前为 `gpt/cloud-build-bootstrap`）创建 `gpt/<topic>`。修改应用代码和对应测试后，按版本需要同步更新 `release.json`、`Resources/Info.plist` 和本 README 首行，再执行一次 `python3 tests/gen_release_scope.py` 生成当前 build 的源码清单。Push 即触发完整 GitHub 云端验证和 IPA 交付；不需要操作旧 Runner。

本 GPT 分支只保留 `.github/workflows/gpt-cloud-build.yml` 一条构建工作流；旧正式发布、候选包工作流和 9 号机脚本已从本分支移除。`main` 分支的发布体系不受本次清理影响。

## 连接自己的服务

首次启动不预设任何服务器。在设置中添加自己的 Hermes 网关地址/API 密钥或 WebUI 实例。网关凭据存储于 iOS Keychain。Bundle ID 保持 `com.whale7.hermes`，以保留覆盖更新兼容性。

## 源码与离线验证

```sh
bash scripts/gpt-cloud-build.sh source
bash scripts/gpt-cloud-build.sh offline
# macOS + Xcode/XcodeGen 时可运行：
bash scripts/gpt-cloud-build.sh ipa
```

命令只接受 `gpt/*` 本地开发分支；GitHub Actions 中还校验仓库、Push 事件、完整分支 ref 和 Commit SHA。所有源码完整性验证基于当前 XcodeGen 构建入口，不依赖旧远程构建脚本。

历史文档中的 Linux/xtool、9 号机、自托管 Runner 和旧 Release 操作属于历史记录，**不是本分支的使用说明**；相应旧入口已从 GPT 分支移除。删除详情见 `docs/gpt-cloud-legacy-cleanup.md`，旧实现可通过 Git 历史查询。

## 第三方代码

保留 `Vendor/Textual/LICENSE`、上游来源/补丁记录和 `Resources/THIRD_PARTY_NOTICES.txt`。第三方许可证以各自声明为准。
