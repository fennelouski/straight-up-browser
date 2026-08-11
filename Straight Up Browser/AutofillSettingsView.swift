//
//  AutofillSettingsView.swift
//  Straight Up Browser
//
//  Manage the saved profiles autofill offers, what it's allowed to use, and
//  where it stays out of the way. The toolbar menu is the quick picker; this is
//  where the data itself lives.
//

import SwiftUI
import SwiftData

struct AutofillSettingsView: View {
    @Query(sort: \AutofillProfile.createdAt) private var profiles: [AutofillProfile]
    @Environment(\.modelContext) private var modelContext
    @Bindable private var preferences = AutofillPreferences.shared

    @State private var expandedProfileID: UUID?
    @State private var confirmingDeleteAll = false
    @State private var pendingProfileDeletion: AutofillProfile?

    private var shortcutDisplay: String {
        ShortcutStore.shared.shortcut(for: .toggleAutofill).displayString
    }

    var body: some View {
        Form {
            masterSection
            profilesSection
            categoriesSection
            exceptionsSection
            resetSection
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete all autofill data?",
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every saved profile and resets your autofill settings on this device. Profiles synced to iCloud are deleted too.")
        }
        .confirmationDialog(
            "Delete this profile?",
            isPresented: Binding(
                get: { pendingProfileDeletion != nil },
                set: { if !$0 { pendingProfileDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive) {
                if let profile = pendingProfileDeletion { delete(profile) }
                pendingProfileDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingProfileDeletion = nil }
        }
    }

    // MARK: Master switch

    private var masterSection: some View {
        Section {
            Toggle("Offer saved information when filling out forms", isOn: $preferences.isEnabled)
            Toggle("Also offer in incognito tabs", isOn: $preferences.allowInIncognito)
                .disabled(!preferences.isEnabled)
        } header: {
            SettingsLabel("Autofill", systemImage: "text.append", tint: SettingsTint.autofill)
        } footer: {
            Text("Focus a name, email, phone, or address field and Browser offers what you've saved. Nothing is ever written to a page until you pick a suggestion. Press \(shortcutDisplay) to turn autofill on and off without coming back here.\n\nIncognito is off by default so a private tab doesn't hand over your real details. Autofill never runs on local files, and never offers passwords or payment cards — passwords stay with whichever extension you've installed for them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Profiles

    private var profilesSection: some View {
        Section {
            if profiles.isEmpty {
                ContentUnavailableView {
                    Label("No profiles yet", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Add a profile to start filling forms.")
                } actions: {
                    Button("Add Profile") { addProfile() }
                }
            } else {
                if profiles.count > 1 {
                    Picker("Suggest first", selection: activeProfileBinding) {
                        ForEach(profiles) { profile in
                            Text(profile.displayName).tag(profile.id as UUID?)
                        }
                    }
                }
                ForEach(profiles) { profile in
                    profileRow(profile)
                }
                Button("Add Profile") { addProfile() }
            }
        } header: {
            SettingsLabel("Profiles", systemImage: "person.text.rectangle", tint: SettingsTint.autofill)
        } footer: {
            Text("Each profile is one set of details — home and work, say. Picking any suggestion fills every matching empty field on the page; anything you've already typed is left alone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func profileRow(_ profile: AutofillProfile) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedProfileID == profile.id },
                set: { expandedProfileID = $0 ? profile.id : nil }
            )
        ) {
            AutofillProfileEditor(profile: profile)
            Button("Delete Profile", role: .destructive) { pendingProfileDeletion = profile }
                .padding(.top, 4)
        } label: {
            HStack {
                Text(profile.displayName)
                if profile.id == resolvedActiveProfileID, profiles.count > 1 {
                    Text("Default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if profile.isEmpty {
                    Text("Empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Categories

    private var categoriesSection: some View {
        Section {
            ForEach(AutofillCategory.allCases, id: \.self) { category in
                Toggle(isOn: categoryBinding(category)) {
                    Label(category.label, systemImage: category.systemImage)
                }
            }
        } header: {
            SettingsLabel("Information to Include", systemImage: "checklist", tint: SettingsTint.autofill)
        } footer: {
            Text("Turn a category off and autofill skips those fields everywhere, even when a profile has something saved for them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Per-site exceptions

    private var exceptionsSection: some View {
        Section {
            if preferences.disabledHostList.isEmpty {
                Text("No sites excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(preferences.disabledHostList, id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer(minLength: 8)
                        Button("Allow") { preferences.setHost(host, enabled: true) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            SettingsLabel("Excluded Sites", systemImage: "hand.raised", tint: SettingsTint.autofill)
        } footer: {
            Text("Choose \"Never Autofill on This Site\" from the autofill menu to add a site here. Subdomains count as separate sites.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Reset

    private var resetSection: some View {
        Section {
            Button("Delete All Autofill Data…", role: .destructive) { confirmingDeleteAll = true }
                .disabled(profiles.isEmpty && preferences.disabledHosts.isEmpty)
        } footer: {
            Text("Autofill profiles are kept separately from browsing data — clearing a site's data leaves them alone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Bindings and actions

    /// The stored choice, or the first profile when nothing is chosen yet.
    private var resolvedActiveProfileID: UUID? {
        if let id = preferences.activeProfileID, profiles.contains(where: { $0.id == id }) { return id }
        return profiles.first?.id
    }

    private var activeProfileBinding: Binding<UUID?> {
        Binding(get: { resolvedActiveProfileID }, set: { preferences.activeProfileID = $0 })
    }

    private func categoryBinding(_ category: AutofillCategory) -> Binding<Bool> {
        Binding(
            get: { preferences.allows(category) },
            set: { preferences.setCategory(category, enabled: $0) }
        )
    }

    private func addProfile() {
        let profile = AutofillProfile(label: defaultLabel())
        modelContext.insert(profile)
        try? modelContext.save()
        if preferences.activeProfileID == nil { preferences.activeProfileID = profile.id }
        expandedProfileID = profile.id
    }

    /// "Personal", then "Profile 2", "Profile 3"… so a new profile always has a
    /// name to distinguish it in the picker.
    private func defaultLabel() -> String {
        profiles.isEmpty
            ? String(localized: "Personal")
            : String(localized: "Profile \(profiles.count + 1)")
    }

    private func delete(_ profile: AutofillProfile) {
        if preferences.activeProfileID == profile.id { preferences.activeProfileID = nil }
        modelContext.delete(profile)
        try? modelContext.save()
    }

    private func deleteAll() {
        for profile in profiles { modelContext.delete(profile) }
        try? modelContext.save()
        preferences.resetAll()
    }
}

/// The field-by-field editor for one profile. Split out so `@Bindable` can hand
/// each TextField a direct binding into the model.
private struct AutofillProfileEditor: View {
    @Bindable var profile: AutofillProfile

    var body: some View {
        Group {
            LabeledContent("Profile name") {
                TextField("Home", text: $profile.label).textFieldStyle(.roundedBorder)
            }
            LabeledContent(AutofillField.givenName.label) {
                TextField("", text: $profile.givenName).textFieldStyle(.roundedBorder)
            }
            LabeledContent(AutofillField.familyName.label) {
                TextField("", text: $profile.familyName).textFieldStyle(.roundedBorder)
            }
            LabeledContent(AutofillField.email.label) {
                TextField("", text: $profile.email).textFieldStyle(.roundedBorder)
            }
            LabeledContent(AutofillField.phone.label) {
                TextField("", text: $profile.phone).textFieldStyle(.roundedBorder)
            }
            LabeledContent(AutofillField.organization.label) {
                TextField("", text: $profile.organization).textFieldStyle(.roundedBorder)
            }
            LabeledContent(AutofillField.addressLine1.label) {
                TextField("", text: $profile.addressLine1).textFieldStyle(.roundedBorder)
            }
            LabeledContent(AutofillField.addressLine2.label) {
                TextField("", text: $profile.addressLine2).textFieldStyle(.roundedBorder)
            }
            LabeledContent(AutofillField.city.label) {
                TextField("", text: $profile.city).textFieldStyle(.roundedBorder)
            }
            LabeledContent(AutofillField.state.label) {
                TextField("", text: $profile.addressState).textFieldStyle(.roundedBorder)
            }
            LabeledContent(AutofillField.postalCode.label) {
                TextField("", text: $profile.postalCode).textFieldStyle(.roundedBorder)
            }
            LabeledContent(AutofillField.country.label) {
                TextField("", text: $profile.country).textFieldStyle(.roundedBorder)
            }
        }
    }
}

#Preview {
    AutofillSettingsView()
}
