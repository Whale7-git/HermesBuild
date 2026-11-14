import SwiftUI

extension StructuredText {
  struct BlockContent<Content: AttributedStringProtocol>: View {
    /// 只有已完成的消息才合并相邻段落：流式期间合并会让分组随字数变化，
    /// 选字时还会被结构重建打断。
    @Environment(\.textualBlockCoalescing) private var coalescing

    private let parent: PresentationIntent.IntentType?
    private let content: Content

    init(parent: PresentationIntent.IntentType? = nil, content: Content) {
      self.parent = parent
      self.content = content
    }

    var body: some View {
      let runs = Array(content.blockRuns(parent: parent))
      let groups = coalescing
        ? BlockCoalescer.groups(items(for: runs))
        : runs.indices.map { $0...$0 }

      BlockVStack {
        ForEach(groups.indices, id: \.self) { index in
          let group = groups[index]
          let first = runs[group.lowerBound]
          let last = runs[group.upperBound]
          Block(intent: first.intent,
                content: content[first.range.lowerBound..<last.range.upperBound])
            .equatable()
        }
      }
    }

    /// Coalesces consecutive plain paragraphs so a selection drag can cross a
    /// paragraph boundary inside one native text view. Headings, lists, code
    /// blocks, tables, math and paragraphs carrying attachments stay separate.
    private func items(for runs: [AttributedString.BlockRuns.BlockRun]) -> [BlockCoalescer.Item] {
      runs.enumerated().map { index, run in
        let body = content[run.range]
        // 段落之间那一两个换行会自成一块（intent 与前后段落不同），而它既不是
        // paragraph、也没有附件，按原规则就不可合并——于是每两段之间都插进一个
        // 不可合并的块，把相邻段落切开，跨段选择永远不生效。纯空白块并进相邻
        // 段落是无损的：它是段落分隔符，本来就该跟着段落走。
        let isPlain = run.intent?.kind == .paragraph || BlockCoalescer.isBlank(body.characters)
        return BlockCoalescer.Item(
          // A math block is itself an attachment, so this one check excludes
          // both math and inline attachments without scanning attributes twice.
          isMergeable: isPlain && body.attachments().isEmpty,
          isContiguousWithPrevious: index == 0
            || runs[index - 1].range.upperBound == run.range.lowerBound
        )
      }
    }
  }
}

extension StructuredText {
  struct Block: View, Equatable {
    private let intent: PresentationIntent.IntentType?
    private let content: AttributedSubstring

    init(intent: PresentationIntent.IntentType?, content: AttributedSubstring) {
      self.intent = intent
      self.content = content
    }

    var body: some View {
      switch intent?.kind {
      case .paragraph where content.isMathBlock:
        MathBlock(content)
      case .paragraph:
        Paragraph(content)
      case .header(let level):
        Heading(content, level: level)
      case .orderedList:
        OrderedList(intent: intent, content: content)
      case .unorderedList:
        UnorderedList(intent: intent, content: content)
      case .codeBlock(let languageHint) where languageHint?.lowercased() == "math":
        MathCodeBlock(content)
      case .codeBlock(let languageHint):
        CodeBlock(content, languageHint: languageHint)
      case .blockQuote:
        BlockQuote(intent: intent, content: content)
      case .thematicBreak:
        ThematicBreak(content)
      case .table(let columns):
        Table(intent: intent, content: content, columns: columns)
      default:
        Paragraph(content)
      }
    }
  }
}
