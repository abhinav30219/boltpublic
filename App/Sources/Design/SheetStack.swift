import SwiftUI

/// Wraps a pushed-style screen so it can also be presented as a sheet with a Done button.
struct SheetStack<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        NavigationStack {
            content.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(.ink)
    }
}
