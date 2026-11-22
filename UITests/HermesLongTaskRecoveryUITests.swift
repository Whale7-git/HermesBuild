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

        // An empty draft intentionally disables Send. Instead require a
        // second canonical GET without tapping a recovery button, then type a
        // real draft and prove the composer becomes usable again.
        let logURL = URL(string: "http://127.0.0.1:8765/__control/log")!
        var historyGets = 0
        var submittedRuns = 0
        for _ in 0..<70 {
            let (data, response) = try await URLSession.shared.data(from: logURL)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let requests = try XCTUnwrap(root["requests"] as? [[String: Any]])
            historyGets = requests.filter {
                ($0["method"] as? String) == "GET" &&
                ($0["path"] as? String) == "/api/sessions/ui-session-1/messages"
            }.count
            submittedRuns = requests.filter {
                ($0["method"] as? String) == "POST" &&
                ($0["path"] as? String) == "/v1/runs"
            }.count
            if historyGets >= 2 { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertGreaterThanOrEqual(historyGets, 2,
                                    "Client must automatically retry canonical history GET")
        XCTAssertEqual(submittedRuns, 0, "Recovery must never submit a chat POST")
        let editor = app.textViews.matching(
            NSPredicate(format: "label CONTAINS[cd] %@", "消息输入框")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10) && editor.isHittable,
                      "Recovered chat must expose a usable text editor")
        editor.tap()
        editor.typeText("UI recovery verified draft")
        let send = app.buttons["发送消息"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10) && send.isEnabled,
                      "Send must become available after typing a draft into a recovered chat")
        let (finalData, _) = try await URLSession.shared.data(from: logURL)
        let finalRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: finalData) as? [String: Any])
        let finalRequests = try XCTUnwrap(finalRoot["requests"] as? [[String: Any]])
        XCTAssertEqual(finalRequests.filter {
            ($0["method"] as? String) == "POST" &&
            ($0["path"] as? String) == "/v1/runs"
        }.count, 0, "Typing after recovery must not replay the original POST")
    }
}
