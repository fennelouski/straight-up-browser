import Foundation
import Testing
@testable import Browser

struct AutofillProfileTests {
    private func populated() -> AutofillProfile {
        let profile = AutofillProfile(label: "Home")
        profile.givenName = "Nathan"
        profile.familyName = "Fennel"
        profile.email = "nathan@example.com"
        profile.phone = "5551234567"
        profile.organization = "100 Apps Studio"
        profile.addressLine1 = "1 Main Street"
        profile.addressLine2 = "Apt 2"
        profile.city = "Portland"
        profile.addressState = "OR"
        profile.postalCode = "97201"
        profile.country = "United States"
        return profile
    }

    @Test func valueForCoversEveryField() {
        let profile = populated()
        let expected: [AutofillField: String] = [
            .givenName: "Nathan",
            .familyName: "Fennel",
            .fullName: "Nathan Fennel",
            .email: "nathan@example.com",
            .phone: "5551234567",
            .organization: "100 Apps Studio",
            .addressLine1: "1 Main Street",
            .addressLine2: "Apt 2",
            .city: "Portland",
            .state: "OR",
            .postalCode: "97201",
            .country: "United States",
        ]
        // allCases rather than a literal list, so a new field can't be added
        // without deciding what it maps to.
        for field in AutofillField.allCases {
            #expect(profile.value(for: field) == expected[field], "\(field)")
        }
    }

    @Test func emptyProfileYieldsNoValues() {
        let profile = AutofillProfile(label: "Blank")
        #expect(profile.isEmpty)
        #expect(AutofillField.allCases.allSatisfy { profile.value(for: $0).isEmpty })
    }

    @Test func fullNameToleratesEitherHalfMissing() {
        let profile = AutofillProfile(label: "Partial")
        profile.givenName = "Nathan"
        #expect(profile.value(for: .fullName) == "Nathan")

        profile.givenName = ""
        profile.familyName = "Fennel"
        #expect(profile.value(for: .fullName) == "Fennel")

        profile.familyName = ""
        #expect(profile.value(for: .fullName) == "")
    }

    @Test func everyFieldBelongsToACategory() {
        // Exhaustive by construction — `category` has no default arm, so this
        // fails to compile rather than fails at runtime if a case is missed.
        let grouped = Dictionary(grouping: AutofillField.allCases, by: \.category)
        #expect(Set(grouped.keys) == Set(AutofillCategory.allCases))
        #expect(grouped[.name]?.count == 3)
        #expect(grouped[.address]?.count == 6)
    }

    @Test func canonicalTokensAreUnique() {
        let tokens = AutofillField.allCases.map(\.canonicalToken)
        #expect(Set(tokens).count == tokens.count)
    }

    @Test func displayNameFallsBackThroughTheLikelyFields() {
        let labelled = populated()
        #expect(labelled.displayName == "Home")

        labelled.label = ""
        #expect(labelled.displayName == "Nathan Fennel")

        labelled.givenName = ""
        labelled.familyName = ""
        #expect(labelled.displayName == "nathan@example.com")

        labelled.email = ""
        #expect(labelled.displayName == String(localized: "Untitled profile"))
    }

    @Test func autofillProfilesAreDisclosedAsSyncedData() {
        // The model is CloudKit-backed, so the user has to be able to see that.
        #expect(TabSync.syncedDataCategories.contains(.autofillProfiles))
        #expect(TabSync.cloudBackedModelTypeNames.contains("AutofillProfile"))
        #expect(SyncedDataCategory.autofillProfiles.label.contains("no cards or passwords"))
    }
}
