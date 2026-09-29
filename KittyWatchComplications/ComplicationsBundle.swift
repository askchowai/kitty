import SwiftUI
import WidgetKit

/// Watch-face complications: the same widgets the iPhone shows on its lock screen.
@main
struct KittyComplicationsBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        AttentionWidget()
        ActivityWidget()
        ContextWidget()
    }
}
