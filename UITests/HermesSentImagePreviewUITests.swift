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
        for _ in 0..<24 {
            if tile.exists && tile.isHittable { break }
            if transcript.exists && transcript.isHittable { transcript.swipeUp() }
        }
        guard tile.waitForExistence(timeout: 12), tile.isHittable else {
            XCTFail("Authenticated history image tile not reachable; native chat fixture or accessibility lookup failed")
            return
        }
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "已加载"), object: tile)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 20), .completed,
                       "Image never decoded; tile state: \(String(describing: tile.value))")
        guard tile.value as? String == "已加载" else { return }
        tile.tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 10),
                      "A loaded sent image must open its preview gallery")
    }
}
