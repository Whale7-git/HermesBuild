import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
let contract = ChatRequests(baseURL: URL(string:"https://host.example:49001/")!)
let history = contract.history(sessionID:"s+1 &中文", before:42)
let parts = URLComponents(url:history.url!,resolvingAgainstBaseURL:false)!
precondition(parts.path == "/api/session")
let q = Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name,$0.value!) })
precondition(q["session_id"] == "s+1 &中文")
precondition(q["msg_before"] == "42" && q["msg_limit"] == "60")
precondition(history.httpMethod == "GET")
let start = try contract.start(sessionID:"test",text:"中文\nhello")
let body = try JSONSerialization.jsonObject(with:start.httpBody!) as! [String:Any]
precondition(start.httpMethod == "POST" && body["session_id"] as? String == "test")
precondition(body["message"] as? String == "中文\nhello")
precondition(start.value(forHTTPHeaderField:"Content-Type") == "application/json")
let create = try contract.newSession()
let cb = try JSONSerialization.jsonObject(with:create.httpBody!) as! [String:Any]
precondition(cb["worktree"] as? Bool == false)
precondition(create.url!.path == "/api/session/new")
let cancel = contract.cancel(streamID:"abc:12")
precondition(cancel.httpMethod == "GET" && cancel.url!.path == "/api/chat/cancel")
let stream = contract.stream(streamID:"run",lastEventID:"run:123")
precondition(stream.value(forHTTPHeaderField:"Accept") == "text/event-stream")
let sq = URLComponents(url:stream.url!,resolvingAgainstBaseURL:false)!.queryItems!
precondition(sq.contains { $0.name == "after_event_id" && $0.value == "run:123" })
precondition(history.url!.absoluteString.contains("s%2B1"))
precondition(stream.value(forHTTPHeaderField:"Last-Event-ID") == "run:123")
// /api/chat/start 的 attachments 必须是对象数组：字符串形式会被服务端
// 归一化成 path=""，文件根本传不上去。
let payload = ChatAttachmentPayload(name:"图.png", path:"/tmp/up/图.png", mime:"image/png", size:1024, isImage:true)
let withAttachment = try contract.start(sessionID:"s1", text:"看图", attachments:[payload])
let attachBody = try JSONSerialization.jsonObject(with:withAttachment.httpBody!) as! [String:Any]
let attachList = attachBody["attachments"] as! [[String:Any]]
precondition(attachList.count == 1)
precondition(attachList[0]["path"] as? String == "/tmp/up/图.png")
precondition(attachList[0]["name"] as? String == "图.png" && attachList[0]["mime"] as? String == "image/png")
precondition(attachList[0]["is_image"] as? Bool == true && attachList[0]["size"] as? Int == 1024)
// 无附件时也要发空数组，不能省掉字段。
let noAttachment = try contract.start(sessionID:"s1", text:"纯文字")
let plainBody = try JSONSerialization.jsonObject(with:noAttachment.httpBody!) as! [String:Any]
precondition((plainBody["attachments"] as? [Any])?.isEmpty == true)
print("REQUEST_CONTRACT_PASS attachments-serialize as objects with path/name/mime/size/is_image")
