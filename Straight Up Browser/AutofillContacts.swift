//
//  AutofillContacts.swift
//  Straight Up Browser
//
//  Contacts-backed autofill people. This file keeps only opaque contact IDs in
//  Browser preferences; names, addresses, and other values are read from
//  Contacts immediately before they are shown or filled.
//

#if os(macOS)
import AppKit
import Combine
@preconcurrency import Contacts
@preconcurrency import ContactsUI
import SwiftUI

nonisolated struct AutofillResolvedPerson: Identifiable, Equatable, Sendable {
    let reference: AutofillPersonReference
    let resolvedReference: AutofillPersonReference
    let contactIdentifier: String?
    let name: String
    let values: [AutofillField: String]

    var id: String { reference.storageValue }
}

/// The long-lived settings/menu roster deliberately carries no contact values.
nonisolated struct AutofillContactRosterPerson: Identifiable, Equatable, Sendable {
    let reference: AutofillPersonReference
    let resolvedReference: AutofillPersonReference
    let contactIdentifier: String?
    let name: String

    var id: String { reference.storageValue }
}

nonisolated struct AutofillContactValues: Equatable, Sendable {
    let givenName: String
    let familyName: String
    let email: String
    let phone: String
    let organization: String
    let addressLine1: String
    let addressLine2: String
    let city: String
    let state: String
    let postalCode: String
    let country: String

    var name: String {
        let fullName = AutofillProfile.joined(givenName, familyName)
        if !fullName.isEmpty { return fullName }
        return organization.isEmpty ? String(localized: "Contact") : organization
    }

    func values() -> [AutofillField: String] {
        [
            .givenName: givenName,
            .familyName: familyName,
            .fullName: AutofillProfile.joined(givenName, familyName),
            .email: email,
            .phone: phone,
            .organization: organization,
            .addressLine1: addressLine1,
            .addressLine2: addressLine2,
            .city: city,
            .state: state,
            .postalCode: postalCode,
            .country: country,
        ]
    }
}

/// Resolves only the fields Browser already knows how to fill. The first value
/// on a Contacts card wins, matching Contacts' own ordering without creating a
/// second, browser-specific address-book preference.
nonisolated enum AutofillContactStore {
    static func authorizationStatus() -> CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    @MainActor
    static func requestAccess() async -> Bool {
        guard authorizationStatus() == .notDetermined else {
            return isAuthorized(authorizationStatus())
        }
        return (try? await CNContactStore().requestAccess(for: .contacts)) == true
    }

    static func resolve(_ reference: AutofillPersonReference) async -> AutofillResolvedPerson? {
        guard isAuthorized(authorizationStatus()) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let keysToFetch: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactPostalAddressesKey as CNKeyDescriptor,
            ]
            let contact: CNContact?
            switch reference {
            case .me:
                contact = try? store.unifiedMeContactWithKeys(toFetch: keysToFetch)
            case .contact(let identifier):
                contact = try? store.unifiedContact(withIdentifier: identifier, keysToFetch: keysToFetch)
            case .manual:
                contact = nil
            }
            guard let contact else { return nil }
            let resolvedReference: AutofillPersonReference = switch reference {
            case .me: .me
            case .contact: .contact(contact.identifier)
            case .manual: reference
            }
            let values = contactValues(contact)
            return AutofillResolvedPerson(
                reference: reference,
                resolvedReference: resolvedReference,
                contactIdentifier: contact.identifier,
                name: values.name,
                values: values.values()
            )
        }.value
    }

    static func resolve(_ references: [AutofillPersonReference]) async -> [AutofillResolvedPerson] {
        var people: [AutofillResolvedPerson] = []
        for reference in references {
            if let person = await resolve(reference) {
                people.append(person)
            }
        }
        return people
    }

    static func resolveRoster(_ references: [AutofillPersonReference]) async -> [AutofillContactRosterPerson] {
        var people: [AutofillContactRosterPerson] = []
        for reference in references {
            if let person = await resolveRoster(reference) {
                people.append(person)
            }
        }
        return people
    }

    private static func resolveRoster(_ reference: AutofillPersonReference) async -> AutofillContactRosterPerson? {
        guard isAuthorized(authorizationStatus()) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let keysToFetch: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
            ]
            let contact: CNContact?
            switch reference {
            case .me:
                contact = try? store.unifiedMeContactWithKeys(toFetch: keysToFetch)
            case .contact(let identifier):
                contact = try? store.unifiedContact(withIdentifier: identifier, keysToFetch: keysToFetch)
            case .manual:
                contact = nil
            }
            guard let contact else { return nil }
            let resolvedReference: AutofillPersonReference = switch reference {
            case .me: .me
            case .contact: .contact(contact.identifier)
            case .manual: reference
            }
            let fullName = AutofillProfile.joined(contact.givenName, contact.familyName)
            let name = fullName.isEmpty
                ? (contact.organizationName.isEmpty ? String(localized: "Contact") : contact.organizationName)
                : fullName
            return AutofillContactRosterPerson(
                reference: reference,
                resolvedReference: resolvedReference,
                contactIdentifier: contact.identifier,
                name: name
            )
        }.value
    }

    static func isAuthorized(_ status: CNAuthorizationStatus) -> Bool {
        status == .authorized
    }

    private static func contactValues(_ contact: CNContact) -> AutofillContactValues {
        let address = contact.postalAddresses.first?.value
        let lines = addressLines(street: address?.street ?? "")
        return AutofillContactValues(
            givenName: contact.givenName,
            familyName: contact.familyName,
            email: contact.emailAddresses.first?.value as String? ?? "",
            phone: contact.phoneNumbers.first?.value.stringValue ?? "",
            organization: contact.organizationName,
            addressLine1: lines.0,
            addressLine2: lines.1,
            city: address?.city ?? "",
            state: address?.state ?? "",
            postalCode: address?.postalCode ?? "",
            country: address?.country ?? ""
        )
    }

    static func addressLines(street: String) -> (String, String) {
        let lines = street.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (lines.first ?? "", lines.dropFirst().joined(separator: ", "))
    }
}

