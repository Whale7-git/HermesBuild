import Foundation

// This suite exercises controller state, not UIKit sharing or file lease cleanup.
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
struct SharedTemporaryFile: Identifiable {
    let id = UUID()
    let url: URL
}

@main struct ExportRecoveryTests {
    @MainActor static func main() async {
        let controller = ChatExportController()
        controller.markFailure("offline fixture failure", fullHistory: true)
        precondition(controller.failure != nil && controller.failedFullHistory && !controller.isBusy)
        let retryScope = controller.failedFullHistory
        controller.dismissFailure()
        precondition(controller.failure == nil && controller.failedFullHistory == retryScope,
                     "dismiss before retry must preserve failed export range")
        controller.markFailure("loaded export failed", fullHistory: false)
        precondition(!controller.failedFullHistory,
                     "loaded-only failure must not offer misleading full-history fallback")
        let previousTicket = controller.ticket
        controller.progress = .init()
        controller.readyFile = SharedTemporaryFile(url: URL(fileURLWithPath: "/offline-fixture/no-file.md"))
        controller.cancel()
        precondition(controller.ticket != previousTicket && !controller.isBusy
                     && controller.readyFile == nil && controller.failure == nil && controller.task == nil,
                     "cancel invalidates task ticket and clears pending recovery UI state")
        controller.readyFile = SharedTemporaryFile(url: URL(fileURLWithPath: "/offline-fixture/no-file.md"))
        let expectedID = controller.readyFile!.id
        controller.shareReadyFile()
        precondition(controller.sharingFile?.id == expectedID && !controller.hasReadyFile,
                     "sharing transfers the ready state once")
        print("EXPORT_RECOVERY_PASS failure visibility, retry range, loaded fallback flag, cancellation ticket and ready/share state; headless controller only")
    }
}
