import Foundation
import Testing
@testable import IvynoteKit

@MainActor
@Suite struct LanguageTests {
    let defaults: UserDefaults
    let alice = "https://web.ivynote.app|u1"
    let bob = "https://web.ivynote.app|u2"

    init() {
        let name = "ivy.test.language.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    func settings(_ tags: [String]) -> LanguageSettings {
        LanguageSettings(defaults: defaults, systemTags: tags, isGlobal: false)
    }

    @Test func systemTags() {
        #expect(Language(tag: "zh-Hans-CN") == .zh)
        #expect(Language(tag: "zh_TW") == .zh)
        #expect(Language(tag: "en-GB") == .en)
        #expect(Language(tag: "ja-JP") == nil)
        #expect(Language(tag: "") == nil)
        #expect(Language.fromSystem(["ja-JP", "zh-Hans-CN", "en-US"]) == .zh)
        #expect(Language.fromSystem(["en-US", "zh-Hans-CN"]) == .en)
        #expect(Language.fromSystem(["fr-FR"]) == .en)
        #expect(Language.fromSystem([]) == .en)
    }

    @Test func followsTheSystemUntilChosen() {
        let s = settings(["en-US"])
        #expect(s.current == .en)
        #expect(s.choice == .system)
        s.systemChanged(["zh-Hans-CN"])
        #expect(s.current == .zh)
    }

    @Test func aManualChoiceIsRemembered() {
        settings(["en-US"]).choose(.fixed(.zh))
        let again = settings(["en-US"])
        #expect(again.current == .zh)
        #expect(again.choice == .fixed(.zh))
        again.choose(.system)
        #expect(settings(["en-US"]).current == .en)
    }

    @Test func theAccountsLanguageComesFirst() {
        let s = settings(["zh-Hans-CN"])
        s.choose(.fixed(.zh))
        s.accountOpened(alice, serverLanguage: "en")
        #expect(s.current == .en)
        #expect(s.choice == .fixed(.en))
        s.accountClosed(alice)
        #expect(s.current == .zh)
        // No language on the account (""): this device's choice.
        s.accountOpened(bob, serverLanguage: "")
        #expect(s.current == .zh)
        // A tag this app does not speak counts as none.
        s.accountClosed(bob)
        s.accountOpened(bob, serverLanguage: "fr")
        #expect(s.current == .zh)
    }

    @Test func choosingWhileSignedInSetsTheAccountToo() {
        var sent: [String] = []
        let s = settings(["zh-Hans-CN"])
        s.onAccountChoice = { key, tag in sent.append("\(key)=\(tag)") }
        s.accountOpened(alice, serverLanguage: "")
        s.choose(.fixed(.en))
        #expect(sent == ["\(alice)=en"])
        #expect(s.current == .en)
        // Not sent yet (offline): it wins over the server's older value.
        #expect(s.pendingTag(alice) == "en")
        s.accountOpened(alice, serverLanguage: "zh")
        #expect(s.current == .en)
        s.pushed(alice, tag: "en")
        #expect(s.pendingTag(alice) == nil)
        // Following the system clears the account's language.
        s.choose(.system)
        #expect(sent.last == "\(alice)=")
        #expect(s.current == .zh)
        s.accountClosed(alice)
        #expect(s.deviceChoice == .system)
    }

    @Test func aPushedChangeDoesNotClearANewerOne() {
        let s = settings(["zh-Hans-CN"])
        s.accountOpened(alice, serverLanguage: "")
        s.choose(.fixed(.en))
        s.choose(.fixed(.zh))
        s.pushed(alice, tag: "en")
        #expect(s.pendingTag(alice) == "zh")
    }

    @Test func englishCounts() {
        #expect(EnStrings().pending(1) == "1 change to sync")
        #expect(EnStrings().pending(2) == "2 changes to sync")
        #expect(ZhStrings().pending(2) == "2 条待同步")
        #expect(EnStrings().tagColor("") == "Automatic")
    }
}
