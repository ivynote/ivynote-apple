import IvynoteKit
import SwiftUI

/// The interface's strings in the language in use. Read in a view's body,
/// it is observed (`LanguageSettings` is `@Observable`): a language change
/// redraws the view. Code that may run off the main actor uses `L10n.s`.
@MainActor
var L: any Strings { LanguageSettings.shared.current.strings }

extension LanguageChoice {
    /// "跟随系统（English）", "简体中文".
    @MainActor
    var label: String {
        switch self {
        case .system: L.followSystem(LanguageSettings.shared.systemLanguage.nativeName)
        case .fixed(let language): language.nativeName
        }
    }
}

/// Picks the interface language: follow the system, or one language. Signed
/// in to a synced library, the choice is the account's (it wins on every
/// device); otherwise this device's.
struct LanguagePicker: View {
    var body: some View {
        let settings = LanguageSettings.shared
        Picker(selection: Binding(get: { settings.choice }, set: { settings.choose($0) })) {
            ForEach(LanguageChoice.all, id: \.self) { choice in
                Text(choice.label).tag(choice)
            }
        } label: {
            Label(L.language, systemImage: "globe")
        }
    }
}

/// The hint under the picker: where the choice is kept.
struct LanguageHint: View {
    var body: some View {
        Text(LanguageSettings.shared.hasAccount ? L.languageAccountHint : L.languageDeviceHint)
    }
}

extension View {
    /// Dates and numbers in the interface language; follows system changes.
    func interfaceLanguage() -> some View {
        modifier(InterfaceLanguage())
    }
}

private struct InterfaceLanguage: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.locale, LanguageSettings.shared.current.locale)
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                LanguageSettings.shared.systemChanged()
            }
    }
}
