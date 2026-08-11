//
//  AutofillProfile.swift
//  Straight Up Browser
//
//  A saved set of personal details the browser can offer when you focus a form
//  field. Identity, contact, and postal address only — deliberately NOT payment
//  cards and NOT passwords. Passwords keep the documented route in
//  WebExtension.swift: bring your own extension. Nothing here is ever exposed to
//  the agent (see AutofillFieldClassifier for the full invariant list).
//
//  Flat rather than profile + field records: the field set is closed and
//  product-decided, and a CloudKit to-many relationship merges per child record,
//  so two devices editing one address can produce duplicates or orphans. One
//  record per profile syncs atomically. Adding a field later is one defaulted
//  property, which lightweight migration handles on its own.
//

import Foundation
import SwiftData

/// One recognized kind of form field. Cases map 1:1 onto the HTML autofill
/// detail tokens in `canonicalToken`, which is the primary classification
/// signal — see `AutofillFieldClassifier`.
nonisolated enum AutofillField: String, CaseIterable, Codable, Sendable {
    case givenName
    case familyName
    case fullName
    case email
    case phone
    case organization
    case addressLine1
    case addressLine2
    case city
    case state
    case postalCode
    case country

    /// The HTML `autocomplete` detail token for this field. Round-tripped by a
    /// test, so a new case can't be added without a token mapping.
    var canonicalToken: String {
        switch self {
        case .givenName: return "given-name"
        case .familyName: return "family-name"
        case .fullName: return "name"
        case .email: return "email"
        case .phone: return "tel"
        case .organization: return "organization"
        case .addressLine1: return "address-line1"
        case .addressLine2: return "address-line2"
        case .city: return "address-level2"
        case .state: return "address-level1"
        case .postalCode: return "postal-code"
        case .country: return "country-name"
        }
    }

    var category: AutofillCategory {
        switch self {
        case .givenName, .familyName, .fullName: return .name
        case .email: return .email
        case .phone: return .phone
        case .organization: return .organization
        case .addressLine1, .addressLine2, .city, .state, .postalCode, .country: return .address
        }
    }

    var label: String {
        switch self {
        case .givenName: return String(localized: "First name")
        case .familyName: return String(localized: "Last name")
        case .fullName: return String(localized: "Full name")
        case .email: return String(localized: "Email")
        case .phone: return String(localized: "Phone")
        case .organization: return String(localized: "Organization")
        case .addressLine1: return String(localized: "Address")
        case .addressLine2: return String(localized: "Address line 2")
        case .city: return String(localized: "City")
        case .state: return String(localized: "State or province")
        case .postalCode: return String(localized: "Postal code")
        case .country: return String(localized: "Country")
        }
    }
}

/// The user-facing grouping in the autofill menu — "which information to
/// include". Toggling one off suppresses every field in it.
nonisolated enum AutofillCategory: String, CaseIterable, Codable, Sendable {
    case name
    case email
    case phone
    case organization
    case address

    var label: String {
        switch self {
        case .name: return String(localized: "Name")
        case .email: return String(localized: "Email")
        case .phone: return String(localized: "Phone")
        case .organization: return String(localized: "Organization")
        case .address: return String(localized: "Address")
        }
    }

    var systemImage: String {
        switch self {
        case .name: return "person"
        case .email: return "envelope"
        case .phone: return "phone"
        case .organization: return "building.2"
        case .address: return "mappin.and.ellipse"
        }
    }
}

@Model
final class AutofillProfile {
    // Defaults required for SwiftData+CloudKit compatibility.
    var id: UUID = UUID()
    var label: String = ""
    var createdAt: Date = Date()
    var givenName: String = ""
    var familyName: String = ""
    var email: String = ""
    var phone: String = ""
    var organization: String = ""
    var addressLine1: String = ""
    var addressLine2: String = ""
    var city: String = ""
    // `addressState` rather than `state` — the latter reads as view state next to
    // SwiftData's own vocabulary.
    var addressState: String = ""
    var postalCode: String = ""
    var country: String = ""

    init(label: String) {
        self.id = UUID()
        self.label = label
        self.createdAt = Date()
    }

    /// The stored value for a recognized field, or "" when this profile has
    /// nothing for it. Pure — the seam the fill planner and its tests use.
    func value(for field: AutofillField) -> String {
        switch field {
        case .givenName: return givenName
        case .familyName: return familyName
        case .fullName: return Self.joined(givenName, familyName)
        case .email: return email
        case .phone: return phone
        case .organization: return organization
        case .addressLine1: return addressLine1
        case .addressLine2: return addressLine2
        case .city: return city
        case .state: return addressState
        case .postalCode: return postalCode
        case .country: return country
        }
    }

    /// A full name from the parts, tolerating either half being blank.
    static func joined(_ given: String, _ family: String) -> String {
        [given, family]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The name shown in the suggestion list and the profile picker. Falls back
    /// through the fields most likely to be filled in.
    var displayName: String {
        if !label.isEmpty { return label }
        let name = Self.joined(givenName, familyName)
        if !name.isEmpty { return name }
        if !email.isEmpty { return email }
        return String(localized: "Untitled profile")
    }

    /// Whether this profile has anything worth offering at all.
    var isEmpty: Bool {
        AutofillField.allCases.allSatisfy { value(for: $0).isEmpty }
    }
}
