import Foundation

func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
    print("  ok  " + message)
}

func paragraph(contiguous: Bool = true) -> BlockCoalescer.Item {
    BlockCoalescer.Item(isMergeable: true, isContiguousWithPrevious: contiguous)
}

func block(contiguous: Bool = true) -> BlockCoalescer.Item {
    BlockCoalescer.Item(isMergeable: false, isContiguousWithPrevious: contiguous)
}

print("[block coalescer]")

check(BlockCoalescer.groups([]).isEmpty, "no blocks produce no groups")
check(BlockCoalescer.groups([paragraph()]) == [0...0],
      "a single paragraph is its own group")

// 核心场景：相邻两段合并，选择可以跨段拖动
check(BlockCoalescer.groups([paragraph(), paragraph()]) == [0...1],
      "two adjacent paragraphs share one selectable block")
check(BlockCoalescer.groups([paragraph(), paragraph(), paragraph()]) == [0...2],
      "three paragraphs stay in one group: grouping never depends on a size budget")
check(BlockCoalescer.groups([paragraph(), paragraph(), paragraph(), paragraph()]) == [0...3],
      "a long answer is one group, so a 4,001st character cannot split an earlier pair")

// 反例：非段落块必须断开
check(BlockCoalescer.groups([paragraph(), block(), paragraph()]) == [0...0, 1...1, 2...2],
      "a code block between paragraphs breaks the selection range")
check(BlockCoalescer.groups([block(), paragraph(), paragraph()]) == [0...0, 1...2],
      "a heading or list before the prose does not join it")
check(BlockCoalescer.groups([paragraph(), block(), block(), paragraph()])
        == [0...0, 1...1, 2...2, 3...3],
      "consecutive non-paragraph blocks stay separate from each other")
check(BlockCoalescer.groups([paragraph(), block(), paragraph(), block()])
        == [0...0, 1...1, 2...2, 3...3],
      "a trailing code block is never folded into the prose")

// 反例：范围不连续不能合并，否则会吞字符
check(BlockCoalescer.groups([paragraph(), paragraph(contiguous: false)]) == [0...0, 1...1],
      "non-contiguous ranges are never joined")

// The separator classifier must keep build64's whitespace bridge while never
// treating visible combining/emoji/ideographic content as an empty separator.
for value in ["", "\n\n", "\r\n", " \t", "\u{00A0}", "\u{2003}", "\u{2028}\u{2029}",
              "正文", " 👩‍💻 ", "\u{0301}", " \u{0301}", "\n# 标题", "\u{FFFC}"] {
    check(BlockCoalescer.isBlank(value) == value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          "separator classifier preserves Foundation whitespace semantics: \(value.debugDescription)")
}

print("BLOCK_COALESCER_PASS adjacency/blocks/contiguity/no-size-budget; drag selection and spacing require device")
