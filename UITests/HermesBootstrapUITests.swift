import XCTest

/// First-launch configuration is a prerequisite, not four product Gold cases.
/// It exercises the shipping Settings/AddInstance views and a real Keychain
/// write followed by cold relaunch against the loopback Gateway fixture.
final class HermesBootstrapUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor func testGatewaySetupPersistsAcrossRelaunch() async throws {
        let app = HermesUITestHarness.launchAndConnect(verifySettingsDismissal: true)
        // A failed common setup records a single authoritative assertion.
        // Do not keep issuing a mock GET or print BOOTSTRAP_PASS after it.
        guard HermesUITestHarness.setupSucceeded else { return }
        let drawer = app.buttons["打开会话侧栏"]
        XCTAssertTrue(drawer.exists && drawer.isHittable,
                      "SETUP_BLOCKED stage=bootstrap.home; cannot interact after cold launch")

        // Verify that the persisted credential actually reaches the isolated
        // Gateway API. A visible home alone cannot prove session connectivity.
        let url = try XCTUnwrap(URL(string:
            "http://127.0.0.1:8765/__control/log"))
        var connected = false
        for _ in 0..<30 {
            let (data, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                           "SETUP_BLOCKED stage=bootstrap.ledger; fixture unavailable")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            let requests = try XCTUnwrap(body["requests"] as? [[String: Any]])
            connected = requests.contains { item in
                item["method"] as? String == "GET"
                && item["path"] as? String == "/api/sessions"
                && item["authorization_present"] as? Bool == true
                && item["authorization_scheme"] as? String == "Bearer"
            }
            if connected { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(connected,
                      "SETUP_BLOCKED stage=bootstrap.session_get; no authenticated "
                      + "GET /api/sessions observed after setup and cold relaunch")
        print("HERMES_BOOTSTRAP stage=bootstrap.authenticated_session_get")
        print("HERMES_BOOTSTRAP_PASS")
    }
}
