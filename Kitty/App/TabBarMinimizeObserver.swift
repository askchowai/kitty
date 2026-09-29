import SwiftUI
import UIKit

/// Reports whether the system tab bar is minimized (the small circle it shrinks into on
/// scroll-down). There is no API for this, so a zero-size probe view finds the tab bar in the
/// window and watches its width every frame; a floating button can then move at the same moment
/// the bar itself does, rather than on a guess about scroll distance.
struct TabBarMinimizeObserver: UIViewRepresentable {
    @Binding var minimized: Bool

    func makeUIView(context: Context) -> Probe {
        let p = Probe()
        p.onChange = { m in if m != minimized { minimized = m } }
        return p
    }

    func updateUIView(_ uiView: Probe, context: Context) {
        uiView.onChange = { m in if m != minimized { minimized = m } }
    }

    static func dismantleUIView(_ uiView: Probe, coordinator: ()) { uiView.stop() }

    final class Probe: UIView {
        var onChange: ((Bool) -> Void)?
        private var link: CADisplayLink?
        private weak var bar: UIView?
        private var last: Bool?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stop()
            guard window != nil else { return }
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30)
            l.add(to: .main, forMode: .common)
            link = l
        }

        func stop() { link?.invalidate(); link = nil }

        private var ticks = 0
        @objc private func tick() {
            guard let window else { return }
            ticks += 1
            if bar == nil || bar?.window == nil || ticks % 20 == 0 { bar = Self.findTabBar(in: window) }
            guard let bar else { return }
            // Expanded, the bar spans most of the screen; minimized it is a small circle.
            let m = bar.bounds.width < window.bounds.width * 0.5
            if m != last { last = m; onChange?(m) }
        }

        /// The narrowest bar-shaped view whose class mentions TabBar: expanded, every candidate is
        /// wide; minimized, the circle itself is the narrow one, whatever containers sit around it.
        private static func findTabBar(in root: UIView) -> UIView? {
            var best: UIView?
            func walk(_ v: UIView, depth: Int) {
                if depth > 14 { return }
                let name = String(describing: type(of: v))
                if name.contains("TabBar"), v.bounds.height > 30, v.bounds.height < 140, v.bounds.width > 40, v.alpha > 0.01, !v.isHidden {
                    if best == nil || v.bounds.width < best!.bounds.width { best = v }
                }
                for s in v.subviews { walk(s, depth: depth + 1) }
            }
            walk(root, depth: 0)
            return best
        }


    }
}
