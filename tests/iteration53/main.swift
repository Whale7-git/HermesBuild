import Foundation

@main struct Iteration53Tests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); checks += 1; print("BUILD53_PASS " + label)
        }
        var merge = ParagraphMergeState(finished: true)
        merge.update(finished: true, selecting: true)
        check(merge.enabled, "selecting completed text never unmerges its native view")
        merge = ParagraphMergeState(finished: false)
        merge.update(finished: true, selecting: true)
        check(!merge.enabled, "completion during selection defers merging")
        merge.update(finished: true, selecting: false)
        check(merge.enabled, "ending selection permits the one-way merge")
        merge.update(finished: true, selecting: true)
        check(merge.enabled, "a later selection retains the merged structure")
        merge.update(finished: false, selecting: false)
        check(!merge.enabled, "a new streaming document resets its mode")

        var edits = ImageEditHistory()
        check(!edits.append(.crop(.init(x: 0.9, y: 0, width: 0.2, height: 1))), "crop outside the source is rejected")
        check(!edits.append(.crop(.init(x: 0, y: 0, width: .nan, height: 1))), "nonfinite crop is rejected")
        check(edits.append(.crop(.full)), "full crop accepted")
        let mark = ImageEditMark(kind: .arrow, color: .red, points: [.init(x: -1, y: 2), .init(x: 0.8, y: 0.5)])
        check(mark.points.first == ImageEditPoint(x: 0, y: 1), "mark coordinates are clamped")
        check(edits.append(.mark(mark)) && edits.steps.count == 2, "crop and mark keep their operation order")
        edits.undo()
        check(edits.steps == [.crop(.full)], "undo removes only the last operation")
        edits.reset()
        check(!edits.canUndo, "reset restores the original edit plan")
        for _ in 0..<ImageEditHistory.limit { _ = edits.append(.rotateClockwise) }
        check(!edits.append(.rotateClockwise), "operation history has a memory/work budget")

        for count in [0, 1, 2, 3, 4, 5, 9] {
            check(AttachmentGridPlan.visibleCount(count) + AttachmentGridPlan.overflow(count) == count,
                  "grid count and hidden count agree for \(count) images")
        }
        let messages = [ChatMessage(id: "a", role: "user", content: "", attachmentPaths: ["a.png", "a.png", ""]),
            ChatMessage(id: "b", role: "assistant", content: "none"),
            ChatMessage(id: "c", role: "user", content: "", attachmentPaths: ["a.png", "b.pdf"])]
        let catalog = AttachmentCatalog.entries(messages)
        check(catalog.map(\.id) == ["c", "a"], "overview orders attachment-bearing messages newest first")
        check(catalog.last?.paths == ["a.png"], "overview de-duplicates only within one message")
        check(catalog.first?.rowID == "m-c", "overview uses the transcript's actual row identity")

        var batch = AttachmentBatch(sessionID: "edit", maxTotalBytes: 12)
        let id = try batch.append(name: "original.png", mime: "image/png", data: Data([1, 2, 3]))
        let oldAttempt = try batch.begin(id)
        let old = UploadedAttachment(name: "original.png", path: "/old.png", size: 3, mime: "image/png", isImage: true)
        batch.complete(id, attempt: oldAttempt, attachment: old)
        _ = try batch.append(name: "file.txt", mime: "text/plain", data: Data([8, 9]))
        try batch.replace(id, name: "edited.jpg", mime: "image/jpeg", data: Data([4, 5, 6, 7]))
        batch.complete(id, attempt: oldAttempt, attachment: old)
        check(!batch.canSend && batch.items.first?.state == .queued, "edited image invalidates the ready payload and old completion")
        check(batch.items.first?.id == id && batch.items.first?.data == Data([4, 5, 6, 7]), "replacement preserves chip identity but sends new bytes")
        check(batch.items.first?.reuploading == true, "an edited chip reports its own re-upload state")
        do {
            try batch.replace(id, name: "oversize.jpg", mime: "image/jpeg", data: Data(repeating: 1, count: 11))
            preconditionFailure("over-budget replacement was accepted")
        } catch { check(batch.items.first?.name == "edited.jpg", "rejected replacement leaves the previous draft intact") }

        var uploads: [AttachmentDraft] = []
        var replies: [CheckedContinuation<UploadedAttachment, Error>] = []
        let coordinator = AttachmentUploadCoordinator(sessionID: "replacement") { _, draft, _ in
            uploads.append(draft)
            return try await withCheckedThrowingContinuation { replies.append($0) }
        }
        let replacementID = try coordinator.add(name: "original.png", mime: "image/png", data: Data([1]))
        while replies.count < 1 { await Task.yield() }
        try coordinator.replace(replacementID, name: "edited.jpg", mime: "image/jpeg", data: Data([2, 3]))
        while replies.count < 2 { await Task.yield() }
        replies[0].resume(returning: old)
        for _ in 0..<30 { await Task.yield() }
        check(!coordinator.batch.canSend, "late old upload cannot mark the edited chip ready")
        let edited = UploadedAttachment(name: "edited.jpg", path: "/edited.jpg", size: 2, mime: "image/jpeg", isImage: true)
        replies[1].resume(returning: edited)
        for _ in 0..<1000 {
            if coordinator.batch.canSend { break }
            await Task.yield()
        }
        check(uploads.map(\.data) == [Data([1]), Data([2, 3])], "replacement upload receives edited bytes")
        check(try coordinator.batch.payload(for: "replacement") == [edited], "only edited server reference enters the outgoing payload")

        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ratios53-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImageRatioStore(directory: directory)
        let before = store.token(scope: "one")
        let other = store.token(scope: "two")
        store.remove(scope: "one")
        store.remember(token: before, sessionID: "s", path: "late.png", ratio: 2)
        check(store.snapshot(scope: "one", sessionID: "s").count == 0, "late measurement after scope removal cannot resurrect memory")
        store.remember(token: other, sessionID: "s", path: "live.png", ratio: 1)
        check(store.snapshot(scope: "two", sessionID: "s").count == 1, "removing one scope does not invalidate another scope's request")
        store.remember(token: store.token(scope: "one"), sessionID: "s", path: "fresh.png", ratio: 3)
        check(store.snapshot(scope: "one", sessionID: "s").count == 1, "a fresh request after removal can write")
        let beforeClear = store.token(scope: "one")
        store.clearAll()
        store.remember(token: beforeClear, sessionID: "s", path: "late-again.png", ratio: 4)
        store.flushPendingWrites()
        check(store.snapshot(scope: "one", sessionID: "s").count == 0, "clearAll also invalidates measurements already in flight")

        let seed = ImageRatioStore(directory: directory)
        seed.remember(token: seed.token(scope: "cold"), sessionID: "s", path: "old.png", ratio: 2)
        seed.flushPendingWrites()
        let cold = ImageRatioStore(directory: directory)
        cold.remember(token: cold.token(scope: "cold"), sessionID: "s", path: "new.png", ratio: 1)
        cold.preloadSynchronously(scope: "cold")
        cold.flushPendingWrites()
        check(cold.snapshot(scope: "cold", sessionID: "s").count == 2, "new measurement before cold preload preserves existing disk entries")
        print("BUILD53_OFFLINE_CHECKS \(checks)")
    }
}
