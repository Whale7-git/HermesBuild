import Foundation

// 离线断言：只依赖 ChatFindHighlight（Foundation only）。
// 统一使用「字符偏移」，不写任何 UTF-16 断言。

var checkIndex = 0
var failures = 0

func describe(_ ranges: [Range<Int>]) -> String {
    "[" + ranges.map { "\($0.lowerBound)..<\($0.upperBound)" }.joined(separator: ", ") + "]"
}

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    checkIndex += 1
    if condition {
        print("FINDHIGHLIGHT \(checkIndex) PASS \(name)")
    } else {
        failures += 1
        let extra = detail()
        print("FINDHIGHLIGHT \(checkIndex) FAIL \(name)" + (extra.isEmpty ? "" : " — \(extra)"))
    }
}

func expect(_ name: String, _ actual: [Range<Int>], _ expected: [Range<Int>]) {
    check(name, actual == expected,
          "expected \(describe(expected)), got \(describe(actual))")
}

// 1. 纯英文多次命中 + 大小写不敏感
let english = "Hello hello HELLO"
expect("english-multiple-case-insensitive", ChatFindHighlight.characterRanges(of: "hello", in: english),
       [0..<5, 6..<11, 12..<17])

// 2. query 先 trim 空白
expect("query-trimmed", ChatFindHighlight.characterRanges(of: "  hello \n", in: english),
       [0..<5, 6..<11, 12..<17])

// 3. 中文：2 处，字符偏移 0 与 4
expect("chinese-two-hits", ChatFindHighlight.characterRanges(of: "你好", in: "你好世界你好"),
       [0..<2, 4..<6])

// 4. emoji 组合：家庭、国旗都按单 grapheme 计
let emoji = "👨‍👩‍👧🇨🇳x"
expect("emoji-family-single-grapheme", ChatFindHighlight.characterRanges(of: "👨‍👩‍👧", in: emoji),
       [0..<1])
expect("emoji-flag-offset", ChatFindHighlight.characterRanges(of: "🇨🇳", in: emoji),
       [1..<2])
expect("emoji-trailing-ascii-offset", ChatFindHighlight.characterRanges(of: "x", in: emoji),
       [2..<3])
expect("emoji-none", ChatFindHighlight.characterRanges(of: "👨‍👩‍👧‍👦", in: emoji), [])

// 5. 重叠不重复：aaaa 查 aa → 2 处，偏移 0 与 2
expect("non-overlapping", ChatFindHighlight.characterRanges(of: "aa", in: "aaaa"),
       [0..<2, 2..<4])
expect("non-overlapping-odd", ChatFindHighlight.characterRanges(of: "aa", in: "aaa"),
       [0..<2])

// 6. 空 / 纯空白 / 超长 query
expect("empty-query", ChatFindHighlight.characterRanges(of: "", in: "abc"), [])
expect("whitespace-query", ChatFindHighlight.characterRanges(of: "   \n\t", in: "abc"), [])
expect("long-query-513", ChatFindHighlight.characterRanges(of: String(repeating: "a", count: 513), in: "aaaa"), [])
expect("long-query-boundary-512",
       ChatFindHighlight.characterRanges(of: String(repeating: "a", count: 512),
                                         in: String(repeating: "a", count: 512), limit: 1),
       [0..<512])

// 7. limit 截断（含 limit <= 0）
expect("limit-truncates", ChatFindHighlight.characterRanges(of: "a", in: "aaaaaa", limit: 2),
       [0..<1, 1..<2])
expect("limit-zero", ChatFindHighlight.characterRanges(of: "a", in: "aaaaaa", limit: 0), [])
expect("limit-negative", ChatFindHighlight.characterRanges(of: "a", in: "aaaaaa", limit: -3), [])

// 8. 变音符号：cafe 命中 café
expect("diacritic-insensitive", ChatFindHighlight.characterRanges(of: "cafe", in: "café"),
       [0..<4])

// 9. 组合序列不被切开：é 是一个 grapheme，命中区间长度必须为 1
let combining = "e\u{301}e"
let combiningHits = ChatFindHighlight.characterRanges(of: "e", in: combining)
check("combining-grapheme-not-split",
      combiningHits == [0..<1, 1..<2],
      "expected [0..<1, 1..<2], got \(describe(combiningHits))")

if failures == 0 {
    print("FINDHIGHLIGHT_ALL_PASS \(checkIndex) checks")
} else {
    print("FINDHIGHLIGHT_FAIL \(failures)/\(checkIndex) checks")
    exit(1)
}
