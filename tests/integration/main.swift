import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Optional READ-ONLY live test against an existing synthetic conversation.
/// The cookie is read from stdin, never logged or saved. No POST/stop is issued.
@main struct LiveHistoryProbe {
    static func main() async throws {
        guard (3...4).contains(CommandLine.arguments.count),
              let base = URL(string:CommandLine.arguments[1]), base.scheme == "https",
              let cookie = readLine(), !cookie.isEmpty else {
            throw NSError(domain:"probe",code:1,userInfo:[NSLocalizedDescriptionKey:"expected HTTPS base, synthetic session ID, and cookie on stdin"])
        }
        let sid = CommandLine.arguments[2]
        var request = ChatRequests(baseURL:base).history(sessionID:sid)
        request.setValue(cookie,forHTTPHeaderField:"Cookie")
        request.timeoutInterval = 35
        let (data,response) = try await URLSession.shared.data(for:request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain:"probe",code:2,userInfo:[NSLocalizedDescriptionKey:"history request was not HTTP 200"])
        }
        let snapshot = try ChatSnapshot(data:data)
        guard snapshot.sessionID == sid,
              snapshot.messages.contains(where: { $0.role == "assistant" && $0.content.contains("IOS_NATIVE_OK") }) else {
            throw NSError(domain:"probe",code:3,userInfo:[NSLocalizedDescriptionKey:"synthetic conversation marker absent"])
        }
        print("LIVE_SWIFT_HTTPS_HISTORY_PASS status=200 messages=\(snapshot.messages.count) authenticated=true mode=GET-only")
        if CommandLine.arguments.count == 4 {
            var replay = ChatRequests(baseURL:base).stream(streamID:CommandLine.arguments[3],lastEventID:nil)
            replay.setValue(cookie,forHTTPHeaderField:"Cookie")
            replay.timeoutInterval = 35
            let (wire,response) = try await URLSession.shared.data(for:replay)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.value(forHTTPHeaderField:"Content-Type")?.contains("text/event-stream") == true else {
                throw NSError(domain:"probe",code:4,userInfo:[NSLocalizedDescriptionKey:"archived SSE GET was not HTTP 200 text/event-stream"])
            }
            var parser = SSEParser()
            var transcript = ChatTranscript()
            var frames = 0
            for line in String(decoding:wire,as:UTF8.self).components(separatedBy:"\n") {
                if let frame = parser.feed(line:line) {
                    try transcript.apply(frame)
                    frames += 1
                }
            }
            guard transcript.terminal,
                  transcript.messages.contains(where:{ $0.role == "assistant" && $0.content.contains("IOS_NATIVE_OK") }) else {
                throw NSError(domain:"probe",code:5,userInfo:[NSLocalizedDescriptionKey:"archived SSE lacked terminal marker and expected assistant output"])
            }
            print("LIVE_SWIFT_HTTPS_SSE_REPLAY_PASS status=200 frames=\(frames) terminal=true mode=GET-only")
        }
    }
}
