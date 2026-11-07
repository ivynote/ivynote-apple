import Foundation
import Observation

/// The languages of the interface: Chinese first, English second, as on the
/// web (`client/packages/core/src/i18n.ts`). The raw value is what the web
/// keeps in `ivy.lang` and what the server is expected to store for an account.
public enum Language: String, CaseIterable, Sendable {
    case zh
    case en

    public var strings: any Strings {
        switch self {
        case .zh: return ZhStrings()
        case .en: return EnStrings()
        }
    }

    /// Each language in its own name, so it can be found whatever the interface speaks.
    public var nativeName: String {
        switch self {
        case .zh: "简体中文"
        case .en: "English"
        }
    }

    /// For dates and numbers. Chinese is always the simplified script.
    public var locale: Locale {
        switch self {
        case .zh: Locale(identifier: "zh-Hans")
        case .en: Locale(identifier: "en")
        }
    }

    /// `zh`, `zh-Hans-CN`, `zh_TW`, `en-GB`… to a supported language; nil for any other.
    public init?(tag: String?) {
        guard let primary = tag?.trimmingCharacters(in: .whitespaces).lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init),
            let language = Language(rawValue: primary) else { return nil }
        self = language
    }

    /// The first supported language in the system's preference list (most
    /// preferred first); English when none is.
    public static func fromSystem(_ tags: [String]) -> Language {
        tags.lazy.compactMap { Language(tag: $0) }.first ?? .en
    }
}

/// A language choice: follow the system, or one language.
public enum LanguageChoice: Hashable, Sendable {
    case system
    case fixed(Language)

    public static let systemTag = "system"

    /// `system`, `zh`, `en`: how it is stored, and sent to the server.
    public var tag: String {
        switch self {
        case .system: Self.systemTag
        case .fixed(let l): l.rawValue
        }
    }

    public init?(tag: String?) {
        guard let tag else { return nil }
        if tag == Self.systemTag {
            self = .system
        } else if let l = Language(tag: tag) {
            self = .fixed(l)
        } else {
            return nil
        }
    }

    public static let all: [LanguageChoice] = [.system] + Language.allCases.map { .fixed($0) }
}

/// The strings of the current language, for code without a view (errors,
/// shelf labels). Safe from any thread.
public enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: Language = .zh

    public static var language: Language {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    public static var s: any Strings { language.strings }
}

/// Which language the interface speaks, in this order (guide §界面语言):
///
/// 1. the signed-in account's language (`User.language`, kept by the server,
///    the same on every device), when a synced library is open and it is set;
/// 2. the choice made on this device, remembered across launches and sign-outs;
/// 3. the system's language (the first supported one in its list, else English).
///
/// Choosing in settings sets this device's choice and, when an account is
/// open, the account's (`PATCH /me {language}`; "follow the system" clears
/// it). A change made offline is kept as pending and sent once the server
/// can be reached (`pendingTag`, `pushed`). A new account is registered with
/// the language in use at that moment.
@MainActor
@Observable
public final class LanguageSettings {
    public static let deviceKey = "ivy.language"
    public static let pendingKeyPrefix = "ivy.language.pending."

    public static let shared = LanguageSettings()

    @ObservationIgnored private let defaults: UserDefaults
    /// Whether `L10n` follows this instance (off in tests, which run in parallel).
    @ObservationIgnored private let isGlobal: Bool
    private var systemTags: [String]
    private var account: String?
    private var accountLanguage: Language?

    /// The language in use.
    public private(set) var current: Language
    /// What the settings page shows as selected.
    public private(set) var choice: LanguageChoice

    /// Called when the user changes the open account's language: send `tag` to the server.
    @ObservationIgnored public var onAccountChoice: ((_ accountKey: String, _ tag: String) -> Void)?

    public init(defaults: UserDefaults = .standard, systemTags: [String] = Locale.preferredLanguages, isGlobal: Bool = true) {
        self.defaults = defaults
        self.isGlobal = isGlobal
        self.systemTags = systemTags
        let device = LanguageChoice(tag: defaults.string(forKey: Self.deviceKey)) ?? .system
        choice = device
        current = Self.resolve(device, systemTags)
        if isGlobal { L10n.language = current }
    }

    /// An account across devices: its server and user id.
    public nonisolated static func accountKey(server: ServerAddress, userID: String) -> String {
        "\(server.base.absoluteString)|\(userID)"
    }

    /// This device's choice; `.system` until the user picks one.
    public var deviceChoice: LanguageChoice {
        LanguageChoice(tag: defaults.string(forKey: Self.deviceKey)) ?? .system
    }

    /// The system's own language, for "follow the system".
    public var systemLanguage: Language { Language.fromSystem(systemTags) }

    /// Whether an account is open, so a choice is saved to it too.
    public var hasAccount: Bool { account != nil }

    /// The system language changed (or the app's language in the system settings).
    public func systemChanged(_ tags: [String] = Locale.preferredLanguages) {
        systemTags = tags
        update()
    }

    /// The user picked a language in settings.
    public func choose(_ choice: LanguageChoice) {
        if choice == .system {
            defaults.removeObject(forKey: Self.deviceKey)
        } else {
            defaults.set(choice.tag, forKey: Self.deviceKey)
        }
        if let account {
            // "Follow the system" clears the account's language.
            var language: Language?
            if case .fixed(let l) = choice { language = l }
            let tag = language?.rawValue ?? ""
            accountLanguage = language
            defaults.set(tag, forKey: Self.pendingKeyPrefix + account)
            onAccountChoice?(account, tag)
        }
        update()
    }

    /// A synced library is open with a signed-in account, or its account was
    /// refreshed. `serverLanguage` is `User.language` ("" when not set). A
    /// change not sent yet wins over it.
    public func accountOpened(_ accountKey: String, serverLanguage: String) {
        account = accountKey
        accountLanguage = Language(tag: pendingTag(accountKey) ?? serverLanguage)
        update()
    }

    /// The account's library closed (switched, signed out): back to this device's choice.
    public func accountClosed(_ accountKey: String) {
        guard account == accountKey else { return }
        account = nil
        accountLanguage = nil
        update()
    }

    /// A language change for the account not yet saved on the server ("" clears it), if any.
    public func pendingTag(_ accountKey: String) -> String? {
        defaults.string(forKey: Self.pendingKeyPrefix + accountKey)
    }

    /// The server took `tag`; a newer pending change stays.
    public func pushed(_ accountKey: String, tag: String) {
        if pendingTag(accountKey) == tag { defaults.removeObject(forKey: Self.pendingKeyPrefix + accountKey) }
    }

    private static func resolve(_ choice: LanguageChoice, _ tags: [String]) -> Language {
        switch choice {
        case .system: Language.fromSystem(tags)
        case .fixed(let l): l
        }
    }

    private func update() {
        let selected = accountLanguage.map(LanguageChoice.fixed) ?? deviceChoice
        let language = Self.resolve(selected, systemTags)
        if isGlobal { L10n.language = language }
        if choice != selected { choice = selected }
        if current != language { current = language }
    }
}
