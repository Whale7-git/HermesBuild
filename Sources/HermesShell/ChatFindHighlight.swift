import Foundation

/// 在「渲染后的纯文本」上重新检索，得到按字符（grapheme）计的命中区间。
///
/// 查找栏的 `ChatConversationSearch.Hit.location` 是源码 UTF-16 偏移，和
/// Textual 排版后的字形没有对应关系；因此这里不建映射表，而是让每个可视
/// 文本叶子各自在渲染结果上检索，再用「行内第 N 个命中」对齐当前项。
enum ChatFindHighlight {
    /// 按「字符（grapheme）」计的匹配区间；大小写/变音不敏感、字面匹配。
    /// 空 query 或 limit <= 0 返回 []。不得返回跨越 grapheme 的区间。
    static func characterRanges(of query: String, in plain: String, limit: Int = 300) -> [Range<Int>] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.utf16.count <= 512, limit > 0, !plain.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(min(limit, 8))
        var searchStart = plain.startIndex
        while searchStart < plain.endIndex, ranges.count < limit {
            guard let match = plain.range(of: term, options: options, range: searchStart..<plain.endIndex)
            else { break }
            // NSString 的大小写/变音不敏感检索可能落在组合序列内部；向外对齐到
            // grapheme 边界，保证返回区间永远不切开一个字符。
            let aligned = graphemeAligned(match, in: plain)
            guard aligned.lowerBound < aligned.upperBound else { break }
            let lower = plain.distance(from: plain.startIndex, to: aligned.lowerBound)
            let upper = plain.distance(from: plain.startIndex, to: aligned.upperBound)
            if upper > lower { ranges.append(lower..<upper) }
            // 同一位置不重复命中：每次都从本次命中的尾部继续。
            guard aligned.upperBound > searchStart else { break }
            searchStart = aligned.upperBound
        }
        return ranges
    }

    static func utf16Ranges(of query: String, in plain: String, limit: Int = 300) -> [NSRange] {
        characterRanges(of: query, in: plain, limit: limit).compactMap { value in
            guard let lower = plain.index(plain.startIndex, offsetBy: value.lowerBound, limitedBy: plain.endIndex),
                  let upper = plain.index(plain.startIndex, offsetBy: value.upperBound, limitedBy: plain.endIndex)
            else { return nil }
            return NSRange(lower..<upper, in: plain)
        }
    }

    /// 把可能切开组合序列的区间扩到完整 grapheme。
    private static func graphemeAligned(_ range: Range<String.Index>, in text: String)
        -> Range<String.Index> {
        var lower = range.lowerBound
        var upper = range.upperBound
        if lower < text.endIndex {
            let cluster = text.rangeOfComposedCharacterSequence(at: lower)
            if cluster.lowerBound < lower { lower = cluster.lowerBound }
        }
        if upper < text.endIndex {
            let cluster = text.rangeOfComposedCharacterSequence(at: upper)
            if cluster.lowerBound < upper { upper = cluster.upperBound }
        }
        return lower..<upper
    }
}
