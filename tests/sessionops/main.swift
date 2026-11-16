import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { print("FAIL: \(message)"); exit(1) }
}

let contract = ChatRequests(baseURL: URL(string: "https://host.example:49001/")!)

// Models catalog route.
let models = contract.models()
expect(models.url!.path == "/api/models", "models path")
expect(models.httpMethod == "GET", "models is GET")

// Session-scoped model switch.
let setModel = try contract.sessionModel(sessionID: "s1", model: "gpt-6.1-sol", provider: "openai-codex")
let modelBody = try JSONSerialization.jsonObject(with: setModel.httpBody!) as! [String: Any]
expect(setModel.url!.path == "/api/session/update", "session model path is the deployed update route")
expect(modelBody["session_id"] as? String == "s1", "session model carries session id")
expect(modelBody["model"] as? String == "gpt-6.1-sol", "session model carries model")
expect(modelBody["model_provider"] as? String == "openai-codex", "session model carries provider")

// A provider-less pick must send an explicit null, not an omitted key: the
// server treats an absent model_provider as "keep the old one".
let clearProvider = try contract.sessionModel(sessionID: "s1", model: "fixture", provider: nil)
let clearBody = try JSONSerialization.jsonObject(with: clearProvider.httpBody!) as! [String: Any]
expect(clearBody["model_provider"] is NSNull, "provider-less pick sends explicit null")
expect(clearBody.index(forKey: "model_provider") != nil, "provider key is present so the server sees the change")

// Rename / pin / archive / delete.
let rename = try contract.rename(sessionID: "s1", title: "新标题")
let renameBody = try JSONSerialization.jsonObject(with: rename.httpBody!) as! [String: Any]
expect(rename.url!.path == "/api/session/rename" && rename.httpMethod == "POST", "rename route")
expect(renameBody["title"] as? String == "新标题", "rename carries title")

let pin = try contract.pin(sessionID: "s1", pinned: true)
let pinBody = try JSONSerialization.jsonObject(with: pin.httpBody!) as! [String: Any]
expect(pin.url!.path == "/api/session/pin", "pin route")
expect(pinBody["pinned"] as? Bool == true, "pin carries flag")

let unpin = try contract.pin(sessionID: "s1", pinned: false)
let unpinBody = try JSONSerialization.jsonObject(with: unpin.httpBody!) as! [String: Any]
expect(unpinBody["pinned"] as? Bool == false, "unpin sends false rather than omitting the key")

let archive = try contract.archive(sessionID: "s1", archived: true)
let archiveBody = try JSONSerialization.jsonObject(with: archive.httpBody!) as! [String: Any]
expect(archive.url!.path == "/api/session/archive", "archive route")
expect(archiveBody["archived"] as? Bool == true, "archive carries flag")

let delete = try contract.deleteSession(sessionID: "s1")
let deleteBody = try JSONSerialization.jsonObject(with: delete.httpBody!) as! [String: Any]
expect(delete.url!.path == "/api/session/delete", "delete route")
expect(deleteBody["session_id"] as? String == "s1", "delete carries session id")

// Branch: without keep_count the server forks the full history, so an
// unspecified count must omit the key rather than send 0 (which means empty).
let branchAll = try contract.branch(sessionID: "s1", keepCount: nil, title: nil)
let branchAllBody = try JSONSerialization.jsonObject(with: branchAll.httpBody!) as! [String: Any]
expect(branchAll.url!.path == "/api/session/branch", "branch route")
expect(branchAllBody.index(forKey: "keep_count") == nil, "full branch omits keep_count instead of sending 0")

let branchPartial = try contract.branch(sessionID: "s1", keepCount: 4, title: "分支")
let branchPartialBody = try JSONSerialization.jsonObject(with: branchPartial.httpBody!) as! [String: Any]
expect(branchPartialBody["keep_count"] as? Int == 4, "partial branch carries keep_count")
expect(branchPartialBody["title"] as? String == "分支", "partial branch carries title")

