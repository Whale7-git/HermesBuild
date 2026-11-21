import XCTest

/// A real chat attachment must load through the authenticated gateway and
/// open a gallery, rather than silently remaining a grey placeholder.
final class HermesSentImagePreviewUITests: XCTestCase {
    @MainActor func testUploadedHistoryImageLoadsAndOpens() async throws {
        // Prepare before launching the app: launching may prefetch chat history.
        var request = URLRequest(url: URL(string:
            "http://127.0.0.1:8765/__control/add-image")!)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "Could not prepare the isolated uploaded-image fixture")

        let app = HermesUITestHarness.launchAndConnect()
        HermesUITestHarness.openSession(app)
        let tile = app.descendants(matching: .any)
            .matching(identifier: "hermes-chat-image").firstMatch
        let transcript = app.scrollViews.firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        // Virtualized rows can expose an accessibility placeholder at an
        // infinite coordinate while offscreen. Never call isHittable on one.
        func isVisible(_ element: XCUIElement) -> Bool {
            guard element.exists else { return false }
            let frame = element.frame
            return frame.origin.x.isFinite && frame.origin.y.isFinite
                && frame.width.isFinite && frame.height.isFinite
                && frame.width > 4 && frame.height > 4
                && frame.intersects(transcript.frame)
        }
        for _ in 0..<30 {
            if isVisible(tile) { break }
            transcript.swipeUp()
        }
        guard tile.waitForExistence(timeout: 12), isVisible(tile) else {
            XCTFail("Authenticated image row was not made visible in the chat viewport")
            return
        }
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "已加载"), object: tile)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 20), .completed,
                       "Image never decoded; status=\(String(describing: tile.value))"
                       + "; safe reason=\(tile.label)")
        guard tile.value as? String == "已加载" else { return }

        // Confirm the real UI fetched through Gateway Files API with Bearer,
        // without ever logging a token or the opaque private file path.
        let (logData, _) = try await URLSession.shared.data(from: URL(string:
            "http://127.0.0.1:8765/__control/log")!)
        let body = try JSONSerialization.jsonObject(with: logData) as? [String: Any]
        let requests = body?["requests"] as? [[String: Any]] ?? []
        XCTAssertTrue(requests.contains { item in
            item["method"] as? String == "GET"
                && item["path"] as? String == "/v1/files/by-path"
                && item["authorization_scheme"] as? String == "Bearer"
        }, "Authenticated chat thumbnail must request the Gateway file endpoint")
        tile.tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 10),
                      "A loaded sent image must open its preview gallery")
    }
}
