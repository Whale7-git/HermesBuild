import Foundation

// 这里的测试体是脚本式顶层代码（nonisolated），而被测类型
// （RuntimeLogBuffer / RuntimeLogScope / RuntimeLogUploadPolicy）都没有 actor 隔离，
// 所以 check 不该带 @MainActor；-warnings-as-errors 会把那条跨隔离调用升成错误。
// 单线程执行，计数器用 nonisolated(unsafe) 就够。
nonisolated(unsafe) var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message); checks += 1
}
var ring = RuntimeLogBuffer<Int>(capacity: 3)
check(ring.elements.isEmpty, "empty snapshot")
for value in 0..<10 { ring.append(value) }
check(ring.count == 3 && ring.elements == [7,8,9], "ordered bounded overwrite")
let snapshot = ring.elements
ring.append(10)
check(snapshot == [7,8,9] && ring.elements == [8,9,10], "snapshot immutable")
var single = RuntimeLogBuffer<String>(capacity: 0)
single.append("old"); single.append("new")
check(single.count == 1 && single.elements == ["new"], "minimum capacity")
let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-log-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let logs = root.appendingPathComponent("logs")
for index in 0..<12 {
    try RuntimeLogStorage.save(Data(repeating: 65, count: 4096), in: logs,
        filename: "runtime-log-\(String(format: "%03d", index)).txt", maxFiles: 3, maxBytes: 8192)
}
let files = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.fileSizeKey])
check(files.count == 2, "byte budget stronger than count budget")
let retainedBytes = try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
check(retainedBytes == 8192, "bounded retained bytes")
try RuntimeLogStorage.save(Data(repeating: 65, count: 9000), in: logs,
    filename: "runtime-log-big.txt", maxFiles: 3, maxBytes: 8192)
check(!FileManager.default.fileExists(atPath: logs.appendingPathComponent("runtime-log-big.txt").path), "oversize file rejected")
let sentinel = root.appendingPathComponent("sentinel")
try Data("keep".utf8).write(to: sentinel)
let link = logs.appendingPathComponent("runtime-log-link.txt")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
try RuntimeLogStorage.save(Data("new".utf8), in: logs, filename: "runtime-log-final.txt", maxFiles: 1, maxBytes: 8)
check((try? String(contentsOf: sentinel, encoding: .utf8)) == "keep", "pruning never follows a symlink")
check(FileManager.default.fileExists(atPath: link.path), "symlink is outside managed regular files")
let concurrentLogs = root.appendingPathComponent("concurrent-logs")
DispatchQueue.concurrentPerform(iterations: 32) { index in
    try! RuntimeLogStorage.save(Data(repeating: 65, count: 4096), in: concurrentLogs,
        filename: "runtime-log-concurrent-\(index).txt", maxFiles: 3, maxBytes: 8192)
}
let concurrentFiles = try FileManager.default.contentsOfDirectory(at: concurrentLogs, includingPropertiesForKeys: [.fileSizeKey])
let concurrentBytes = try concurrentFiles.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
check(concurrentFiles.count == 2 && concurrentBytes == 8192,
      "simultaneous failure snapshots obey one shared count/byte retention budget")
// A07: scope key 对会碰撞的分隔符拼接例子必须唯一。
let gluedA = RuntimeLogScope(instanceID:"a:b", accountScope:"c", sessionID:"d")
let gluedB = RuntimeLogScope(instanceID:"a", accountScope:"b:c", sessionID:"d")
check(gluedA.key != gluedB.key, "delimiter-joined triples must not collide")
check(gluedA.key == RuntimeLogScope(instanceID:"a:b", accountScope:"c", sessionID:"d").key, "same triple encodes stably")
let sessionA = RuntimeLogScope(instanceID:"inst", accountScope:"acct", sessionID:"s1")
let sessionB = RuntimeLogScope(instanceID:"inst", accountScope:"acct", sessionID:"s2")
check(sessionA.key != sessionB.key, "different sessions encode differently")
// 上传门禁：显式 opt-in 且 scope 匹配才允许提交。
check(!RuntimeLogUploadPolicy.shouldSubmit(enabled:false, scopeMatches:true), "upload disabled never submits")
check(!RuntimeLogUploadPolicy.shouldSubmit(enabled:true, scopeMatches:false), "scope mismatch never submits")
check(!RuntimeLogUploadPolicy.shouldSubmit(enabled:false, scopeMatches:false), "disabled and mismatched never submits")
check(RuntimeLogUploadPolicy.shouldSubmit(enabled:true, scopeMatches:true), "enabled and matching submits")
print("RUNTIME_LOG_STORAGE_PASS \(checks) assertions (actual ring/files; no upload)")
