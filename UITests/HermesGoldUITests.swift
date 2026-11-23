import XCTest

final class HermesGoldUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Distinguish a real accepted POST from optimistic local bubbles before
    /// diagnosing SSE rendering or manual-reading scroll. This endpoint is
    /// loopback-only and never retries the original chat submission.
    @MainActor private func requestLedger() async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:8765/__control/log")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "Mock request ledger must be readable")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor private func acceptedRunPOSTCount() async throws -> Int {
        let root = try await requestLedger()
        let requests = try XCTUnwrap(root["requests"] as? [[String: Any]])
        return requests.filter {
            ($0["method"] as? String) == "POST" && ($0["path"] as? String) == "/v1/runs"
        }.count
    }

    @MainActor private func acceptedRuns() async throws -> [[String: Any]] {
        let ledger = try await requestLedger()
        return try XCTUnwrap(ledger["accepted_runs"] as? [[String: Any]])
    }

    @MainActor private func deliveredEvents() async throws -> [String] {
        let ledger = try await requestLedger()
        return try XCTUnwrap(ledger["delivered_event_ids"] as? [String])
    }

    @MainActor private func waitForDeliveredEvent(_ eventID: String) async throws {
        for _ in 0..<50 {
            if try await deliveredEvents().contains(eventID) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Gateway did not deliver SSE sequence \(eventID); layout assertion is invalid")
    }


    @MainActor private func waitForSingleAcceptedPOST() async throws {
        for attempt in 0..<30 {
            let count = try await acceptedRunPOSTCount()
            if count == 1 { return }
            XCTAssertLessThanOrEqual(count, 1, "Client replayed the accepted chat POST")
            if attempt < 29 { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        XCTFail("No accepted /v1/runs POST after send tap; cannot attribute missing text or scroll jump to SSE")
    }

    /// A recorded HTTP attempt is not a Gateway admission. Observe the
    /// authoritative fixture receipt before checking the rendering path.
    @MainActor private func waitForSingleAcceptedRun() async throws -> [[String: Any]] {
        for attempt in 0..<30 {
            let receipts = try await acceptedRuns()
            XCTAssertLessThanOrEqual(receipts.count, 1, "Gateway admitted duplicate runs")
            if receipts.count == 1 { return receipts }
            if attempt < 29 { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        XCTFail("Run POST reached the fixture but was not accepted")
        return []
    }

    /// XCTest's .any.firstMatch can resolve to different virtualized SwiftUI
    /// descendants after a layout commit. Never infer a UIKit viewport jump
    /// from its isHittable/activation point or an unrelated accessibility frame.
    private func viewportContains(_ frame: CGRect, inside viewport: CGRect) -> Bool {
        guard !frame.isNull, !frame.isEmpty,
              !viewport.isNull, !viewport.isEmpty else { return false }
        let intersection = frame.intersection(viewport)
        return !intersection.isNull && intersection.width > 2 && intersection.height > 2
    }

    /// Read actual UIKit row frames emitted by the opt-in StableChatScrollView
    /// diagnostics, which use the stable turnAnchor row identity.
    private func traceFrame(_ field: String, in trace: String) -> CGRect? {
        let prefix = field + "=("
        guard let contents = trace.components(separatedBy: prefix).dropFirst().first,
              let raw = contents.split(separator: ")").first else { return nil }
        let values = raw.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard values.count == 4, values.allSatisfy(\.isFinite) else { return nil }
        return CGRect(x: CGFloat(values[0]), y: CGFloat(values[1]),
                      width: CGFloat(values[2]), height: CGFloat(values[3]))
    }

    private func traceValue(_ field: String, in trace: String) -> String? {
        let prefix = field + "="
        return trace.split(separator: ";").first {
            $0.hasPrefix(prefix)
        }.map { String($0.dropFirst(prefix.count)) }
    }

    /// Gold 1: the real session row must open a functioning chat composer.
    func test01ConnectionAndSessionList() {
        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)
    }

    /// Gold 2: UI sends a single message and observes scripted SSE completion.
    // Network setup is async but XCUIApplication gestures must remain on
    // XCTest's main actor; otherwise launch throws NSInternalInconsistencyException.
    @MainActor func test02SendStreamAndComplete() async throws {
        // Isolate SSE expectations from image and selection fixtures injected
        // by prior UI suites. All tests run against the same loopback process.
        var reset = URLRequest(url: URL(string:
            "http://127.0.0.1:8765/__control/reset")!)
        reset.httpMethod = "POST"
        let (_, initialResponse) = try await URLSession.shared.data(for: reset)
        XCTAssertEqual((initialResponse as? HTTPURLResponse)?.statusCode, 200,
                       "Mock gateway reset failed before SSE test")
        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)
        // Make the terminal SSE arrive before the mock persists its answer.
        var config = URLRequest(url: URL(string:
            "http://127.0.0.1:8765/__control/finalization-lag")!)
        config.httpMethod = "POST"
        config.setValue("application/json", forHTTPHeaderField: "Content-Type")
        config.httpBody = Data(#"{"delay_ms":350}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: config)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let editor = app.textViews.matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "消息输入框")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        let focused = app.textViews.matching(
            NSPredicate(format: "hasKeyboardFocus == 1")).firstMatch
        if !focused.exists {
            // A history layout update can move the editor immediately after tap.
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(focused.waitForExistence(timeout: 7),
                      "Chat editor did not gain focus after two real taps")
        editor.typeText("UI test: one message")
        let send = app.buttons["发送消息"]
        XCTAssertTrue(send.waitForExistence(timeout: 15), "Send control missing")
        XCTAssertTrue(send.isEnabled)
        send.tap()
        try await waitForSingleAcceptedPOST()
        let receipts = try await waitForSingleAcceptedRun()
        XCTAssertEqual(receipts.count, 1, "Attempt ledger is not proof of an accepted POST")
        XCTAssertEqual(receipts.first?["session_id"] as? String, "ui-session-1")
        XCTAssertTrue((receipts.first?["run_id"] as? String)?.hasPrefix("ui-run-") == true)
        let text = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "第二段回复已送达")).firstMatch
        // The transcript virtualizes long histories; a completed reply can
        // exist beyond the viewport even after the one SSE GET succeeded.
        // Still require the exact rendered reply, not just a network request.
        let transcript = app.scrollViews.firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10),
                      "Chat transcript missing after sending")
        func replyInViewport() -> Bool {
            text.exists && viewportContains(text.frame, inside: transcript.frame)
        }
        if !(text.waitForExistence(timeout: 12) && replyInViewport()) {
            for _ in 0..<24 {
                if replyInViewport() { break }
                transcript.swipeUp()
            }
        }
        if !replyInViewport() {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "sse-reply-not-visible-after-scroll"
            screenshot.lifetime = .keepAlways
            XCTContext.runActivity(named: "Failed SSE visible transcript") {
                $0.add(screenshot)
            }
        }
        XCTAssertTrue(replyInViewport(),
                      "Gold2 rendered SSE reply is outside the transcript viewport; "
                      + "reply=\(text.frame), transcript=\(transcript.frame)")
        XCTAssertTrue(app.buttons["发送消息"].waitForExistence(timeout: 30),
                      "Finished Run did not restore the idle Send control")
        // An empty draft can legitimately disable Send. Type a new *unsent*
        // draft to prove the terminal Run unlocked the composer without replay.
        editor.tap()
        editor.typeText("next unsent draft")
        XCTAssertTrue(app.buttons["发送消息"].isEnabled,
                      "Terminal Run must restore composer send availability")
        let postCount = try await acceptedRunPOSTCount()
        XCTAssertEqual(postCount, 1,
                       "Typing after completion must not submit another POST")
    }

    /// Gold 3: contentOffset must change in a real rendered long-answer reader.
    @MainActor func test03ReaderProgressAdvancesOnSwipe() async throws {
        // Test-specific image and text fixtures added by earlier UI suites
        // must not displace the long-answer reader from its deterministic
        // baseline. Reset the isolated loopback server before this test.
        var reset = URLRequest(url: URL(string:
            "http://127.0.0.1:8765/__control/reset")!)
        reset.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: reset)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "Mock gateway baseline reset failed")
        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)
        let thread = app.scrollViews.firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 10),
                      "Chat transcript has no UIScrollView")
        // Open the build216 direct long-answer shortcut, not an ellipsis menu.
        let read = app.buttons["专注阅读这条长回复"].firstMatch
        for _ in 0..<24 {
            if read.exists && read.isHittable { break }
            thread.swipeUp()
        }
        XCTAssertTrue(read.waitForExistence(timeout: 8) && read.isHittable,
                      "Completed long answer has no hittable reader shortcut")
        read.tap()
        XCTAssertTrue(app.navigationBars["阅读模式"].waitForExistence(timeout: 12),
                      "Reader sheet did not open")
        let progress = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "阅读进度 ")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10),
                      "Reader does not expose its progress")
        func percent() -> Int {
            Int(progress.label.filter { $0.isNumber }) ?? -1
        }
        let before = percent()
        XCTAssertGreaterThanOrEqual(before, 0)
        let reader = app.scrollViews.firstMatch
        XCTAssertTrue(reader.exists, "Reader has no UIScrollView")
        for _ in 0..<4 { reader.swipeUp() }
        XCTAssertGreaterThan(percent(), before,
                             "Four reader swipes did not increase reading progress")
    }
    /// Gold 4: a short manual downward pan during live SSE output must leave
    /// the current reading anchor alone when additional reply text arrives.
    @MainActor func test04StreamingManualReadingKeepsAnchor() async throws {
        func control(_ path: String, body: String = "{}") async throws {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:8765" + path)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }
        try await control("/__control/reset")
        let app = HermesUITestHarness.launchAndConnect(extraLaunchArguments: ["--hermes-scroll-trace"])
        HermesUITestHarness.openSession(app)
        try await control("/__control/stream-interval", body: #"{"delay_ms":250}"#)
        // Pause after the first real delta. Gold4 releases the next delta
        // only AFTER the UIKit manual pan; timing cannot accidentally finish SSE.
        try await control("/__control/stream-grow", body: #"{"lines":40}"#)
        try await control("/__control/stream-pause", body: #"{"after_seq":"2"}"#)
        let editor = app.textViews.matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "消息输入框")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("UI streamed reading anchor")
        let send = app.buttons["发送消息"]
        XCTAssertTrue(send.waitForExistence(timeout: 12) && send.isEnabled)
        send.tap()
        try await waitForSingleAcceptedPOST()
        let admission = try await waitForSingleAcceptedRun()
        XCTAssertEqual(admission.count, 1, "Gold4 needs one truly admitted Run")
        try await waitForDeliveredEvent("2")
        let user = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "UI streamed reading anchor")).firstMatch
        XCTAssertTrue(user.waitForExistence(timeout: 12),
                      "Sent question must be present before the manual pan")
        let transcript = app.scrollViews.firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let trace = app.descendants(matching: .any).matching(identifier: "HermesScrollTrace").firstMatch
        XCTAssertTrue(trace.waitForExistence(timeout: 10),
                      "Opt-in UIKit scroll diagnostics must be exposed to XCTest")

        // isHittable alone does not prove the post-send focus command has
        // completed. A pan intentionally cancels a still-pending navigation;
        // wait for the measured question row to reach its focus position.
        let focusReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let value = trace.value as? String ?? ""
                return value.contains("focus=applied")
                    && value.contains("navigationTarget=none")
                    && user.isHittable
                    && user.frame.minY <= transcript.frame.minY + 180
                    && user.frame.maxY <= transcript.frame.maxY
            },
            object: trace)
        let focusResult = XCTWaiter.wait(for: [focusReady], timeout: 10)
        let prePanTrace = trace.value as? String ?? "missing"
        print("HERMES_MANUAL_ANCHOR prePan frame=\(user.frame)"
              + " transcript=\(transcript.frame) trace=\(prePanTrace)")
        XCTAssertEqual(focusResult, .completed,
                       "The measured user-turn focus must settle before manual reading: \(prePanTrace)")

        let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.38))
        let end = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.52))
        start.press(forDuration: 0.25, thenDragTo: end)
        // Let UIKit deceleration settle before measuring. A new SSE delta
        // arrives during the next interval, while the reader is detached.
        try await Task.sleep(nanoseconds: 650_000_000)
        let postPanTrace = trace.value as? String ?? "missing"
        let postPanRow = try XCTUnwrap(traceFrame("userFrame", in: postPanTrace),
                                        "Gold4 missing actual UIKit user row geometry after pan")
        let postPanViewport = try XCTUnwrap(traceFrame("transcriptFrame", in: postPanTrace),
                                             "Gold4 missing actual UIKit viewport after pan")
        let anchoredID = try XCTUnwrap(traceValue("turnAnchor", in: postPanTrace),
                                        "Gold4 missing stable turn ID after pan")
        if !viewportContains(postPanRow, inside: postPanViewport) {
            let postCount = try await acceptedRunPOSTCount()
            print("HERMES_MANUAL_ANCHOR postPan row=\(postPanRow)"
                  + " viewport=\(postPanViewport)"
                  + " a11yFrame=\(user.frame)"
                  + " trace=\(postPanTrace)"
                  + " acceptedPOSTs=\(postCount)")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "manual-pan-question-not-visible"
            screenshot.lifetime = .keepAlways
            XCTContext.runActivity(named: "Post-pan viewport evidence") { $0.add(screenshot) }
        }
        XCTAssertTrue(viewportContains(postPanRow, inside: postPanViewport),
                      "Gold4 POST_PAN UIKit user row left viewport: \(postPanTrace)")
        XCTAssertNotEqual(anchoredID, "none", "Gold4 has no anchored user turn")
        let before = postPanRow.midY
        let initialTrace = trace.value as? String ?? ""
        func contentSize(_ value: String) -> Double? {
            guard let tail = value.components(separatedBy: "contentSize=").dropFirst().first,
                  let raw = tail.split(separator: ";").first else { return nil }
            return Double(raw)
        }
        let initialHeight = try XCTUnwrap(contentSize(initialTrace),
                                          "UIKit contentSize missing before SSE resume")
        try await control("/__control/stream-resume")
        try await waitForDeliveredEvent("3")
        // The mock injects 40 Markdown lines into delta 3. Require a measured
        // contentSize increase instead of an arbitrary time delay.
        var postStreamTrace = trace.value as? String ?? "missing"
        var grew = false
        for _ in 0..<50 {
            postStreamTrace = trace.value as? String ?? "missing"
            if let height = contentSize(postStreamTrace), height > initialHeight + 1 {
                grew = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(grew,
                      "No observed UIKit layout growth after delivered SSE delta: \(postStreamTrace)")
        let postStreamRow = try XCTUnwrap(traceFrame("userFrame", in: postStreamTrace),
                                           "Gold4 missing UIKit user row after SSE")
        let postStreamViewport = try XCTUnwrap(traceFrame("transcriptFrame", in: postStreamTrace),
                                                "Gold4 missing viewport after SSE")
        let after = postStreamRow.midY
        let afterID = try XCTUnwrap(traceValue("turnAnchor", in: postStreamTrace),
                                    "Gold4 lost user turn ID during SSE")
        XCTAssertEqual(afterID, anchoredID,
                       "Gold4 SSE changed the stable user turn row identity")
        XCTAssertTrue(viewportContains(postStreamRow, inside: postStreamViewport),
                      "Gold4 SSE_ROW_VISIBLE failed: userRow=\(postStreamRow), "
                      + "viewport=\(postStreamViewport), trace=\(postStreamTrace)")
        print("HERMES_MANUAL_ANCHOR postStream before=\(before) after=\(after)"
              + " UIKitRow=\(postStreamRow) A11yFrame=\(user.frame)"
              + " trace=\(postStreamTrace)")
        XCTAssertLessThan(abs(after - before), 28,
                          "Gold4 SSE_ANCHOR_DRIFT \(abs(after - before))pt (limit <28pt): "
                          + postStreamTrace)
        // Observing the transcript must never cause the client to replay POST.
        let finalPOSTCount = try await acceptedRunPOSTCount()
        XCTAssertEqual(finalPOSTCount, 1,
                       "Streaming gestures must not submit another chat request")
    }

}
