import Foundation
import Testing
@testable import Browser

/// Builds a descriptor with everything defaulted to "a plain visible text input"
/// so each test only states the thing it's actually about.
private func field(
    tag: String = "input",
    type: String = "text",
    autocomplete: String = "",
    name: String = "",
    elementID: String = "",
    placeholder: String = "",
    label: String = "",
    ariaLabel: String = "",
    isVisible: Bool = true,
    isEditable: Bool = true,
    isEmpty: Bool = true
) -> AutofillFieldDescriptor {
    AutofillFieldDescriptor(
        tag: tag, type: type, autocomplete: autocomplete, name: name,
        elementID: elementID, placeholder: placeholder, label: label,
        ariaLabel: ariaLabel, isVisible: isVisible, isEditable: isEditable, isEmpty: isEmpty
    )
}

struct AutofillClassifierTests {

    // MARK: autocomplete tokens

    @Test func everyFieldRoundTripsThroughItsCanonicalToken() {
        // A new AutofillField case can't be added without a token mapping.
        for expected in AutofillField.allCases {
            let descriptor = field(autocomplete: expected.canonicalToken)
            #expect(
                AutofillFieldClassifier.classify(descriptor) == expected,
                "\(expected.canonicalToken) should classify as \(expected)"
            )
        }
    }

    @Test func autocompleteBeatsConflictingAttributes() {
        // The site said given-name; the name attribute says otherwise. Standard wins.
        let descriptor = field(autocomplete: "given-name", name: "lastname", placeholder: "Email")
        #expect(AutofillFieldClassifier.classify(descriptor) == .givenName)
    }

    @Test func sectionAndModifierTokensAreStripped() {
        #expect(AutofillFieldClassifier.classify(field(autocomplete: "shipping given-name")) == .givenName)
        #expect(AutofillFieldClassifier.classify(field(autocomplete: "section-a billing address-level2")) == .city)
        #expect(AutofillFieldClassifier.classify(field(autocomplete: "billing home tel")) == .phone)
        #expect(AutofillFieldClassifier.classify(field(autocomplete: "SHIPPING Postal-Code")) == .postalCode)
    }

    @Test func paymentTokensAreNeverClassified() {
        for token in ["cc-number", "cc-name", "cc-exp", "cc-exp-month", "cc-csc", "cc-type"] {
            #expect(
                AutofillFieldClassifier.classify(field(autocomplete: token)) == nil,
                "\(token) must never be filled"
            )
        }
    }

    @Test func credentialTokensAreNeverClassified() {
        for token in ["new-password", "current-password", "one-time-code", "username"] {
            #expect(AutofillFieldClassifier.classify(field(autocomplete: token)) == nil)
        }
    }

    @Test func refusedTokensDoNotFallThroughToKeywords() {
        // "cc-name" contains "name" and the element is called "name" — if a refused
        // token leaked into the keyword table this would come back as .fullName.
        let card = field(autocomplete: "cc-name", name: "name", label: "Name on card")
        #expect(AutofillFieldClassifier.classify(card) == nil)

        // A middle-name field must not be filled with a full name.
        let middle = field(autocomplete: "additional-name", name: "middle_name")
        #expect(AutofillFieldClassifier.classify(middle) == nil)
    }

    @Test func unrecognizedAutocompleteFallsThroughToKeywords() {
        #expect(AutofillFieldClassifier.classify(field(autocomplete: "off", name: "email")) == .email)
        #expect(AutofillFieldClassifier.classify(field(autocomplete: "on", name: "city")) == .city)
        #expect(AutofillFieldClassifier.classify(field(autocomplete: "gibberish", name: "zip")) == .postalCode)
    }

    // MARK: The control allowlist

    @Test func passwordFieldsAreNeverClassified() {
        // Even when the page insists it's an email field.
        let descriptor = field(type: "password", autocomplete: "email", name: "email")
        #expect(AutofillFieldClassifier.classify(descriptor) == nil)
    }

    @Test func nonTextInputTypesAreRejected() {
        for type in ["hidden", "file", "checkbox", "radio", "submit", "button",
                     "range", "color", "date", "number", "url", "password"] {
            #expect(
                AutofillFieldClassifier.classify(field(type: type, autocomplete: "email")) == nil,
                "input type=\(type) must not be fillable"
            )
        }
    }

    @Test func selectAndOtherTagsAreRejected() {
        #expect(AutofillFieldClassifier.classify(field(tag: "select", autocomplete: "country-name")) == nil)
        #expect(AutofillFieldClassifier.classify(field(tag: "div", autocomplete: "email")) == nil)
    }

    @Test func textareaAndBareTypeAreAccepted() {
        #expect(AutofillFieldClassifier.classify(field(tag: "textarea", autocomplete: "street-address")) == .addressLine1)
        #expect(AutofillFieldClassifier.classify(field(type: "", autocomplete: "email")) == .email)
        #expect(AutofillFieldClassifier.classify(field(type: "search", name: "city")) == .city)
    }

    @Test func invisibleOrUneditableFieldsAreRejected() {
        #expect(AutofillFieldClassifier.classify(field(autocomplete: "email", isVisible: false)) == nil)
        #expect(AutofillFieldClassifier.classify(field(autocomplete: "email", isEditable: false)) == nil)
    }

    // MARK: Input type as a signal

    @Test func inputTypeClassifiesWhenAutocompleteIsSilent() {
        #expect(AutofillFieldClassifier.classify(field(type: "email", name: "q")) == .email)
        #expect(AutofillFieldClassifier.classify(field(type: "tel", name: "q")) == .phone)
    }

    // MARK: Keyword table

    @Test func heuristicOrderResolvesKnownCollisions() {
        // Each of these is a real trap that a reordering would reintroduce.
        #expect(AutofillFieldClassifier.classify(field(name: "address_zip")) == .postalCode)
        #expect(AutofillFieldClassifier.classify(field(name: "address_city")) == .city)
        #expect(AutofillFieldClassifier.classify(field(name: "address_state")) == .state)
        #expect(AutofillFieldClassifier.classify(field(placeholder: "Email address")) == .email)
        #expect(AutofillFieldClassifier.classify(field(label: "Address Line 2")) == .addressLine2)
        #expect(AutofillFieldClassifier.classify(field(label: "Address")) == .addressLine1)
        #expect(AutofillFieldClassifier.classify(field(label: "Company name")) == .organization)
        #expect(AutofillFieldClassifier.classify(field(label: "First Name")) == .givenName)
        #expect(AutofillFieldClassifier.classify(field(label: "Last Name")) == .familyName)
        #expect(AutofillFieldClassifier.classify(field(label: "Full Name")) == .fullName)
        #expect(AutofillFieldClassifier.classify(field(name: "country", placeholder: "United States")) == .country)
    }

    @Test func heuristicTableOrderIsPinned() {
        // The order IS the behaviour — assert it directly so a reshuffle fails
        // loudly rather than silently changing what forms fill correctly.
        #expect(AutofillFieldClassifier.heuristics.map(\.0) == [
            .email, .phone, .postalCode, .city, .country, .state,
            .addressLine2, .addressLine1, .organization,
            .givenName, .familyName, .fullName,
        ])
    }

    @Test func keywordsMatchTokenPrefixesNotBareSubstrings() {
        // Prefix matching is what keeps these out.
        #expect(AutofillFieldClassifier.classify(field(label: "Hotel name")) == .fullName)  // not .phone via "tel"
        #expect(AutofillFieldClassifier.classify(field(name: "username")) == nil)           // not .fullName via "name"
        #expect(AutofillFieldClassifier.classify(field(label: "Real estate agent")) == nil) // not .state
        // …while still being forgiving about run-together names.
        #expect(AutofillFieldClassifier.classify(field(name: "zipcode")) == .postalCode)
        #expect(AutofillFieldClassifier.classify(field(name: "addressline1")) == .addressLine1)
    }

    @Test func camelCaseAndSeparatorsNormalizeToTheSameThing() {
        #expect(AutofillFieldClassifier.normalize("firstName") == "first name")
        #expect(AutofillFieldClassifier.normalize("first_name") == "first name")
        #expect(AutofillFieldClassifier.normalize("first-name") == "first name")
        #expect(AutofillFieldClassifier.normalize("  FIRST   NAME ") == "first name")
        for variant in ["firstName", "first_name", "first-name", "billing.firstName"] {
            #expect(AutofillFieldClassifier.classify(field(name: variant)) == .givenName)
        }
    }

    @Test func labelTextIsUsedWhenAttributesAreEmpty() {
        #expect(AutofillFieldClassifier.classify(field(label: "Postal code")) == .postalCode)
        #expect(AutofillFieldClassifier.classify(field(ariaLabel: "Phone number")) == .phone)
    }

    @Test func unrecognizedFieldsStayUnrecognized() {
        #expect(AutofillFieldClassifier.classify(field(name: "q", placeholder: "Search")) == nil)
        #expect(AutofillFieldClassifier.classify(field(name: "coupon", label: "Promo code")) == nil)
        #expect(AutofillFieldClassifier.classify(field()) == nil)
    }
}

