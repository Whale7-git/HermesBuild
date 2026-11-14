import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message); checks += 1
}

// MARK: - 最近模型

let suite = "hermes.recentmodels.test"
let defaults = UserDefaults(suiteName: suite)!
defaults.removePersistentDomain(forName: suite)
defer { defaults.removePersistentDomain(forName: suite) }

func option(_ provider: String, _ model: String) -> ModelOption {
    ModelOption(model: model, providerID: provider, label: model, providerLabel: provider)
}

let scope = "inst|acct"
let store = RecentModelStore(defaults: defaults)

check(store.ids(scope: scope).isEmpty, "a fresh scope has no recent models")

// 1. 记录顺序：最近的在前。
store.remember(scope: scope, id: "p1/a")
store.remember(scope: scope, id: "p1/b")
store.remember(scope: scope, id: "p1/c")
check(store.ids(scope: scope) == ["p1/c", "p1/b", "p1/a"], "most recent first")

// 2. 重复选择不产生重复项，而是提到最前。
store.remember(scope: scope, id: "p1/a")
check(store.ids(scope: scope) == ["p1/a", "p1/c", "p1/b"], "re-selecting moves to front without duplicating")

// 3. 上限 3 条，最旧的被挤出。
store.remember(scope: scope, id: "p1/d")
check(store.ids(scope: scope).count == RecentModelStore.limit, "list is capped")
check(store.ids(scope: scope) == ["p1/d", "p1/a", "p1/c"], "the oldest entry is dropped")
check(!store.ids(scope: scope).contains("p1/b"), "the evicted entry is really gone")

// 4. 同名不同 provider 是不同身份，不能互相顶替。
store.remember(scope: scope, id: "p1/shared")
store.remember(scope: scope, id: "p2/shared")
check(store.ids(scope: scope).prefix(2) == ["p2/shared", "p1/shared"],
      "same model name under two providers stays distinct")

// 5. 作用域隔离。
store.remember(scope: "other|acct", id: "p9/z")
check(!store.ids(scope: scope).contains("p9/z"), "scopes do not leak into each other")

// 6. 目录里已不存在的模型不展示，但记录本身保留。
//    此时记录是 ["p2/shared", "p1/shared", "p1/d"]：只有 p2/shared 还在目录里，
//    p1/shared 与 p1/d 都是过期条目。
check(store.ids(scope: scope) == ["p2/shared", "p1/shared", "p1/d"], "state before filtering")
let catalog = [option("p1", "a"), option("p2", "shared")]
let available = store.availableIds(scope: scope, in: catalog)
check(available == ["p2/shared"], "only models still in the catalog are offered")
check(available.count < store.ids(scope: scope).count,
      "stale entries are filtered out of the offer")
check(store.ids(scope: scope).contains("p1/d"),
      "the stale id stays recorded, so a catalog that brings it back still shows it")

// 7. 空作用域与空 id 不写入。
let before = store.ids(scope: scope)
store.remember(scope: "", id: "p1/a")
store.remember(scope: scope, id: "")
check(store.ids(scope: scope) == before, "empty scope or empty id is ignored")

// 8. 持久化：新实例读到同样的顺序。
let reopened = RecentModelStore(defaults: defaults)
check(reopened.ids(scope: scope) == store.ids(scope: scope), "order survives a new instance")

// 9. 磁盘内容被外部改坏时（重复、超长）读回仍合法。
let dirty = ["p1/x", "p1/x", "p1/y", "p1/z", "p1/w"]
defaults.set(try! JSONEncoder().encode(dirty), forKey: "hermes.recentModels.dirty|acct")
let dirtyStore = RecentModelStore(defaults: defaults)
check(dirtyStore.ids(scope: "dirty|acct") == ["p1/x", "p1/y", "p1/z"],
      "duplicates are removed and the list is capped on load")

// 10. 清理：删除作用域后不再返回任何记录。
store.remove(scope: scope)
check(store.ids(scope: scope).isEmpty, "removing a scope clears it")
check(RecentModelStore(defaults: defaults).ids(scope: scope).isEmpty, "removal is persisted")

// 11. 全清。
store.remember(scope: "a|1", id: "p1/a")
store.remember(scope: "b|2", id: "p1/b")
store.clearAll()
check(store.ids(scope: "a|1").isEmpty && store.ids(scope: "b|2").isEmpty, "clearAll drops every scope")
check(RecentModelStore(defaults: defaults).ids(scope: "a|1").isEmpty, "clearAll is persisted")

// MARK: - 外部链接打开策略

check(ExternalLinkPolicy.canOpen("https://example.com/a.pdf"), "https link is openable")
check(ExternalLinkPolicy.canOpen("http://example.com/a.pdf"), "http link is openable")
check(ExternalLinkPolicy.canOpen("  https://example.com/a.pdf  "), "surrounding whitespace is tolerated")
check(ExternalLinkPolicy.canOpen("HTTPS://EXAMPLE.COM/a.pdf"), "scheme match is case-insensitive")

check(!ExternalLinkPolicy.canOpen("file:///etc/passwd"), "file scheme is refused")
check(!ExternalLinkPolicy.canOpen("javascript:alert(1)"), "javascript scheme is refused")
check(!ExternalLinkPolicy.canOpen("data:text/html;base64,PHNjcmlwdD4="), "data scheme is refused")
check(!ExternalLinkPolicy.canOpen("hermes://open?x=1"), "custom scheme is refused")
check(!ExternalLinkPolicy.canOpen("/inbox/photo.jpg"), "a bare path is not a link")
check(!ExternalLinkPolicy.canOpen("https://"), "a hostless url is refused")
check(!ExternalLinkPolicy.canOpen(""), "empty string is refused")
check(!ExternalLinkPolicy.canOpen("   "), "whitespace only is refused")

// 打开时必须原样保留路径与查询串：预览链接常带签名参数。
let signed = "https://example.com/f/report.pdf?token=abc&v=2"
check(ExternalLinkPolicy.openableURL(signed)?.absoluteString == signed,
      "the url is passed through unchanged, query included")

print("RECENT_MODEL_PASS \(checks) assertions (real store + link policy; isolated suite)")