// ---- /api/models 目录解析（真实响应形态）----
let catalogJSON = """
{"active_provider":"custom:fixture","default_model":"fixture",
 "groups":[{"provider":"fixture","provider_id":"custom:fixture","models":[{"id":"fixture","label":"Fixture"},{"id":"glm-5.3","label":"GLM 5.3"}]},
           {"provider":"openai-codex","provider_id":"openai-codex","models":[{"id":"gpt-6.1-sol","label":"GPT 6.1 Sol"}]}],
 "aliases":{}}
"""
let catalog = try ModelCatalog(data: Data(catalogJSON.utf8))
expect(catalog.options.count == 3, "catalog keeps every provider/model pair")
expect(catalog.defaultModel == "fixture", "catalog exposes default model")
expect(catalog.option(matching: "fixture", provider: "custom:fixture")?.label == "Fixture", "exact provider match picks the right label")
expect(catalog.option(matching: "gpt-6.1-sol", provider: nil)?.providerID == "openai-codex", "model-only match still resolves its provider")
expect(catalog.option(matching: "not-there", provider: nil) == nil, "unknown model resolves to nil rather than inventing an entry")

// Same model id under two providers must not collapse: switching needs the
// provider, so dedupe on model alone would silently drop one target.
let dupJSON = """
{"groups":[{"provider":"a","provider_id":"a","models":[{"id":"m1","label":"M1 (a)"}]},
           {"provider":"b","provider_id":"b","models":[{"id":"m1","label":"M1 (b)"}]}]}
"""
let dup = try ModelCatalog(data: Data(dupJSON.utf8))
expect(dup.options.count == 2, "same model under two providers is not deduped away")
expect(dup.option(matching: "m1", provider: nil) == nil,
       "ambiguous provider-less model ID cannot display a guessed label")
expect(dup.option(matching: "m1", provider: "b")?.label == "M1 (b)",
       "exact provider/model pair resolves the correct UI label")
expect(dup.option(matching: "m1", provider: "unknown") == nil,
       "unknown provider never falls back to another provider")
expect(dup.options.map(\.providerID) == ["a", "b"], "both providers survive, in catalog order")

// An error payload must throw, not present as an empty catalog.
do {
    _ = try ModelCatalog(data: Data(#"{"error":"models unavailable"}"#.utf8))
    expect(false, "error payload must throw")
} catch {
    expect("\(error)".contains("models unavailable"), "server error text is preserved")
}
// Malformed shape must throw too — never a silent empty picker.
do {
    _ = try ModelCatalog(data: Data("[]".utf8))
    expect(false, "non-object payload must throw")
} catch { }

// 分支响应两种形态；都不匹配时必须返回 nil 而不是编一个 ID。
let flatBranch = #"{"session_id":"new-1","title":"Untitled (fork)","parent_session_id":"old-1"}"#
expect(BranchResponse.sessionID(from: Data(flatBranch.utf8)) == "new-1", "flat branch response parsed")
let nestedBranch = #"{"session":{"session_id":"new-2"}}"#
expect(BranchResponse.sessionID(from: Data(nestedBranch.utf8)) == "new-2", "nested branch response parsed")
expect(BranchResponse.sessionID(from: Data(#"{"session_id":"  "}"#.utf8)) == nil, "blank branch id rejected")
expect(BranchResponse.sessionID(from: Data(#"{"ok":true}"#.utf8)) == nil, "unknown branch shape rejected instead of guessed")

// A05: setModel 成功后本地行必须同步更新。本编译组只含
// ChatRequests/Models/ChatCore，不包含 AppState（openedSession 为其 private
// 状态且不在本组），这里回归验证 applyModel 复用的 withModel 原语；
// openedSession 全链路需真机/集成验证。
let listedRow = SessionSummary.placeholder(id:"s1")
let updatedRow = listedRow.withModel("gpt-6.1-sol")
expect(updatedRow.model == "gpt-6.1-sol", "confirmed model switch updates the local row")
expect(updatedRow.sessionId == listedRow.sessionId && updatedRow.title == listedRow.title
       && updatedRow.pinned == listedRow.pinned && updatedRow.archived == listedRow.archived,
       "model update keeps the row identity")
expect(listedRow.model == nil, "withModel returns a copy instead of mutating the list row")

print("SESSION_OPS_PASS \(checks) assertions")
