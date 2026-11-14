import Foundation

extension ModelTests {
    @MainActor static func placeholderOriginTests() async throws {
        let scope = "placeholder-origin-test-" + UUID().uuidString
        let store = ChatAttachmentPlaceholderStore.shared
        defer { store.removeScope(scope) }
        let payload = ChatAttachmentPayload(name: "image.png", path: "/fixture/image.png", mime: "image/png", size: 3, isImage: true)

        // Exercise the actual send/mark path, not a manually prepared ID set.
        let manualService = FakeChatService()
        manualService.failStart = true
        let manual = NativeChatModel(sessionID: "manual", api: manualService, displayScope: scope)
        await manual.load()
        manual.draft = ChatAttachmentPlaceholder.systemText
        _ = await manual.send(attachments: [payload])
        precondition(store.markedIDs(scope: scope, sessionID: "manual").isEmpty)
        precondition(manualService.lastAttachmentPaths == [payload.path])
        await manual.refresh()
        precondition(manual.canResendPending)
        _ = await manual.resendPending()
        precondition(store.markedIDs(scope: scope, sessionID: "manual").isEmpty)
        manual.disconnect()

        let pureService = FakeChatService()
        pureService.failStart = true
        let pure = NativeChatModel(sessionID: "pure", api: pureService, displayScope: scope)
        await pure.load()
        pure.draft = " \n "
        _ = await pure.send(attachments: [payload])
        guard let first = pure.pendingUserMessageID() else { preconditionFailure("missing local row") }
        precondition(store.markedIDs(scope: scope, sessionID: "pure") == [first])
        await pure.refresh()
        _ = await pure.resendPending()
        guard let second = pure.pendingUserMessageID() else { preconditionFailure("missing retried row") }
        precondition(second != first && store.markedIDs(scope: scope, sessionID: "pure") == [second])
        await pure.refresh()
        pure.discardPending()
        precondition(store.markedIDs(scope: scope, sessionID: "pure").isEmpty)
        pure.draft = ChatAttachmentPlaceholder.systemText
        _ = await pure.send(attachments: [payload])
        precondition(store.markedIDs(scope: scope, sessionID: "pure").isEmpty,
                     "a manual later message cannot inherit the abandoned system marker")
        pure.disconnect()
        print("MODEL_PASS build53 actual send/manual origin/retry/discard isolation")
    }
}
