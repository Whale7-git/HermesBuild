import Foundation

@main struct TextualPrimitiveTests {
  @MainActor static var checks = 0
  @MainActor static func expect(_ value: @autoclosure () -> Bool, _ description: String) {
    checks += 1
    precondition(value(), description)
  }

  @MainActor static func main() async throws {
    testMeasurementReuse()
    try await testPublication()
    try await testActorEntryAndTiming()
    print("TEXTUAL_PRIMITIVES_PASS \(checks) assertions (actual cache/token work; native Layout/selection untested)")
  }

  @MainActor static func testMeasurementReuse() {
    struct Context: Equatable { var font = 1; var style = 1; var locale = "zh" }
    var cache = TextualBlockMeasurementCache<Context, CGSize>()
    var calls = 0
    var context = Context()
    var source = (0..<200).map { CGSize(width: 300, height: 20 + $0) }
    func measure(_ index: Int) -> CGSize { calls += 1; return source[index] }
    let sizing = cache.sizes(width: 320, count: 200, context: context, measure: measure)
    let placement = cache.sizes(width: 320, count: 200, context: context, measure: measure)
    expect(sizing == source && placement == source && calls == 200, "size/place share exactly the real measurements")
    let originalHeight = source.reduce(CGFloat.zero) { $0 + $1.height }
    expect(placement.reduce(CGFloat.zero) { $0 + $1.height } == originalHeight, "reuse leaves natural block heights unchanged")
    _ = cache.sizes(width: 321, count: 200, context: context, measure: measure)
    expect(calls == 400, "different exact width cannot reuse the previous dimensions")
    _ = cache.sizes(width: nil, count: 200, context: context, measure: measure)
    _ = cache.sizes(width: .infinity, count: 200, context: context, measure: measure)
    expect(calls == 800, "unspecified and infinite width are independent proposals")
    _ = cache.sizes(width: nil, count: 200, context: context, measure: measure)
    expect(calls == 800, "unspecified-width sizing can be reused for its matching placement")
    source[0].height = 999
    cache.invalidate() // The actual Layout.updateCache always calls this.
    let replacement = cache.sizes(width: 320, count: 200, context: context, measure: measure)
    expect(replacement[0].height == 999 && calls == 1000, "same-count replacement cannot reuse an index from an old subtree")
    for change in 0..<3 {
      if change == 0 { context.font += 1 }
      if change == 1 { context.style += 1 }
      if change == 2 { context.locale = "en" }
      _ = cache.sizes(width: 320, count: 200, context: context, measure: measure)
    }
    expect(calls == 1600, "font, style and locale changes invalidate a same-width measurement")
    _ = cache.sizes(width: 320, count: 2, context: context, measure: measure)
    _ = cache.sizes(width: 320, count: 3, context: context, measure: measure)
    _ = cache.sizes(width: 320, count: 2, context: context, measure: measure)
    expect(calls == 1607, "count changes discard older child arrays instead of reviving their indices")
    _ = cache.sizes(width: .nan, count: 2, context: context, measure: measure)
    _ = cache.sizes(width: .nan, count: 2, context: context, measure: measure)
    expect(calls == 1611, "NaN proposals are never cached")
    expect(cache.sizes(width: 100, count: 0, context: context, measure: measure).isEmpty, "empty layout safely measures no children")
    cache.invalidate()
    let before = calls
    for width in [1.0, 2, 3, 1, 4, 3, 2] { _ = cache.sizes(width: width, count: 1, context: context, measure: measure) }
    expect(calls - before == 5, "proposal LRU is bounded and retains recently reused widths")
  }

  struct Input: Equatable { let source: String; let language: String? }

