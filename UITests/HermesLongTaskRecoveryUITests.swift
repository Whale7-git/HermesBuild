import XCTest

/// The user's chat must recover from a transient authoritative-history failure
/// without opening the technical status-verification panel or replaying POST.
final class HermesLongTaskRecoveryUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor func testFailedHistoryAutomaticallyRecoversWithoutManualCheck() async throws {
        func control(_ path: String, _ payload: String = "{}") async throws {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:8765" + path)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(payload.utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                           "Mock control did not accept \(path)")
        }
        try await control("/__control/reset")
        let app = HermesUITestHarness.launchAndConnect()
        try await control("/__control/stub",
                          #"{"method":"GET","path":"/api/sessions/ui-session-1/messages","status":503}"#)
        HermesUITestHarness.openSession(app)

        // The first GET fails. The app must schedule an automatic read-only
        // retry, and the user's send control must recover with no button tap.
        let send = app.buttons["发送消息"].firstMatch
        let enabled = NSPredicate(format: "exists == true AND enabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: enabled, object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 35), .completed,
                       "Chat did not automatically recover from transient history failure")

        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:8765/__control/log")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let requests = try XCTUnwrap(root["requests"] as? [[String: Any]])
        let historyGets = requests.filter {
            ($0["method"] as? String) == "GET" &&
            ($0["path"] as? String) == "/api/sessions/ui-session-1/messages"
        }
        XCTAssertGreaterThanOrEqual(historyGets.count, 2,
                                    "Client must re-fetch canonical history automatically")
        XCTAssertEqual(requests.filter {
            ($0["method"] as? String) == "POST" &&
            ($0["path"] as? String) == "/v1/runs"
        }.count, 0, "Status recovery must not submit any chat POST")
    }
}
