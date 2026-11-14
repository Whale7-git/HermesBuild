// Compile-only dependencies. This checks actual discovery views against the iOS SDK;
// it does not claim to exercise AppState, authentication or an on-device UI.
import Foundation
import SwiftUI
import UIKit

@MainActor final class HermesAPI {
    var chatRequests: ChatRequests { ChatRequests(baseURL: URL(string: "https://example.test")!) }
    func performNative(_ request: URLRequest) async throws -> Data { Data() }
    func syncCookiesFromWebKit() async {}
}
enum APIError: Error { case http(Int, String) }
enum ChatPresentation { static func shortAge(_ date: Date) -> String { "" } }
@MainActor final class AppState: ObservableObject {
    @Published var sessions: [SessionSummary] = []
    @Published var sessionActionError: String?
    @Published var instances: [HermesInstance] = []
    @Published var activeIndex = 0
    @Published var activeChangeToken = 0
    @Published var creating = false
    @Published var loadingSessions = false
    @Published var errorText: String?
    @Published var needsLogin = false
    let api = HermesAPI()
    var active: HermesInstance { HermesInstance(name: "test", baseURL: "https://example.test") }
    func switchTo(_ index: Int) {}
    func refresh() async {}
    func rename(sessionID: String, title: String) async {}
    func delete(sessionID: String) async {}
    func togglePin(sessionID: String) async {}
    func branch(sessionID: String, keepCount: Int?) async {}
    func archive(sessionID: String) async {}
}