struct AutofillFillPlanTests {
    private let values: [AutofillField: String] = [
        .givenName: "Nathan", .familyName: "Fennel",
        .fullName: "Nathan Fennel", .email: "nathan@example.com",
        .phone: "5551234567", .city: "Portland", .postalCode: "97201",
    ]

    private func plan(
        _ candidates: [AutofillFieldCandidate],
        allows: @escaping (AutofillCategory) -> Bool = { _ in true }
    ) -> [AutofillAssignment] {
        AutofillFieldClassifier.plan(
            candidates: candidates,
            value: { values[$0] ?? "" },
            allows: allows
        )
    }

    private func candidate(_ id: String, _ descriptor: AutofillFieldDescriptor) -> AutofillFieldCandidate {
        AutofillFieldCandidate(localID: id, descriptor: descriptor)
    }

    @Test func planFillsEveryRecognizedEmptyField() {
        let assignments = plan([
            candidate("a", field(autocomplete: "given-name")),
            candidate("b", field(autocomplete: "family-name")),
            candidate("c", field(autocomplete: "email")),
        ])
        #expect(assignments.map(\.localID) == ["a", "b", "c"])
        #expect(assignments.map(\.value) == ["Nathan", "Fennel", "nathan@example.com"])
    }

    @Test func alreadyTypedFieldsAreNeverOverwritten() {
        let assignments = plan([
            candidate("typed", field(autocomplete: "given-name", isEmpty: false)),
            candidate("blank", field(autocomplete: "family-name")),
        ])
        #expect(assignments.map(\.localID) == ["blank"])
    }

