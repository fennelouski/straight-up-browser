//
//  AutofillFieldClassifier.swift
//  Straight Up Browser
//
//  Decides what a form field is asking for. Pure Swift over a Codable descriptor
//  that mirrors the `fieldHints` payload the page runtime collects, so every rule
//  here is testable from a struct literal with no WKWebView.
//
//  Classification lives in Swift rather than JavaScript on purpose: the repo has
//  no .js files, so page scripts get no type checking, no warning gate, and no
//  test harness. A keyword table is the most churn-prone part of this feature, so
//  it belongs where verify.sh can see it.
//
//  Safety invariants enforced here (do not "simplify" these away):
//    * Fields are matched by ALLOWLIST, so password/hidden/file are unreachable
//      by construction. A redundant explicit password guard backs that up.
//    * Payment and credential autocomplete tokens are rejected outright rather
//      than falling through to the keyword table, which could otherwise match a
//      cc-name field as a person's name.
//    * Nothing in this file is reachable from AgentToolCatalog. Profile values
//      must never become an agent tool or enter agent context.
//

import Foundation

/// The DOM facts the page runtime reports for one form control. Mirrors the JS
/// `fieldHints` object field for field.
nonisolated struct AutofillFieldDescriptor: Codable, Equatable, Hashable, Sendable {
    var tag: String = ""
    var type: String = ""
    var autocomplete: String = ""
    var name: String = ""
    var elementID: String = ""
    var placeholder: String = ""
    var label: String = ""
    var ariaLabel: String = ""
    var isVisible: Bool = true
    var isEditable: Bool = true
    /// Whether the control currently holds no value. The classifier ignores this;
    /// the fill planner uses it so typing is never overwritten.
    var isEmpty: Bool = true
}

/// One field the browser intends to write, resolved against a profile.
nonisolated struct AutofillAssignment: Equatable, Sendable {
    let localID: String
    let field: AutofillField
    let value: String
}

/// A candidate control from a page snapshot, paired with its stable element id.
nonisolated struct AutofillFieldCandidate: Equatable, Sendable {
    let localID: String
    let descriptor: AutofillFieldDescriptor
}

