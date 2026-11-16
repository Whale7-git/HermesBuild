import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { print("FAIL: \(message)"); exit(1) }
}

let simple = MarkdownBlockPlan.make("first\n\nsecond\n\nactive")
expect(simple.complete == ["first\n\n", "second\n\n"] && simple.tail == "active", "only complete paragraph boundaries freeze")
expect(MarkdownBlockPlan.make("paragraph\n").complete.isEmpty, "a single newline is not a paragraph boundary")
let fenced = MarkdownBlockPlan.make("before\n\n```swift\n\na[0] < b\n```\nafter")
expect(fenced.complete.count == 2 && !fenced.requiresWholeDocument && fenced.tail == "after", "code contents do not become document reference hazards")
expect(MarkdownBlockPlan.make("```\ncode\n```").complete.isEmpty, "an unterminated closing-fence LINE can still change")
expect(MarkdownBlockPlan.make("```\ncode\n````\nnext").complete.count == 1, "a longer closing fence is valid")
expect(MarkdownBlockPlan.make("~~~~\n```\n~~~\n\nend").complete.isEmpty, "shorter and mismatched fences remain active")
expect(MarkdownBlockPlan.make("   ```\ncode\n   ```\nx").complete.count == 1, "up to three indent spaces preserve fences")
let containers = ["- one\n\n  continued\n\nmore", "1. one\n\n   nested", "> quote\n\ncontinued",
                  "    code\n\n    continued", "\tcode\n\nnext", "a | b\n---|---\n1|2\n\nnext"]
for source in containers {
    let result = MarkdownBlockPlan.make("prefix\n\n" + source)
    expect(result.complete == ["prefix\n\n"] && result.tail == source, "container tails preserve all parsing context")
}
for source in ["[link][ref]\n\n[ref]: https://example.com", "before\n\n<img src='x'>", "x\r\ny\r\n\r\nz"] {
    let result = MarkdownBlockPlan.make(source)
    expect(result.requiresWholeDocument && result.complete.isEmpty && result.tail == source, "document-wide constructs keep the authoritative parser")
}
let fixtures = containers + ["", "\n\n", "你好🙂\n\n👩🏽‍💻e\u{301}\n\nend", "# heading\n\nnext",
    "Title\n-----\n\nnext", "```bad`info\n\nplain", "   ~~~text\n[]<x>\n   ~~~\nnext"]
for source in fixtures {
    let characters = Array(source)
    for end in 0...characters.count {
        let input = String(characters.prefix(end))
        let result = MarkdownBlockPlan.make(input)
        expect(result.complete.joined() + result.tail == input, "every prefix preserves source bytes and Unicode")
    }
}
// Incremental planning must equal the full authoritative boundary scan at
// every appended prefix, including opaque containers and UTF-8 boundaries.
let incrementalFixtures = fixtures + [
    "first\\n\\nsecond\\n\\nthird\\n\\nlast".replacingOccurrences(of: "\\\\n", with: "\\n"),
    "start\\n\\n\u{1F600}\\n\\n\\\`\\\`\\\`swift\\ncode\\n\\\`\\\`\\\`\\nend"
        .replacingOccurrences(of: "\\\\n", with: "\\n"),
    "prefix\\n\\n[link][ref]\\n\\n[ref]: /url"
        .replacingOccurrences(of: "\\\\n", with: "\\n")
]
for source in incrementalFixtures {
    var last = ""
    var planned: MarkdownBlockPlan.Plan?
    for end in 0...source.count {
        let current = String(source.prefix(end))
        let next = MarkdownBlockPlan.makeAppending(current, after: last, plan: planned)
        let full = MarkdownBlockPlan.make(current)
        expect(next == full, "append-only plan equals complete scan at every prefix")
        last = current
        planned = next
    }
}
let longStable = (0..<1000).map { "item \($0)\\n\\n" }.joined()
let longPlan = MarkdownBlockPlan.make(longStable)
let grownPlan = MarkdownBlockPlan.makeAppending(longStable + "active", after: longStable, plan: longPlan)
expect(grownPlan.complete.count == longPlan.complete.count &&
       grownPlan.tail == "active", "long stable prefix remains frozen when only tail grows")
let rewrittenPlan = MarkdownBlockPlan.makeAppending("replacement", after: longStable, plan: longPlan)
expect(rewrittenPlan == MarkdownBlockPlan.make("replacement"),
       "replacement source discards previous incremental boundaries")

let ready = MarkdownRenderRequest(source: "first", finished: false)
expect(MarkdownRenderGate.allows(ready, latest: .init(source: "first second", finished: false)), "a slower valid append may be displayed")
expect(!MarkdownRenderGate.allows(ready, latest: .init(source: "replacement", finished: false)), "late replacement results cannot overwrite new content")
expect(!MarkdownRenderGate.allows(ready, latest: .init(source: "first second", finished: true)), "finalized content rejects a stale live result")
expect(!MarkdownRenderGate.allows(.init(source: "first", finished: true), latest: .init(source: "first second", finished: true)), "late final content cannot overwrite a different final")
expect(MarkdownRenderGate.allows(.init(source: "first", finished: true), latest: .init(source: "first", finished: true)), "the exact final request publishes")
let growing = (0..<500).map { "段落 \($0)\n\n" }.joined()
let planned = MarkdownBlockPlan.make(growing + "活动末尾")
expect(planned.complete.count == 500 && planned.tail == "活动末尾", "long simple replies expose a small active tail")
print("MARKDOWN_BLOCK_PLAN_PASS \(checks) assertions (source boundaries/publication; native semantics checked in app)")
