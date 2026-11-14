import Foundation

/// One visible operation/presentation per message's attachment strip. Tickets
/// survive asynchronous callbacks; a cancelled/retired ticket can never present.
struct AttachmentInteractionState {
    enum Intent: Equatable, Sendable { case preview, share, image }
    struct Ticket: Equatable, Sendable {
        let id: UUID
        let itemID: String
        let intent: Intent
    }
    struct Failure: Equatable {
        let ticket: Ticket
        let message: String
    }

    private(set) var scope = ""
    private(set) var isActive = false
    private(set) var pending: Ticket?
    private(set) var presentationID: UUID?
    private(set) var receivedBytes = 0
    private(set) var expectedBytes: Int?
    private(set) var failure: Failure?
    var isBusy: Bool { pending != nil || presentationID != nil }

    mutating func activate(scope: String) {
        if self.scope != scope {
            deactivate()
            self.scope = scope
        }
        isActive = true
    }

    mutating func begin(itemID: String, intent: Intent) -> Ticket? {
        guard isActive, !isBusy else { return nil }
        let ticket = Ticket(id: UUID(), itemID: itemID, intent: intent)
        pending = ticket
        failure = nil
        receivedBytes = 0
        expectedBytes = nil
        return ticket
    }

    @discardableResult
    mutating func progress(_ ticket: Ticket, received: Int, expected: Int?) -> Bool {
        guard isActive, pending == ticket else { return false }
        receivedBytes = max(receivedBytes, max(0, received))
        expectedBytes = expected.flatMap { $0 > 0 ? $0 : nil }
        return true
    }

    @discardableResult
    mutating func present(_ ticket: Ticket) -> Bool {
        guard isActive, pending == ticket, presentationID == nil else { return false }
        pending = nil
        presentationID = ticket.id
        return true
    }

    @discardableResult
    mutating func fail(_ ticket: Ticket, message: String) -> Bool {
        guard isActive, pending == ticket else { return false }
        pending = nil
        failure = Failure(ticket: ticket, message: message)
        return true
    }

    mutating func cancel() {
        pending = nil
        failure = nil
        receivedBytes = 0
        expectedBytes = nil
    }

    mutating func deactivate() {
        isActive = false
        cancel()
        presentationID = nil
        // This only retires local UI state. An actual system surface retains its
        // independent lifetime/URL until that surface has really ended.
    }

    @discardableResult
    mutating func dismissed(_ id: UUID) -> Bool {
        guard presentationID == id else { return false }
        presentationID = nil
        return true
    }
}

/// Sibling message rows can own separate controllers. Their attachment panels
/// still share one reservation, released only after actual dismissal/cancel.
@MainActor
final class AttachmentPresentationGate {
    static let shared = AttachmentPresentationGate()
    private(set) var owner: UUID?
    func reserve(_ id: UUID) -> Bool {
        guard owner == nil || owner == id else { return false }
        owner = id
        return true
    }
    func release(_ id: UUID) {
        if owner == id { owner = nil }
    }
}

/// Both the presenting model and the actual system controller retain this
/// lease. Losing either owner alone cannot remove a file the other still uses.
/// A thread-safe cleanup closure runs exactly once after the final owner exits.
final class AttachmentPresentationLifetime: @unchecked Sendable {
    private let cleanup: @Sendable () -> Void
    init(cleanup: @escaping @Sendable () -> Void) { self.cleanup = cleanup }
    deinit { cleanup() }
}
