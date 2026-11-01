import SwiftUI
import UIKit

/// Popup cards report their actual window-space bounds, after reader chrome, safe areas and
/// recursive-card positioning. Only the card itself is a touch target; its surrounding space
/// belongs to the reader's dismissal gesture.
nonisolated struct LookupPopupBoundsKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    func reportsLookupPopupBounds() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: LookupPopupBoundsKey.self, value: [geometry.frame(in: .global)])
            }.allowsHitTesting(false)
        }
    }

    /// The first touch outside an open or pending lookup closes it. The transparent native view
    /// owns that complete touch stream, so a word, menu or navigation button underneath cannot
    /// act on the same touch after SwiftUI removes the popup.
    func consumesOutsideLookupTouches(isActive: Bool, dismiss: @escaping () -> Void) -> some View {
        modifier(LookupOutsideTouchModifier(isActive: isActive, dismiss: dismiss))
    }
}

private struct LookupOutsideTouchModifier: ViewModifier {
    let isActive: Bool
    let dismiss: () -> Void
    @State private var popupBounds: [CGRect] = []

    func body(content: Content) -> some View {
        content
            .overlay {
                LookupOutsideTouchOverlay(isActive: isActive, popupBounds: popupBounds, dismiss: dismiss)
                    .accessibilityHidden(true)
            }
            .onPreferenceChange(LookupPopupBoundsKey.self) { popupBounds = $0 }
    }
}

private struct LookupOutsideTouchOverlay: UIViewRepresentable {
    let isActive: Bool
    let popupBounds: [CGRect]
    let dismiss: () -> Void

    func makeUIView(context: Context) -> LookupOutsideTouchView { LookupOutsideTouchView() }
    func updateUIView(_ view: LookupOutsideTouchView, context: Context) {
        view.lookupIsActive = isActive
        view.popupBounds = popupBounds
        view.dismissLookup = dismiss
    }
}

/// A hit-test barrier, rather than a competing gesture recognizer: WKWebView and SwiftUI chrome
/// never receive the outside touch, while touches inside a card reach its ordinary controls.
final class LookupOutsideTouchView: UIView {
    var lookupIsActive = false
    var popupBounds: [CGRect] = []
    var dismissLookup: () -> Void = {}
    private(set) var consumesStream = false
    private var activeTouches: Set<ObjectIdentifier> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled, bounds.contains(point) else { return nil }
        if consumesStream { return self }
        guard lookupIsActive else { return nil }
        let windowPoint = convert(point, to: nil)
        return popupBounds.contains(where: { $0.contains(windowPoint) }) ? nil : self
    }

    func beginOutsideTouch() {
        guard !consumesStream else { return }
        consumesStream = true
        dismissLookup()
    }
    func endOutsideTouch() { consumesStream = false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.formUnion(touches.map(ObjectIdentifier.init))
        beginOutsideTouch()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches.map(ObjectIdentifier.init))
        if activeTouches.isEmpty { endOutsideTouch() }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches.map(ObjectIdentifier.init))
        if activeTouches.isEmpty { endOutsideTouch() }
    }
}
