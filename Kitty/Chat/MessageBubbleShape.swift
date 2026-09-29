import SwiftUI

/// A message bubble with the Messages tail: the edge on the speaker's side flows down into a
/// small point at the bottom corner, then curls back under. `tailed` false gives the plain
/// rounded bubble used for every message but the last of a run.
struct MessageBubbleShape: Shape {
    enum Side { case leading, trailing }
    var side: Side
    var tailed = true
    var radius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        guard tailed else { return Path(roundedRect: rect, cornerRadius: r, style: .continuous) }
        // Drawn for a trailing tail; mirrored for a leading one.
        let x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
        let tail: CGFloat = 6
        var p = Path()
        p.move(to: CGPoint(x: x0 + r, y: y0))
        p.addLine(to: CGPoint(x: x1 - r, y: y0))
        p.addArc(center: CGPoint(x: x1 - r, y: y0 + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: x1, y: y1 - r))
        // The tail: the edge keeps going down and flares out to a point at the bottom…
        p.addCurve(to: CGPoint(x: x1 + tail, y: y1),
                   control1: CGPoint(x: x1, y: y1 - r * 0.45),
                   control2: CGPoint(x: x1 + tail * 0.9, y: y1 - r * 0.18))
        // …then sweeps back in under itself to the flat bottom edge.
        p.addCurve(to: CGPoint(x: x1 - r * 0.6, y: y1),
                   control1: CGPoint(x: x1 + tail * 0.25, y: y1),
                   control2: CGPoint(x: x1 - r * 0.12, y: y1 - r * 0.04))
        p.addLine(to: CGPoint(x: x0 + r, y: y1))
        p.addArc(center: CGPoint(x: x0 + r, y: y1 - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: x0, y: y0 + r))
        p.addArc(center: CGPoint(x: x0 + r, y: y0 + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        if side == .leading {
            p = p.applying(CGAffineTransform(translationX: rect.midX, y: 0).scaledBy(x: -1, y: 1).translatedBy(x: -rect.midX, y: 0))
        }
        return p
    }
}
