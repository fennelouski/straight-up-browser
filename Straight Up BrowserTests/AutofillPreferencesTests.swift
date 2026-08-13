import Foundation
import Testing
@testable import Browser

struct AutofillPreferencesTests {
    /// A throwaway defaults suite per test, so nothing leaks between them or into
    /// the developer's own preferences.
    private func scratch() -> (AutofillPreferences, UserDefaults) {
        let name = "autofill-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (AutofillPreferences(defaults: defaults), defaults)
    }

    private let page = URL(string: "https://example.com/signup")!

    // MARK: Persistence

    @Test func settingsRoundTripThroughDefaults() {
        let (preferences, defaults) = scratch()
        let id = UUID()

        preferences.isEnabled = false
        preferences.allowInIncognito = true
        preferences.activePerson = .manual(id)
        preferences.setMyCardIncluded(true)
        #expect(preferences.addContact(identifier: "contact-a"))
        preferences.setCategory(.phone, enabled: false)
        preferences.setHost("Example.com", enabled: false)

        let reloaded = AutofillPreferences(defaults: defaults)
        #expect(reloaded.isEnabled == false)
        #expect(reloaded.allowInIncognito == true)
        #expect(reloaded.activePerson == .manual(id))
        #expect(reloaded.includesMyCard)
        #expect(reloaded.contactIdentifiers == ["contact-a"])
        #expect(reloaded.allows(.phone) == false)
        #expect(reloaded.allows(host: "example.com") == false)
    }

    @Test func autofillIsOnByDefaultButOffOnceTurnedOff() {
        let (preferences, defaults) = scratch()
        // Never set: on. `bool(forKey:)` alone would report false here.
        #expect(preferences.isEnabled)

        preferences.isEnabled = false
        #expect(AutofillPreferences(defaults: defaults).isEnabled == false)
    }

    @Test func persistedKeysAreExactlyWhatTheStoreWrites() {
        let (preferences, defaults) = scratch()
        preferences.isEnabled = false
        preferences.allowInIncognito = true
        preferences.activePerson = .manual(UUID())
        preferences.setMyCardIncluded(true)
        #expect(preferences.addContact(identifier: "contact-a"))
        preferences.setCategory(.name, enabled: false)
        preferences.setHost("example.com", enabled: false)

        let written = Set(defaults.dictionaryRepresentation().keys)
            .filter { $0.hasPrefix("autofill") }
        #expect(written == AutofillPreferences.Key.all)
    }

    @Test func resetClearsEverything() {
        let (preferences, defaults) = scratch()
        preferences.isEnabled = false
        preferences.allowInIncognito = true
        preferences.activePerson = .manual(UUID())
        preferences.setMyCardIncluded(true)
        #expect(preferences.addContact(identifier: "contact-a"))
        preferences.setCategory(.address, enabled: false)
        preferences.setHost("example.com", enabled: false)

        preferences.resetAll()

        #expect(preferences.isEnabled)
        #expect(preferences.allowInIncognito == false)
        #expect(preferences.activePerson == nil)
        #expect(preferences.includesMyCard == false)
        #expect(preferences.contactIdentifiers.isEmpty)
        #expect(preferences.disabledCategories.isEmpty)
        #expect(preferences.disabledHosts.isEmpty)
        #expect(AutofillPreferences(defaults: defaults).disabledHosts.isEmpty)
    }

    // MARK: Categories

    @Test func everyCategoryStartsEnabled() {
        let (preferences, _) = scratch()
        #expect(AutofillCategory.allCases.allSatisfy(preferences.allows))
    }

    @Test func disablingACategorySuppressesEveryFieldInIt() {
        let (preferences, _) = scratch()
        preferences.setCategory(.address, enabled: false)

        for field in AutofillField.allCases where field.category == .address {
            #expect(preferences.shouldOffer(field: field, url: page, incognito: false) == false, "\(field)")
        }
        #expect(preferences.shouldOffer(field: .email, url: page, incognito: false))
    }

    // MARK: Hosts

    @Test func hostMatchingIgnoresCaseAndWWW() {
        let (preferences, _) = scratch()
        preferences.setHost("WWW.Example.COM", enabled: false)

        #expect(preferences.allows(host: "example.com") == false)
        #expect(preferences.allows(host: "www.example.com") == false)
        #expect(preferences.allows(host: "EXAMPLE.com") == false)
        // A different site is unaffected, and subdomains are their own site.
        #expect(preferences.allows(host: "other.com"))
        #expect(preferences.allows(host: "shop.example.com"))
        #expect(preferences.allows(host: nil))
    }

    @Test func disabledHostListIsSortedForAStableSettingsView() {
        let (preferences, _) = scratch()
        for host in ["zeta.com", "alpha.com", "www.mid.com"] {
            preferences.setHost(host, enabled: false)
        }
        #expect(preferences.disabledHostList == ["alpha.com", "mid.com", "zeta.com"])
    }

    // MARK: Page gate

    @Test func masterSwitchSuppressesEverything() {
        let (preferences, _) = scratch()
        preferences.isEnabled = false
        #expect(preferences.shouldOffer(url: page, incognito: false) == false)
        #expect(preferences.shouldOffer(field: .email, url: page, incognito: false) == false)
    }

    @Test func incognitoIsOptIn() {
        let (preferences, _) = scratch()
        #expect(preferences.shouldOffer(url: page, incognito: true) == false)
        #expect(preferences.shouldOffer(url: page, incognito: false))

        preferences.allowInIncognito = true
        #expect(preferences.shouldOffer(url: page, incognito: true))
    }

    @Test func onlyHTTPSchemesCanSummonSuggestions() {
        let (preferences, _) = scratch()
        #expect(preferences.shouldOffer(url: URL(string: "https://example.com")!, incognito: false))
        #expect(preferences.shouldOffer(url: URL(string: "http://example.com")!, incognito: false))

        // A local page must not be able to ask for the user's name and address.
        for blocked in ["file:///Users/nathan/evil.html", "about:blank", "data:text/html,<form>",
                        "javascript:void(0)", "sub://settings"] {
            #expect(
                preferences.shouldOffer(url: URL(string: blocked)!, incognito: false) == false,
                "\(blocked)"
            )
        }
        #expect(preferences.shouldOffer(url: nil, incognito: false) == false)
    }

    @Test func disabledHostBlocksThePageGate() {
        let (preferences, _) = scratch()
        preferences.setHost("example.com", enabled: false)
        #expect(preferences.shouldOffer(url: page, incognito: false) == false)
        #expect(preferences.shouldOffer(url: URL(string: "https://other.com/")!, incognito: false))
    }
}
