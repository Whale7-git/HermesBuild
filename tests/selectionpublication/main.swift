import Foundation

var checks = 0
@MainActor func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message); checks += 1
}
var publication = TextualSelectionPublication<String>()
check(publication.receive("你好🙂", interacting: false) == "你好🙂", "initial document")
check(publication.receive("你好🙂", interacting: false) == nil, "no redundant text assignment")
check(publication.receive("你好🙂 一", interacting: true) == nil, "selection freezes text")
check(publication.displayed == "你好🙂", "selected glyph positions unchanged")
check(publication.receive("你好🙂 一二三", interacting: true) == nil, "latest live append retained")
check(publication.pending == "你好🙂 一二三", "coalesced pending value")
check(publication.resume(interacting: true) == nil, "active handles keep original text")
check(publication.resume(interacting: false) == "你好🙂 一二三", "end selection publishes latest")
check(publication.pending == nil, "no replay")
_ = publication.receive("old pending", interacting: true)
_ = publication.receive("你好🙂 一二三", interacting: true)
check(publication.resume(interacting: false) == nil, "returned-to-current supersedes stale pending")
_ = publication.receive("different replacement", interacting: true)
publication.cancel()
check(publication.resume(interacting: false) == nil, "dismantled host cannot replay pending text")
check(publication.receive("", interacting: false) == "", "empty replacement clears old document")
print("SELECTION_PUBLICATION_PASS \(checks) assertions (production gate; UIKit selection untested)")