    @Test func disabledCategoriesAreSkipped() {
        let assignments = plan([
            candidate("a", field(autocomplete: "given-name")),
            candidate("b", field(autocomplete: "email")),
        ], allows: { $0 != .name })
        #expect(assignments.map(\.field) == [.email])
    }

    @Test func fieldsTheProfileHasNoValueForAreSkipped() {
        let assignments = plan([
            candidate("a", field(autocomplete: "organization")),  // not in `values`
            candidate("b", field(autocomplete: "email")),
        ])
        #expect(assignments.map(\.field) == [.email])
    }

    @Test func passwordAndPaymentFieldsNeverAppearInAPlan() {
        let assignments = plan([
            candidate("pw", field(type: "password", autocomplete: "current-password")),
            candidate("cc", field(autocomplete: "cc-number")),
            candidate("hidden", field(type: "hidden", autocomplete: "email")),
        ])
        #expect(assignments.isEmpty)
    }

    @Test func valuesAreTruncatedBeforeCrossingIntoThePage() {
        let long = String(repeating: "x", count: 5000)
        let assignments = AutofillFieldClassifier.plan(
            candidates: [candidate("a", field(autocomplete: "email"))],
            value: { _ in long },
            allows: { _ in true }
        )
        #expect(assignments.first?.value.count == AutofillFieldClassifier.maximumValueLength)
    }
}
