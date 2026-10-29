import SwiftUI
import ContactsUI

/// System contact picker limited to phone numbers. It runs out of process, so the app needs no Contacts
/// permission and only sees the one number the person taps.
struct ContactPicker: UIViewControllerRepresentable {
    var onPick: (_ name: String, _ phone: String) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let vc = CNContactPickerViewController()
        vc.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        vc.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: CNContactPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (String, String) -> Void
        init(onPick: @escaping (String, String) -> Void) { self.onPick = onPick }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect property: CNContactProperty) {
            guard let number = property.value as? CNPhoneNumber else { return }
            let name = CNContactFormatter.string(from: property.contact, style: .fullName) ?? ""
            onPick(name, number.stringValue)
        }
    }
}

/// Name and number fields plus "Pick from Contacts". Shared by onboarding and More → Companion.
struct ContactFields: View {
    @Binding var name: String
    @Binding var phone: String
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BigButton("Pick from Contacts", fill: .fillOxygen) { picking = true }
            Text("Or type it in").typo(.label, size: 16).foregroundStyle(Color.inkSoft)
            StickerField(placeholder: "Their name", text: $name)
                .textContentType(.name)
            StickerField(placeholder: "Phone number", text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .onChange(of: phone) { _, v in
                    let clean = CompanionProfile.sanitizedPhone(v)
                    if clean != v { phone = clean }
                }
        }
        .sheet(isPresented: $picking) {
            ContactPicker { n, p in
                name = n
                phone = CompanionProfile.sanitizedPhone(p)
                picking = false
            }
            .ignoresSafeArea()
        }
        .dismissesOnFallAlert { picking = false }
    }
}

/// White sticker text field in the design system.
struct StickerField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        field
            .submitLabel(.done)
            .onSubmit { KeyboardDismiss.resign() }
            .typo(.body, size: 19)
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: Sticker.minButtonHeight)
            .sticker(fill: .card, radius: 20)
            .padding(.trailing, Sticker.shadowOffset)
    }

    /// Other themes draw the placeholder in soft ink so it stays readable on their surfaces.
    private var field: some View {
        TextField(placeholder, text: $text, prompt: Color.softPrompt(placeholder))
    }
}
