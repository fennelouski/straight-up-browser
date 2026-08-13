import Foundation
import Testing
@testable import Browser

struct AutofillContactsTests {
    private func scratch() -> (AutofillPreferences, UserDefaults) {
        let name = "autofill-contacts-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (AutofillPreferences(defaults: defaults), defaults)
    }

    @Test func personReferencesRoundTripWithoutAContactRecord() {
        let id = UUID()
        let references: [AutofillPersonReference] = [.manual(id), .me, .contact("opaque-contact-id")]

        for reference in references {
            #expect(AutofillPersonReference(storageValue: reference.storageValue) == reference)
        }
    }

    @Test func legacyManualDefaultMigratesToASourceQualifiedReference() {
        let (_, defaults) = scratch()
        let id = UUID()
        defaults.set(id.uuidString, forKey: AutofillPreferences.Key.legacyActiveProfile)

        let preferences = AutofillPreferences(defaults: defaults)

        #expect(preferences.activePerson == .manual(id))
        #expect(defaults.string(forKey: AutofillPreferences.Key.activePerson) == "manual:\(id.uuidString)")
        preferences.resetAll()
        #expect(defaults.object(forKey: AutofillPreferences.Key.legacyActiveProfile) == nil)
    }

    @Test func contactRosterDeduplicatesAndHasAHardLimit() {
        let (preferences, _) = scratch()

        for index in 0..<AutofillPreferences.maximumContactPeople {
            #expect(preferences.addContact(identifier: "contact-\(index)"))
        }
        #expect(preferences.addContact(identifier: "contact-0") == false)
        #expect(preferences.addContact(identifier: "contact-overflow") == false)
        #expect(preferences.contactIdentifiers.count == AutofillPreferences.maximumContactPeople)
    }

    @Test func removingMyCardClearsItsSelectionButNotContactReferences() {
        let (preferences, _) = scratch()
        preferences.setMyCardIncluded(true)
        preferences.activePerson = .me
        #expect(preferences.addContact(identifier: "opaque-contact-id"))

        preferences.setMyCardIncluded(false)

        #expect(preferences.activePerson == nil)
        #expect(preferences.contactIdentifiers == ["opaque-contact-id"])
    }

    @Test func addressMappingPreservesSeparateAddressLines() {
        let lines = AutofillContactStore.addressLines(street: "10 Example Street\nSuite 4")

        #expect(lines.0 == "10 Example Street")
        #expect(lines.1 == "Suite 4")
    }

    @Test func rosterEntriesCarryNoFillValues() {
        let person = AutofillContactRosterPerson(
            reference: .contact("opaque-contact-id"),
            resolvedReference: .contact("opaque-contact-id"),
            contactIdentifier: "opaque-contact-id",
            name: "Contact"
        )

        #expect(!Mirror(reflecting: person).children.contains { $0.label == "values" })
    }

    @Test func organizationNamesAreUsefulWhenAContactHasNoPersonalName() {
        let values = AutofillContactValues(
            givenName: "",
            familyName: "",
            email: "",
            phone: "",
            organization: "Example Co.",
            addressLine1: "",
            addressLine2: "",
            city: "",
            state: "",
            postalCode: "",
            country: ""
        )

        #expect(values.name == "Example Co.")
    }
}
