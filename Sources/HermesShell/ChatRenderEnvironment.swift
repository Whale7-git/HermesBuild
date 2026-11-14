import SwiftUI

@MainActor
final class ChatRenderReadiness {
    var isPending = true { didSet { if oldValue != isPending { changed?() } } }
    /// A valid displayed streaming prefix is measurable even when a newer
    /// append is queued. Replacements must first publish their own document.
    var hasContent = false { didSet { if oldValue != hasContent { changed?() } } }
    fileprivate var changed: (() -> Void)?
}

/// Each host keeps its own reference across rootView updates. Documents observe
/// it directly, so removing a UIKit view also cancels its queued work without
/// relying on the timing of SwiftUI's onDisappear.
@MainActor
final class ChatRowRenderState: ObservableObject {
    private struct WeakReadiness { weak var value: ChatRenderReadiness? }
    private var documents: [ObjectIdentifier: WeakReadiness] = [:]
    private var mountingGeneration: UInt64 = 0
    private var mountedGeneration: UInt64?
    var onReadinessChange: (() -> Void)?
    @Published private(set) var context = ChatRenderContext(priority: .prefetch)
    func track(_ document: ChatRenderReadiness) {
        documents[ObjectIdentifier(document)] = WeakReadiness(value: document)
        document.changed = { [weak self] in self?.onReadinessChange?() }
        onReadinessChange?()
    }
    func untrack(_ document: ChatRenderReadiness) {
        documents.removeValue(forKey: ObjectIdentifier(document))
        document.changed = nil
        onReadinessChange?()
    }
    func beginMount(_ generation: UInt64) {
        mountingGeneration = generation
        mountedGeneration = nil
    }
    func didMount(_ generation: UInt64) {
        guard mountingGeneration == generation else { return }
        mountedGeneration = generation
        onReadinessChange?()
    }
    var isReadyForMeasurement: Bool {
        documents = documents.filter { $0.value.value != nil }
        return (mountedGeneration == mountingGeneration || mountingGeneration == 0)
            && !documents.values.contains { $0.value.map { $0.isPending && !$0.hasContent } == true }
    }
    func update(_ value: ChatRenderContext) {
        if context != value { context = value }
    }
}

private struct ChatRenderStateKey: EnvironmentKey {
    static let defaultValue: ChatRowRenderState? = nil
}

extension EnvironmentValues {
    var chatRenderState: ChatRowRenderState? {
        get { self[ChatRenderStateKey.self] }
        set { self[ChatRenderStateKey.self] = newValue }
    }
}
