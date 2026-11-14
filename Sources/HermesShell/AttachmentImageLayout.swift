import SwiftUI

/// Measures one immutable outer box; loading/error/image children all receive
/// the same proposal. No geometry-to-State feedback or image-driven row resize.
struct AttachmentImageFrame: Layout {
    let ratio: CGFloat?
    var tile = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = max(1, proposal.width ?? 320)
        if tile { return CGSize(width: available, height: available) }
        if InlineImageLayout.isLong(ratio: ratio) {
            return CGSize(width: available, height: InlineImageLayout.longHeight)
        }
        let r = InlineImageLayout.normalized(ratio) ?? (1 / InlineImageLayout.placeholderAspect)
        let width = min(available, InlineImageLayout.maxHeight / r)
        return CGSize(width: width, height: width * r)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            view.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

struct AttachmentTileLayout: Layout {
    var singleColumn = false
    private var spacing: CGFloat { 8 }

    private func dimensions(_ width: CGFloat, count: Int) -> (Int, CGFloat, Int) {
        let columns = singleColumn ? 1 : 2
        return (columns, max(1, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)),
                (count + columns - 1) / columns)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? 320)
        let (_, side, rows) = dimensions(width, count: subviews.count)
        return CGSize(width: width, height: CGFloat(rows) * side + CGFloat(max(0, rows - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (columns, side, _) = dimensions(bounds.width, count: subviews.count)
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(index % columns) * (side + spacing),
                y: bounds.minY + CGFloat(index / columns) * (side + spacing)),
                proposal: ProposedViewSize(width: side, height: side))
        }
    }
}
