//
//  PasswordPicker.swift
//  Straight Up Browser
//
//  ⌘\: search every saved password and fill one into the page without
//  touching the mouse. Unlike CredentialSuggestionList (which only appears
//  once a login field is focused), this works from anywhere on the page and
//  lets you search across every saved site, not just the current one.
//
//  Reuses OmnibarTextField for the arrow-key/Return/Escape handling and
//  CredentialManager.fillFromPicker for the actual fill — the fill only takes
//  effect if the picked credential's domain matches the current page, same
//  safety guard the focus-triggered picker already has.
//

import SwiftUI

struct PasswordPickerView: View {
    @Binding var isPresented: Bool
    let currentDomain: String?
    let onPick: (SavedCredential) -> Void

    @State private var query = ""
    @State private var selectedIndex = 0

    static let width: CGFloat = 360

    private var candidates: [SavedCredential] {
        let all = SavedCredentialStore.all()
        let filtered = query.isEmpty ? all : all.filter {
            $0.domain.localizedCaseInsensitiveContains(query) || $0.username.localizedCaseInsensitiveContains(query)
        }
        guard let currentDomain else { return filtered }
        // Same-site logins float to the top — that's almost always what
        // ⌘\ was pressed for.
        return filtered.sorted { a, b in
            let aHere = a.domain == currentDomain
            let bHere = b.domain == currentDomain
            if aHere != bHere {
                return aHere
            }
            if a.domain != b.domain {
                return a.domain < b.domain
            }
            return a.username < b.username
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(.secondary)
                OmnibarTextField(
                    text: $query,
                    placeholder: "Search saved passwords",
                    shouldFocus: true,
                    onArrowUp: { move(-1) },
                    onArrowDown: { move(1) },
                    onCommit: { _ in commit() },
                    onCancel: { isPresented = false }
                )
            }
            .padding(12)

            if !candidates.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, credential in
                                row(credential, isSelected: index == selectedIndex)
                                    .id(index)
                                    .onTapGesture {
                                        onPick(credential)
                                        isPresented = false
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                    .onChange(of: selectedIndex) { _, newValue in
                        proxy.scrollTo(newValue)
                    }
                }
            } else if !query.isEmpty {
                Text("No saved passwords match")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
        }
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(radius: 16, y: 6)
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Password picker"))
    }

    private func move(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        selectedIndex = max(0, min(candidates.count - 1, selectedIndex + delta))
    }

    private func commit() {
        guard candidates.indices.contains(selectedIndex) else { return }
        onPick(candidates[selectedIndex])
        isPresented = false
    }

    private func row(_ credential: SavedCredential, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(credential.username).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Text(credential.domain).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
    }
}
