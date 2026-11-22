# Hermes 2.53.3 / build227

HermesBuild 是原生 iOS Hermes 多实例客户端，支持流式聊天、历史、附件和会话恢复。Swift 代码的兼容 target/product 名称保留为 `HermesShell`，但本仓库与构建链均为 **HermesBuild**。

## 连接

首次启动配置自己的 Gateway API Key 或 WebUI 实例。凭据保存在 iOS Keychain。固定 Bundle ID 为 `com.whale7.hermes`，便于覆盖升级。

## 开发与测试

无需任何历史源码哈希清单、Release Scope、人工审批或质量门禁。

```sh
python3 tests/check_release_identity.py
python3 tests/check_navigation_contract.py
python3 tests/check_swiftui_modifiers.py
python3 tests/test_swiftui_modifiers.py
python3 -m unittest discover -s tests/releaseautomation -p 'test_*.py' -v
bash tests/run_container.sh
```

Swift 离线测试在 `.github/workflows/hermes-offline-diagnostics.yml` 中按 **core / recovery / interface / media** 拆成四个独立 Ubuntu Runner 并行运行，另有静态检查 Job。测试失败会明确显示红色结果及分片日志，但**不会影响候选 IPA 编译、自动合并和正式 Release**。测试不需要 iOS SDK；Swift 测试程序仍需 `swiftc` 编译。

## 构建与发布

1. `.github/workflows/hermesshell-single-build.yml` 在产品 PR 上只做一次 macOS 真实 IPA 编译、产物检查与 Artifact 上传；不等待离线测试。
2. `.github/workflows/verified-release-automerge.yml` 只对版本递增且不涉及特权 CI 脚本的同仓产品 PR 自动合并，随后调度发布。它**不读取 Issue 验收矩阵或测试分片结果**。
3. `.github/workflows/hermesshell-single-promote.yml` 复用同一 PR 的 IPA，不重新编译。保留精确源码树、候选身份、Artifact digest 和正式 Release 文件校验，以防发布错包。

模拟器 UI 测试已改为**仅手动启动**：GitHub Actions → `Hermes iOS Simulator UI regression` → `Run workflow`，选择 `gold`（聊天/滚动）、`audit`（无障碍）或 `all`。每次 PR 更新、每天定时和 Release 成功后均不再自动调用；它不是发布条件。

普通维护 PR 不递增版本、不会触发产品 Release。CI/工作流/特权脚本修改仍走独立维护 PR，避免未审查的自动化脚本直接获取 GitHub 写权限——这是权限边界，不是测试门禁。

发布命名：`release-<version>-build<build>`，IPA 为 `Hermes-<version>-build<build>-unsigned.ipa`。已发布 tag 不覆盖。通知可选 `BARK_URL` Secret；真实 iPhone 使用仍需自行签名。

GitHub Issues 是未解决问题的实时来源。测试失败或未完成 Issue 应记录事实并继续修复，不得将其假报为已解决；但它们不再自动阻断新版本发布。历史 build 计划、旧门禁说明不再作为操作指引。

## 第三方声明

保留 `Vendor/Textual/LICENSE`、`Vendor/Textual/HERMES-PATCHES.md`、补丁与 `Resources/THIRD_PARTY_NOTICES.txt`；第三方许可以各自文件为准。
