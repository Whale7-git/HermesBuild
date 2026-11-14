import SwiftUI
import UIKit
import Combine

/// Coalesces append bursts without debounce starvation. Foundation work belongs
/// to the worker actor; only ready immutable documents are published to SwiftUI.
@MainActor
final class ChatMarkdownDocument: ObservableObject {
    typealias Request = MarkdownRenderRequest
    @Published private(set) var content: AttributedString
    @Published private(set) var highlightAfter: Int?
    private let worker = ChatMarkdownWorker()
    private let cacheGeneration: UInt64
    private var pending: Request?
    private var latest: Request?
    private var displayed: Request?
    private var job: Task<Void, Never>?
    private var pacingSleep: Task<Void, Error>?
    private var renderingSubscription: AnyCancellable?
    private let readiness = ChatRenderReadiness()
    private weak var renderingOwner: ChatRowRenderState?
    private var context = ChatRenderContext()
    private var isPresented = false
    private var currentTicket: UUID?
    private var epoch: UInt64 = 0
    private var pacing = ChatStreamPacing()
    private var lastParseDuration = 0.0

    init(source: String, finished: Bool) {
        cacheGeneration = ChatMarkdownParser.cacheGeneration
        let cached = finished ? ChatMarkdownParser.cachedDocument(source) : nil
        content = cached ?? AttributedString()
        highlightAfter = finished ? nil : 0
        if cached != nil { displayed = Request(source: source, finished: finished) }
        readiness.isPending = cached == nil
        readiness.hasContent = cached != nil
    }

    func appear(rendering: ChatRowRenderState?) {
        isPresented = true
        renderingSubscription = nil
        if let rendering {
            renderingOwner?.untrack(readiness)
            renderingOwner = rendering
            rendering.track(readiness)
            renderingSubscription = rendering.$context.sink { [weak self] in self?.setContext($0) }
        } else {
            renderingOwner?.untrack(readiness)
            renderingOwner = nil
            setContext(ChatRenderContext())
        }
        startIfNeeded()
    }

    func disappear() {
        isPresented = false
        renderingSubscription = nil
        renderingOwner?.untrack(readiness)
        renderingOwner = nil
        stopCurrentJob()
    }

    func update(source: String, finished: Bool) {
        let request = Request(source: source, finished: finished)
        guard request != latest else { startIfNeeded(); return }
        latest = request
        readiness.hasContent = displayed.map { MarkdownRenderGate.allows($0, latest: request) } ?? false
        readiness.isPending = request != displayed
        guard request != displayed else { stopCurrentJob(); pending = nil; return }
        if finished, let cached = ChatMarkdownParser.cachedDocument(source) {
            stopCurrentJob()
            pending = nil
            content = cached; highlightAfter = nil
            displayed = request
            readiness.isPending = false
            readiness.hasContent = true
            return
        }
        pending = request
        // Wake a pacing wait on finalization; continuous live input does not
        // reset the deadline. A running Foundation parse still owns its slot.
        if finished { pacingSleep?.cancel() }
        startIfNeeded()
    }

    private func setContext(_ value: ChatRenderContext) {
        context = value
        if let currentTicket { ChatRenderScheduler.shared.setPriority(value.priority, for: currentTicket) }
        if !value.isActive { stopCurrentJob() }
        else { startIfNeeded() }
    }

    private func stopCurrentJob() {
        epoch &+= 1
        job?.cancel(); job = nil
        pacingSleep?.cancel(); pacingSleep = nil
        currentTicket = nil
        pending = latest == displayed ? nil : latest
    }

    private func startIfNeeded() {
        guard isPresented, context.isActive, pending != nil, job == nil else { return }
        epoch &+= 1
        let token = epoch
        job = Task { [weak self] in
            while let self, self.epoch == token, !Task.isCancelled, self.pending != nil {
                if let pending = self.pending, !pending.finished, self.displayed != nil {
                    let delay = self.pacing.delay(now: CACurrentMediaTime(), finished: pending.finished,
                        context: self.context)
                    if delay > 0 {
                        let sleep = Task { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                        self.pacingSleep = sleep
                        _ = try? await sleep.value
                        guard self.epoch == token, !Task.isCancelled else { break }
                        self.pacingSleep = nil
                    }
                }
                guard self.epoch == token, var request = self.pending else { break }
                self.pending = nil
                let result: MarkdownRenderSnapshot?
                do {
                    let rendered = try await self.render(request, epoch: token)
                    request = rendered.request
                    result = rendered.snapshot
                }
                catch is CancellationError { break }
                catch { result = nil }
                guard !Task.isCancelled, self.epoch == token else { break }
                // A valid older append may be displayed while a newer append
                // waits. A replacement/collapse/final cache must reject it.
                let valid = MarkdownRenderGate.allows(request, latest: self.latest)
                let publicationSample = ChatPerformanceRecorder.shared.begin()
                if valid, let result {
                    self.content = result.content
                    self.highlightAfter = result.highlightAfter
                    if request.finished, self.cacheGeneration == ChatMarkdownParser.cacheGeneration {
                        ChatMarkdownParser.remember(result.content, source: request.source)
                    }
                } else if valid {
                    // Even a parser failure must leave the actual message
                    // readable. Never replace new content with a stale prefix.
                    self.content = AttributedString(request.source)
                    self.highlightAfter = nil
                }
                if valid {
                    self.displayed = request
                    self.readiness.hasContent = true
                    self.readiness.isPending = self.latest != request
                    self.pacing.published(at: CACurrentMediaTime(), activeBytes: result?.metrics.activeBytes ?? 0,
                        parseSeconds: self.lastParseDuration)
                    ChatPerformanceRecorder.shared.finish(.publish, publicationSample)
                }
            }
            if let self, self.epoch == token { self.job = nil }
        }
    }

    private func render(_ request: Request, epoch token: UInt64) async throws
        -> (request: Request, snapshot: MarkdownRenderSnapshot?) {
        let ticket = UUID()
        currentTicket = ticket
        defer { if currentTicket == ticket { currentTicket = nil } }
        let queueSample = ChatPerformanceRecorder.shared.begin()
        try await ChatRenderScheduler.shared.acquire(ticket, priority: context.priority)
        defer { ChatRenderScheduler.shared.release(ticket) }
        try Task.checkCancellation()
        guard epoch == token, context.isActive, isPresented else { throw CancellationError() }
        ChatPerformanceRecorder.shared.finish(.queue, queueSample)
        // Re-read after queueing. A slow history parse must not force every
        // superseded streaming prefix through the worker before the latest one.
        let actual = pending ?? request
        pending = nil
        let start = CACurrentMediaTime()
        let parseSample = ChatPerformanceRecorder.shared.begin()
        defer {
            let duration = CACurrentMediaTime() - start
            if epoch == token { lastParseDuration = duration }
            ChatPerformanceRecorder.shared.finish(.parse, parseSample)
        }
        do {
            let result = try await worker.render(actual.source, finished: actual.finished)
            try Task.checkCancellation()
            return (actual, result)
        } catch is CancellationError { throw CancellationError() }
        catch { return (actual, nil) } // Fall back using the actual, newest request.
    }

    deinit {
        job?.cancel(); pacingSleep?.cancel()
        let owner = renderingOwner, readiness = readiness
        Task { @MainActor in owner?.untrack(readiness) }
    }
}