@MainActor
final class AutofillContactsRoster: ObservableObject {
    static let shared = AutofillContactsRoster()

    @Published private(set) var people: [AutofillContactRosterPerson] = []
    private var observer: NSObjectProtocol?
    private var refreshToken = UUID()

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh(preferences: AutofillPreferences = .shared) {
        let references = preferences.contactPeople
        let token = UUID()
        refreshToken = token
        Task { [weak self] in
            let people = await AutofillContactStore.resolveRoster(references)
            guard let self, self.refreshToken == token else { return }
            for person in people {
                if case .contact(let old) = person.reference,
                   case .contact(let resolved) = person.resolvedReference {
                    preferences.replaceContact(identifier: old, with: resolved)
                }
            }
            let myCardIDs = Set(people.compactMap { person in
                person.reference == .me ? person.contactIdentifier : nil
            })
            for identifier in myCardIDs {
                if preferences.activePerson == .contact(identifier) {
                    preferences.activePerson = .me
                }
                preferences.removeContact(identifier: identifier)
            }
            let selected = Set(preferences.contactPeople)
            var seen = Set<AutofillPersonReference>()
            self.people = people.compactMap { person in
                let normalized = person.reference == person.resolvedReference
                    ? person
                    : AutofillContactRosterPerson(
                        reference: person.resolvedReference,
                        resolvedReference: person.resolvedReference,
                        contactIdentifier: person.contactIdentifier,
                        name: person.name
                    )
                return selected.contains(normalized.reference) && seen.insert(normalized.reference).inserted
                    ? normalized : nil
            }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// A retained macOS Contacts popover. The platform picker selects one person;
/// the settings roster controls the compact multi-person list and deduplicates.
struct AutofillContactPickerButton: NSViewRepresentable {
    let title: String
    let onSelection: (String) -> Void
    let onPermissionDenied: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.choose))
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, CNContactPickerDelegate {
        var parent: AutofillContactPickerButton
        private let picker = CNContactPicker()

        init(_ parent: AutofillContactPickerButton) {
            self.parent = parent
            super.init()
            picker.delegate = self
            picker.displayedKeys = []
        }

        @objc func choose(_ sender: NSButton) {
            Task { @MainActor in
                guard await AutofillContactStore.requestAccess() else {
                    parent.onPermissionDenied()
                    return
                }
                picker.showRelative(to: sender.bounds, of: sender, preferredEdge: .maxY)
            }
        }

        func contactPicker(_ picker: CNContactPicker, didSelect contact: CNContact) {
            parent.onSelection(contact.identifier)
        }
    }
}
#endif
