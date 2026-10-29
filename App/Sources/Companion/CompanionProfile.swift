import Foundation

/// Who the companion is and who to call. Stored on this phone only.
struct CompanionProfile: Codable, Equatable {
    var name = "Bolt"
    var appearance = Appearance()
    var contactName: String?
    var contactPhone: String?
    var showTalkButton = false
    var theme = AppTheme.stickerBook

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CompanionProfile()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        appearance = (try? c.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? d.appearance
        contactName = try c.decodeIfPresent(String.self, forKey: .contactName)
        contactPhone = try c.decodeIfPresent(String.self, forKey: .contactPhone)
        showTalkButton = try c.decodeIfPresent(Bool.self, forKey: .showTalkButton) ?? d.showTalkButton
        theme = (try? c.decodeIfPresent(AppTheme.self, forKey: .theme)) ?? d.theme
    }

    static let defaultsKey = "companionProfile"

    static func load(from defaults: UserDefaults = .standard) -> CompanionProfile {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(CompanionProfile.self, from: $0) } ?? CompanionProfile()
    }

    func save(to defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.defaultsKey) }
    }

    /// Name to show; an empty field falls back to the default.
    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? CompanionProfile().name : n
    }

    /// The contact's name when it is usable, else nil.
    var contact: (name: String, phone: String)? {
        guard let phone = contactPhone.map(Self.sanitizedPhone), !phone.isEmpty else { return nil }
        let n = contactName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (n.isEmpty ? "your contact" : n, phone)
    }

    /// Keeps `+` only as the first character and ASCII digits 0-9; everything else is dropped.
    static func sanitizedPhone(_ raw: String) -> String {
        var out = ""
        for ch in raw.unicodeScalars {
            if ch == "+", out.isEmpty { out.append("+") }
            else if ("0"..."9").contains(ch) { out.unicodeScalars.append(ch) }
        }
        return out
    }
}
