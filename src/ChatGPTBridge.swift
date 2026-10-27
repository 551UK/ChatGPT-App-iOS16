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

private func session(from rootPointer: UnsafeMutableRawPointer?) -> GeckoSession? {
    guard let rootPointer else { return nil }
    let root = Unmanaged<UIView>.fromOpaque(rootPointer).takeUnretainedValue()
    return findGeckoView(in: root)?.session
}

@_cdecl("CGFixGeckoViewport")
public func CGFixGeckoViewport(_ rootPointer: UnsafeMutableRawPointer?) {
    guard let session = session(from: rootPointer) else { return }

    // Reynard still calculates dynamic-toolbar insets after its native browser
    // chrome is hidden. Clear the engine-side toolbar geometry so chatgpt.com
    // can use the whole app viewport down to the real iOS safe area.
    session.setDynamicToolbarMaxHeight(0, minHeight: 0)
    session.setContentOffsets(
        top: 0,
        bottom: 0,
        topInset: 0,
        bottomInset: 0,
        contentTranslationY: 0
    )
}

@_cdecl("CGLoadChatGPTHome")
public func CGLoadChatGPTHome(_ rootPointer: UnsafeMutableRawPointer?) {
    session(from: rootPointer)?.load("https://chatgpt.com/")
}

@_cdecl("CGGoBackInGecko")
public func CGGoBackInGecko(_ rootPointer: UnsafeMutableRawPointer?) {
    session(from: rootPointer)?.goBack(userInteraction: true)
}
