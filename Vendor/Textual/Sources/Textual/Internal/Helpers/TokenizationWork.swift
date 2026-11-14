import Foundation

/// Called inside the tokenizer actor, after queueing. The measured interval is
/// synchronous work only; a disabled hook does not even read the clock.
func textualTokenizeIfActive<Token>(
  plain: [Token], duration: (@Sendable (Double) -> Void)?,
  clock: () -> Double = { ProcessInfo.processInfo.systemUptime },
  operation: () -> [Token]
) -> [Token] {
  guard !Task.isCancelled else { return plain }
  let started = duration.map { _ in clock() }
  defer { if let started { duration?(max(0, clock() - started)) } }
  return operation()
}

/// A bounded, main-actor-isolated cache of completed tokenizer output.
///
/// The key is an exact caller-supplied identity (for code blocks, language plus
/// the full source text), never a bare hash: a collision would substitute
/// different code. Only completed, non-fallback results are inserted. Keeping
/// the cache on the main actor means `CodeTokenizer` remains the only serial
/// Prism owner and no JavaScript context is shared across threads.
@MainActor
final class TextualTokenCache<Token: Sendable> {
  private struct Entry {
    let tokens: [Token]
    let bytes: Int
    var lastAccess: UInt64
  }

  private let limit: Int
  private let byteLimit: Int
  private let estimatedBytes: (Token) -> Int
  private var entries: [String: Entry] = [:]
  private var totalBytes = 0
  private var clock: UInt64 = 0

  init(
    limit: Int = 64,
    byteLimit: Int = 4 << 20,
    estimatedBytes: @escaping (Token) -> Int = { _ in 64 }
  ) {
    precondition(limit > 0 && byteLimit > 0)
    self.limit = limit
    self.byteLimit = byteLimit
    self.estimatedBytes = estimatedBytes
  }

  func value(for key: String) -> [Token]? {
    guard var entry = entries[key] else { return nil }
    clock &+= 1
    entry.lastAccess = clock
    entries[key] = entry
    return entry.tokens
  }

  func insert(_ tokens: [Token], for key: String) {
    let bytes = tokens.reduce(key.utf8.count + 64) { $0 + estimatedBytes($1) }
    if let replaced = entries.removeValue(forKey: key) { totalBytes -= replaced.bytes }
    clock &+= 1
    entries[key] = Entry(tokens: tokens, bytes: bytes, lastAccess: clock)
    totalBytes += bytes
    // Evict least-recently-used entries until both the row and byte budgets
    // hold. A single entry larger than the byte budget evicts itself.
    while entries.count > limit || totalBytes > byteLimit {
      guard let victim = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) else { break }
      if let removed = entries.removeValue(forKey: victim.key) { totalBytes -= removed.bytes }
    }
  }
}

/// Main-actor publication gate shared by the actual highlighter and Linux
/// tests. Cancellation is cooperative: an already-running JS call may finish,
/// but only its exact input and generation may publish a result.
@MainActor
final class TextualTokenizationWork<Input: Equatable, Token: Equatable & Sendable> {
  private var generation: UInt64 = 0
  private var current: Input?
  // One completed input per mounted fragment, plus optional reuse from the
  // bounded process-wide cache. A plain fallback published before await does
  // not mark the request complete.
  private var completedInput: Input?
  private var completedTokens: [Token]?
  private let sharedCache: TextualTokenCache<Token>?

  init(sharedCache: TextualTokenCache<Token>? = nil) {
    self.sharedCache = sharedCache
  }

  func cancel() {
    generation &+= 1
    current = nil
  }

  func run(
    input: Input,
    plain: [Token],
    cacheKey: String? = nil,
    operation: (@Sendable () async -> [Token])?,
    publish: @MainActor ([Token]) -> Void
  ) async {
    guard !Task.isCancelled else { return }
    generation &+= 1
    let ticket = generation
    current = input
    if completedInput == input, let completedTokens {
      publish(completedTokens)
      return
    }
    completedInput = nil
    completedTokens = nil
    // A hit skips the tokenizer operation entirely; completed output for this
    // exact key never depends on the current input instance.
    if let sharedCache, let cacheKey, let cached = sharedCache.value(for: cacheKey) {
      completedInput = input
      completedTokens = cached
      publish(cached)
      return
    }
    publish(plain)
    guard !Task.isCancelled, generation == ticket, current == input else { return }
    guard let operation else {
      completedInput = input
      completedTokens = plain
      return
    }
    let result = await operation()
    guard !Task.isCancelled, generation == ticket, current == input else { return }
    completedInput = input
    completedTokens = result
    // Never cache the plain fallback: it can mean the tokenizer was
    // unavailable or the caller was cancelled, and a later attempt must retry.
    if let sharedCache, let cacheKey, result != plain {
      sharedCache.insert(result, for: cacheKey)
    }
    publish(result)
  }
}
