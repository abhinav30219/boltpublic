import SwiftUI
import UIKit

/// App-wide keyboard dismissal: tap anywhere outside a text input, scroll, or the Done button.
enum KeyboardDismiss {
    static func resign() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// Installs one window-level tap recognizer. It never cancels touches, so buttons, rows,
/// sliders and drags still get the same tap; it ignores taps that land in a text input.
private final class WindowTapInstaller: UIView, UIGestureRecognizerDelegate {
    private static let marker = UnsafeRawPointer(bitPattern: 0x4B44)!
    private var installed = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard !installed, let window else { return }
        installed = true
        if objc_getAssociatedObject(window, Self.marker) != nil { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        objc_setAssociatedObject(window, Self.marker, tap, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @objc private func tapped() { KeyboardDismiss.resign() }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var v: UIView? = touch.view
        while let cur = v {
            if cur is UITextField || cur is UITextView { return false }
            v = cur.superview
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

private struct WindowTapHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = WindowTapInstaller()
        v.isUserInteractionEnabled = false
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension View {
    /// Apply once at the root.
    func dismissKeyboardOnOutsideTap() -> some View { background(WindowTapHost()) }

    /// "Done" above the keyboard (also covers number/decimal pads). Apply per screen/sheet.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { KeyboardDismiss.resign() }
                    .typo(.label, size: 17)
                    .foregroundStyle(Color.ink)
            }
        }
    }
}
