import UIKit
import GeckoView

private func findGeckoView(in view: UIView) -> GeckoView? {
    if let gecko = view as? GeckoView {
        return gecko
    }
    for child in view.subviews {
        if let found = findGeckoView(in: child) {
            return found
        }
    }
    return nil
}

@_cdecl("CGFixGeckoViewport")
public func CGFixGeckoViewport(_ rootPointer: UnsafeMutableRawPointer?) {
    guard let rootPointer else { return }
    let root = Unmanaged<UIView>.fromOpaque(rootPointer).takeUnretainedValue()
    guard let session = findGeckoView(in: root)?.session else { return }

    // Reynard still calculates dynamic-toolbar insets after the browser chrome
    // has been hidden. Reset the engine-side viewport so ChatGPT can use the
    // entire visible app area down to the iOS safe area.
    session.setDynamicToolbarMaxHeight(0, minHeight: 0)
    session.setContentOffsets(
        top: 0,
        bottom: 0,
        topInset: 0,
        bottomInset: 0,
        contentTranslationY: 0
    )
}
