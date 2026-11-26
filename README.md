# Hermes 2.55.0 / build236

# HermesBuild

HermesBuild 是原生 iOS Hermes 多实例客户端，支持流式聊天、历史记录、附件和会话恢复。Swift target/product 名称仍为 `HermesShell`；仓库与正式构建入口为 **HermesBuild**。

## 连接

首次启动时配置自己的 Gateway API Key 或 WebUI 实例。凭据保存在 iOS Keychain。Bundle ID 固定为 `com.whale7.hermes`，用于覆盖升级。

## 开发入口

- 智能体和仓库操作规则：[`AGENTS.md`](AGENTS.md)（权威规则来源）
- 分支、PR 与 GitHub 协作速查：[`docs/github-collaboration.md`](docs/github-collaboration.md)
- iOS 专项技能：[`.agents/skills/`](.agents/skills/)
- 真机手动回归用例：[`tests/manual-master.md`](tests/manual-master.md)

常用本地检查：

```sh
python3 tests/check_navigation_contract.py
python3 tests/check_swiftui_modifiers.py
python3 tests/test_swiftui_modifiers.py
python3 -m unittest discover -s tests/releaseautomation -p 'test_*.py' -v
bash tests/run_container.sh
```

完整检查范围、并行诊断和发布规则以 `AGENTS.md` 为准。诊断失败会保留结果并继续跟踪，不作为 IPA 发布门禁；只有真实 IPA 编译及产物身份/完整性校验决定是否有可发布构件。

## 构建与发布

- 产品候选由 GitHub Actions 在 macOS 上编译一次，上传不可变 IPA Artifact。
- 正式发布复用同一候选文件，不重新编译。
- 模拟器 UI 回归仅手动启动：GitHub Actions → **Hermes iOS Simulator UI regression** → **Run workflow**。
- 普通维护 PR 不递增产品版本、不触发产品 Release。

## 第三方代码

Textual 本地副本、上游版本、许可证及 Hermes 补丁记录见 [`Vendor/Textual/`](Vendor/Textual/)；第三方声明见 `Resources/THIRD_PARTY_NOTICES.txt`。
