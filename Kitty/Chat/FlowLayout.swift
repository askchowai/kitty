import SwiftUI

/// Lays children out left to right and wraps to a new line when the width runs out, like
/// recipient chips in Messages' To: field.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    /// Each child is measured against the room left on its row: a text field takes what is
    /// left rather than its (large) ideal width, so it only wraps when its minimum will not fit.
    private func rows(width: CGFloat, subviews: Subviews) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let remaining = max(0, width - x)
            let minW = v.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
            if x > 0, minW > remaining { rows.append([]); x = 0 }
            let s = v.sizeThatFits(ProposedViewSize(width: max(0, width - x), height: nil))
            let w = min(s.width, max(0, width - x))
            rows[rows.count - 1].append((i, CGSize(width: w, height: s.height)))
            x += w + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let h = rows(width: width, subviews: subviews).reduce(CGFloat(0)) { $0 + ($1.map(\.size.height).max() ?? 0) }
        let n = rows(width: width, subviews: subviews).count
        return CGSize(width: width, height: h + CGFloat(max(0, n - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y: CGFloat = 0
        for row in rows(width: bounds.width, subviews: subviews) {
            let rowHeight = row.map(\.size.height).max() ?? 0
            var x: CGFloat = 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y + (rowHeight - item.size.height) / 2),
                                           proposal: ProposedViewSize(width: item.size.width, height: item.size.height))
                x += item.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