  @MainActor static func eventually(_ predicate: @Sendable () async -> Bool) async throws {
    for _ in 0..<2000 {
      if await predicate() { return }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    preconditionFailure("controlled tokenizer did not enter")
  }

  @MainActor static func testPublication() async throws {
    let suspended = SuspendedTokenizer()
    let work = TextualTokenizationWork<Input, String>()
    var shown: [[String]] = []
    for scenario in 0..<3 {
      shown = []
      let first = Input(source: "old source", language: "swift")
      let second = scenario == 0 ? Input(source: "new source", language: "swift")
        : scenario == 1 ? Input(source: "old source", language: "python") : first
      let firstKey = "old-\(scenario)"
      let secondKey = "new-\(scenario)"
      let old = Task { @MainActor in
        await work.run(input: first, plain: ["old plain"], operation: { await suspended.wait(firstKey) }) { shown.append($0) }
      }
      try await eventually { await suspended.contains(firstKey) }
      let new = Task { @MainActor in
        await work.run(input: second, plain: ["new plain"], operation: { await suspended.wait(secondKey) }) { shown.append($0) }
      }
      try await eventually { await suspended.contains(secondKey) }
      await suspended.finish(secondKey, tokens: ["new tokens"])
      await new.value
      await suspended.finish(firstKey, tokens: ["stale tokens"])
      await old.value
      expect(shown == [["old plain"], ["new plain"], ["new tokens"]], "source/language/same-input-generation rejects late old results: \(scenario)")
    }
    shown = []
    let cancelled = Task { @MainActor in
      await work.run(input: .init(source: "cancelled", language: "swift"), plain: ["plain"], operation: { await suspended.wait("cancelled") }) { shown.append($0) }
    }
    try await eventually { await suspended.contains("cancelled") }
    cancelled.cancel()
    await suspended.finish("cancelled", tokens: ["must not publish"])
    await cancelled.value
    expect(shown == [["plain"]], "cooperative task cancellation blocks a late uncancellable result")
    shown = []
    let disappeared = Task { @MainActor in
      await work.run(input: .init(source: "same", language: "swift"), plain: ["plain"], operation: { await suspended.wait("disappear") }) { shown.append($0) }
    }
    try await eventually { await suspended.contains("disappear") }
    work.cancel()
    await suspended.finish("disappear", tokens: ["hidden"])
    await disappeared.value
    expect(shown == [["plain"]], "explicit disappearance invalidates work even without Task cancellation")
    shown = []
    let alreadyCancelled = Task { @MainActor in
      await Task.yield()
      await work.run(input: .init(source: "cancel before entry", language: nil), plain: ["hidden"], operation: nil) { shown.append($0) }
    }
    alreadyCancelled.cancel()
    await alreadyCancelled.value
    expect(shown.isEmpty, "a task cancelled before entry never publishes even its plain fallback")
    await work.run(input: .init(source: "plain", language: nil), plain: ["plain"], operation: nil) { shown.append($0) }
    expect(shown == [["plain"]], "no tokenizer/language preserves original plain content")

    let reuse = TextualTokenizationWork<Input, String>()
    let invocations = NumericWitness()
    let sameInput = Input(source: "completed source", language: "swift")
    var completed: [[String]] = []
    for _ in 0..<3 {
      await reuse.run(input: sameInput, plain: ["plain"], operation: {
        invocations.record(1)
        return ["highlighted"]
      }) { completed.append($0) }
      reuse.cancel() // Mirrors host disappearance between reattachments.
    }
    expect(invocations.values.count == 1, "a fully completed input executes the tokenizer only once across reattachments")
    expect(completed == [["plain"], ["highlighted"], ["highlighted"], ["highlighted"]], "reattachment reuses completed tokens without publishing plain again")
    await reuse.run(input: .init(source: sameInput.source, language: "python"), plain: ["plain"], operation: {
      invocations.record(1)
      return ["python"]
    }) { completed.append($0) }
    expect(invocations.values.count == 2 && completed.last == ["python"], "completed reuse never crosses a language change")

    let retry = TextualTokenizationWork<Input, String>()
    var retried: [[String]] = []
    let firstTry = Task { @MainActor in
      await retry.run(input: sameInput, plain: ["plain"], operation: { await suspended.wait("incomplete") }) { retried.append($0) }
    }
    try await eventually { await suspended.contains("incomplete") }
    firstTry.cancel()
    retry.cancel()
    await suspended.finish("incomplete", tokens: ["cancelled result"])
    await firstTry.value
    let retryCount = NumericWitness()
    await retry.run(input: sameInput, plain: ["plain"], operation: {
      retryCount.record(1)
      return ["retried tokens"]
    }) { retried.append($0) }
    expect(retryCount.values.count == 1 && retried == [["plain"], ["plain"], ["retried tokens"]], "cancelled plain stage is not cached as complete and reentry retries tokenization")
  }

  @MainActor static func testActorEntryAndTiming() async throws {
    let measured = NumericWitness()
    var clocks = 0
    let disabled = textualTokenizeIfActive(plain: ["plain"], duration: nil, clock: { clocks += 1; return 1 }) { ["tokens"] }
    expect(disabled == ["tokens"] && clocks == 0, "disabled diagnostics never read the clock")
    let active = textualTokenizeIfActive(plain: ["plain"], duration: { measured.record($0) }, clock: { clocks += 1; return Double(clocks) }) { ["tokens"] }
    expect(active == ["tokens"] && measured.values == [1] && clocks == 2, "only synchronous tokenizer work is measured")
    let actor = BlockingTokenizer()
    let ready = NumericWitness()
    let blocker = Task.detached { await actor.block(ready: ready) }
    try await eventually { !ready.values.isEmpty }
    let queued = Task { await actor.run(duration: { measured.record($0) }) }
    queued.cancel()
    actor.release.signal()
    await blocker.value
    let result = await queued.value
    expect(result == ["plain"], "actor-entry guard returns original text for a queued cancelled job")
    let actualCalls = await actor.calls
    expect(actualCalls == 0 && measured.values == [1], "cancelled queued actor work never starts Prism or records a fake sample")
  }
}

private actor SuspendedTokenizer {
  private var pending: [String: CheckedContinuation<[String], Never>] = [:]
  func wait(_ key: String) async -> [String] { await withCheckedContinuation { pending[key] = $0 } }
  func contains(_ key: String) -> Bool { pending[key] != nil }
  func finish(_ key: String, tokens: [String]) { pending.removeValue(forKey: key)!.resume(returning: tokens) }
}

private actor BlockingTokenizer {
  nonisolated let release = DispatchSemaphore(value: 0)
  var calls = 0
  func block(ready: NumericWitness) {
    ready.record(1)
    precondition(release.wait(timeout: .now() + 5) == .success)
  }
  func run(duration: (@Sendable (Double) -> Void)?) -> [String] {
    textualTokenizeIfActive(plain: ["plain"], duration: duration) {
      calls += 1
      return ["tokens"]
    }
  }
}

private final class NumericWitness: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [Double] = []
  func record(_ value: Double) { lock.withLock { stored.append(value) } }
  var values: [Double] { lock.withLock { stored } }
}
