import XCTest

/// A real chat attachment must not become a permanent grey placeholder after
/// an authenticated upload reference is returned by the gateway.
final class HermesSentImagePreviewUITests: XCTestCase {
    @MainActor func testUploadedHistoryImageLoadsAndOpens() async throws {
        let app = HermesUITestHarness.launchAndConnect()

        var request = URLRequest(url: URL(string:
            "http://127.0.0.1:8765/__control/add-image")!)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "Could not prepare the isolated uploaded-image fixture")
        HermesUITestHarness.openSession(app)

        let tile = app.buttons.matching(
            NSPredicate(format: "label == %@", "图片")
        ).firstMatch
        let transcript = app.scrollViews.firstMatch
        for _ in 0..<30 {
            if tile.exists && tile.isHittable { break }
            if transcript.exists { transcript.swipeUp() }
        }
        XCTAssertTrue(tile.waitForExistence(timeout: 12) && tile.isHittable,
                      "The sent-image row did not render a selectable tile")

        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "已加载"), object: tile)
        let result = XCTWaiter.wait(for: [loaded], timeout: 15)
        XCTAssertEqual(result, .completed,
                       "Sent image never decoded; tile value=\(String(describing: tile.value))")

        tile.tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 10),
                      "A loaded sent image must open its preview gallery")
    }
}
