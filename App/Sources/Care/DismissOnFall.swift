import SwiftUI

extension View {
    /// Runs `close` when a fall alert opens. Put it on every view that presents a sheet, so the
    /// root-level fall cover is never blocked by a sheet that is already up.
    func dismissesOnFallAlert(_ close: @escaping () -> Void) -> some View {
        modifier(DismissOnFallAlert(close: close))
    }
}

private struct DismissOnFallAlert: ViewModifier {
    @EnvironmentObject var model: AppModel
    let close: () -> Void
    func body(content: Content) -> some View {
        content.onChange(of: model.dismissSheetsToken) { _, _ in close() }
    }
}
