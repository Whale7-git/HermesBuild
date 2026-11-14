import Foundation

@MainActor final class AttachmentService: NativeChatService {
    var received: [ChatAttachmentPayload] = []
    var body: Data?
    var legacyCalls = 0
    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot { throw URLError(.unsupportedURL) }
    func stopNativeTurn(streamID: String) async throws {}
    func streamNativeTurn(streamID: String, lastEventID: String?, onFrame: (SSEFrame) async throws -> Bool) async throws {}
    func startNativeTurn(sessionID: String, text: String) async throws -> String { legacyCalls += 1; return "legacy" }
    func startNativeTurn(sessionID: String, text: String, attachments: [ChatAttachmentPayload]) async throws -> String {
        received = attachments
        body = try ChatRequests(baseURL: URL(string: "https://fixture.invalid/p/test")!)
            .start(sessionID: sessionID, text: text, attachments: attachments).httpBody
        return "attachment-turn"
    }
}

@MainActor final class TextOnlyService: NativeChatService {
    var calls = 0
    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot { throw URLError(.unsupportedURL) }
    func stopNativeTurn(streamID: String) async throws {}
    func streamNativeTurn(streamID: String, lastEventID: String?, onFrame: (SSEFrame) async throws -> Bool) async throws {}
    func startNativeTurn(sessionID: String, text: String) async throws -> String { calls += 1; return "text-turn" }
}

@main struct AttachmentDispatchTests {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        let items = [
            ChatAttachmentPayload(name: "图片 + 例子.png", path: "/server/opaque/photo.png", mime: "image/png", size: 42, isImage: true),
            ChatAttachmentPayload(name: "notes.txt", path: "/server/opaque/notes.txt", mime: "text/plain", size: 7, isImage: false)
        ]
        let concrete = AttachmentService()
        let service: any NativeChatService = concrete
        let stream = try await service.startNativeTurn(sessionID: "fixture-session", text: "（仅附件）", attachments: items)
        expect(stream == "attachment-turn" && concrete.legacyCalls == 0, "protocol existential must use the attachment requirement witness")
        expect(concrete.received == items, "attachment names, paths and image metadata survive dynamic dispatch")
        let json = try JSONSerialization.jsonObject(with: concrete.body!) as! [String: Any]
        let payload = json["attachments"] as! [[String: Any]]
        expect(payload.count == 2, "both uploaded files enter the actual request builder")
        expect(payload[0]["path"] as? String == items[0].path && payload[0]["name"] as? String == items[0].name, "opaque server path is not rewritten on the client")
        expect(payload[0]["mime"] as? String == "image/png" && payload[0]["is_image"] as? Bool == true, "vision routing metadata remains present; this does not execute vision")
        expect(payload[1]["is_image"] as? Bool == false && payload[1]["size"] as? Int == 7, "ordinary file metadata remains present")
        let textOnly = TextOnlyService()
        let fallback: any NativeChatService = textOnly
        let textStream = try await fallback.startNativeTurn(sessionID: "fixture-session", text: "text", attachments: [])
        expect(textStream == "text-turn" && textOnly.calls == 1, "empty attachment lists retain text-only compatibility")
        var refused = false
        do { _ = try await fallback.startNativeTurn(sessionID: "fixture-session", text: "files", attachments: items) }
        catch { refused = true }
        expect(refused && textOnly.calls == 1, "a text-only fallback must refuse files instead of silently sending without them")

        // Exercise exactly the four user-facing attachment combinations through
        // the existential witness and production JSON request builder.
        let cases: [(String, [ChatAttachmentPayload])] = [
            ("（仅附件）", [items[0]]),
            ("描述图片", [items[0]]),
            ("（仅附件）", [items[1]]),
            ("（仅附件）", items)
        ]
        for (index, fixture) in cases.enumerated() {
            _ = try await service.startNativeTurn(sessionID: "fixture-session", text: fixture.0, attachments: fixture.1)
            let body = try JSONSerialization.jsonObject(with: concrete.body!) as! [String: Any]
            expect(body["message"] as? String == fixture.0, "case \(index): original prompt preserved")
            expect(body["session_id"] as? String == "fixture-session", "case \(index): session preserved")
            let actual = body["attachments"] as! [[String: Any]]
            expect(NSArray(array: actual).isEqual(to: fixture.1.map(\.jsonObject)), "case \(index): every path, name, MIME, size and image flag survives")
        }

        print("ATTACHMENT_DISPATCH_PASS \(checks) assertions (actual protocol/request; no server or vision request)")
    }
}