nonisolated enum AutofillFieldClassifier {
    /// Longest value we will ever hand to a page. Bounds what a corrupted or
    /// pasted-into profile can inject into a form.
    static let maximumValueLength = 256

    // MARK: Classification

    /// What this control is asking for, or nil if we don't recognize it or
    /// shouldn't touch it.
    static func classify(_ descriptor: AutofillFieldDescriptor) -> AutofillField? {
        guard descriptor.isVisible, descriptor.isEditable else { return nil }
        guard isFillableControl(descriptor) else { return nil }

        switch autocompleteToken(descriptor.autocomplete) {
        case .matched(let field): return field
        case .rejected: return nil
        case .unknown: break
        }

        // The input type is a weaker but still authoritative signal.
        if descriptor.type == "email" { return .email }
        if descriptor.type == "tel" { return .phone }

        return heuristicMatch(descriptor)
    }

    /// Allowlist of controls we are willing to write into. Everything else —
    /// password, hidden, file, checkbox, radio, submit, and <select> — is out.
    private static func isFillableControl(_ descriptor: AutofillFieldDescriptor) -> Bool {
        // Redundant with the type allowlist below, kept explicit and tested so a
        // future edit to that list can't quietly re-admit password fields.
        guard descriptor.type != "password" else { return false }

        switch descriptor.tag {
        case "textarea":
            return true
        case "input":
            // An absent type attribute means "text".
            return ["", "text", "email", "tel", "search"].contains(descriptor.type)
        default:
            // ponytail: <select> is out in v1 — country pickers need select_option
            // plus option-text matching. Add that when a real checkout needs it.
            return false
        }
    }

    // MARK: autocomplete tokens

    private enum TokenOutcome {
        case matched(AutofillField)
        /// A standard token we deliberately do not fill. Stops here rather than
        /// falling through, so a cc-name field never reaches the keyword table.
        case rejected
        case unknown
    }

    /// Per the HTML autofill grammar, the detail token is the last one left after
    /// stripping the optional section, address-type, and phone-type prefixes and
    /// the trailing webauthn.
    private static let modifierTokens: Set<String> = [
        "shipping", "billing", "home", "work", "mobile", "fax", "pager", "webauthn",
    ]

    private static let supportedTokens: [String: AutofillField] = [
        "given-name": .givenName,
        "family-name": .familyName,
        "name": .fullName,
        "email": .email,
        "tel": .phone,
        "tel-national": .phone,
        "tel-local": .phone,
        "organization": .organization,
        "street-address": .addressLine1,
        "address-line1": .addressLine1,
        "address-line2": .addressLine2,
        "address-level2": .city,
        "address-level1": .state,
        "postal-code": .postalCode,
        "country-name": .country,
        // ponytail: `country` is specified as the ISO code while we store a human
        // name. Sites overwhelmingly use it on a text input expecting the name, so
        // we fill it. Split them if an ISO-code field ever shows up wrong.
        "country": .country,
    ]

    /// Standard tokens we recognize and deliberately refuse: payment, credentials,
    /// and name/address parts we don't store. Listed explicitly so they stop at
    /// the token stage instead of falling through to keyword matching.
    private static let refusedTokens: Set<String> = [
        "new-password", "current-password", "one-time-code", "username",
        "additional-name", "honorific-prefix", "honorific-suffix", "nickname",
        "organization-title",
        "tel-country-code", "tel-area-code", "tel-extension",
        "address-line3", "address-level3", "address-level4",
        "bday", "bday-day", "bday-month", "bday-year",
        "sex", "url", "photo", "impp", "language",
    ]

    private static func autocompleteToken(_ raw: String) -> TokenOutcome {
        let tokens = raw
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.hasPrefix("section-") && !modifierTokens.contains($0) }

        guard let token = tokens.last else { return .unknown }
        if token.hasPrefix("cc-") { return .rejected }
        if refusedTokens.contains(token) { return .rejected }
        if let field = supportedTokens[token] { return .matched(field) }
        // "on", "off", and anything non-standard: the site told us nothing useful.
        return .unknown
    }

    // MARK: Keyword fallback

    /// Ordered because the greedy entries have to lose. Every ordering here fixes
    /// a real collision and is pinned by a test:
    ///   * email before addressLine1  — "Email address" contains "address"
    ///   * postalCode/city/state/country before addressLine1 — name="address_zip"
    ///   * country before state       — placeholder "United States" contains "state"
    ///   * addressLine2 before addressLine1 — "Address line 2" contains "address"
    ///   * organization/givenName/familyName before fullName — "Company name",
    ///     "First name", and "Last name" all contain "name"
    ///
    /// ponytail: English only. Carry document.documentElement.lang in the
    /// descriptor and key per-language tables off it if that ever matters.
    static let heuristics: [(AutofillField, [String])] = [
        (.email, ["email", "e mail"]),
        (.phone, ["phone", "mobile", "cell", "tel"]),
        (.postalCode, ["postal", "postcode", "zip", "pincode", "pin code"]),
        (.city, ["city", "town", "locality", "suburb"]),
        (.country, ["country", "nation"]),
        (.state, ["state", "province", "region", "county", "prefecture"]),
        (.addressLine2, ["address line 2", "addressline2", "address 2", "address2",
                         "apt", "apartment", "suite", "line 2", "line2"]),
        (.addressLine1, ["street address", "address line 1", "street", "address", "addr"]),
        (.organization, ["company", "organization", "organisation", "employer", "business"]),
        (.givenName, ["first name", "firstname", "given name", "givenname", "forename", "fname"]),
        (.familyName, ["last name", "lastname", "family name", "familyname", "surname", "lname"]),
        (.fullName, ["full name", "fullname", "your name", "name"]),
    ]

    private static func heuristicMatch(_ descriptor: AutofillFieldDescriptor) -> AutofillField? {
        let haystack = normalize(
            [descriptor.name, descriptor.elementID, descriptor.placeholder,
             descriptor.label, descriptor.ariaLabel].joined(separator: " ")
        )
        guard !haystack.isEmpty else { return nil }
        let tokens = haystack.split(separator: " ")
        for (field, keywords) in heuristics
        where keywords.contains(where: { matches($0, haystack: haystack, tokens: tokens) }) {
            return field
        }
        return nil
    }

    /// Single-word keywords match a token PREFIX, not a bare substring. That is
    /// what keeps "Hotel name" out of `phone` ("tel"), "username" out of
    /// `fullName` ("name"), and "real estate" out of `state`, while still letting
    /// "zip" catch "zipcode" and "address" catch "addressline1". Multi-word
    /// keywords are specific enough to match the whole haystack directly.
    private static func matches(_ keyword: String, haystack: String, tokens: [Substring]) -> Bool {
        if keyword.contains(" ") { return haystack.contains(keyword) }
        return tokens.contains { $0.hasPrefix(keyword) }
    }

    /// Lowercase, punctuation and camelCase boundaries to spaces, runs collapsed.
    /// "firstName" and "first_name" both become "first name", so one keyword
    /// covers every casing convention a form author might use.
    static func normalize(_ raw: String) -> String {
        var spaced = ""
        var previous: Character?
        for character in raw {
            if character.isUppercase, let previous, previous.isLowercase || previous.isNumber {
                spaced.append(" ")
            }
            spaced.append(character)
            previous = character
        }
        let separated = spaced.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(separated).split(separator: " ").joined(separator: " ")
    }

    // MARK: Fill planning

    /// The full set of writes for one pick: every recognized, still-empty field
    /// the profile and the user's category choices allow.
    ///
    /// Empty-only by design — a value the user already typed is never overwritten.
    ///
    /// Takes closures rather than an `AutofillProfile` so this whole layer stays
    /// free of SwiftData: the caller passes `profile.value(for:)` from the main
    /// actor, and tests pass a dictionary lookup with no model container.
    static func plan(
        candidates: [AutofillFieldCandidate],
        value valueFor: (AutofillField) -> String,
        allows: (AutofillCategory) -> Bool
    ) -> [AutofillAssignment] {
        candidates.compactMap { candidate in
            guard candidate.descriptor.isEmpty,
                  let field = classify(candidate.descriptor),
                  allows(field.category) else { return nil }
            let value = valueFor(field)
            guard !value.isEmpty else { return nil }
            return AutofillAssignment(
                localID: candidate.localID,
                field: field,
                value: String(value.prefix(maximumValueLength))
            )
        }
    }
}
