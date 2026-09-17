//
//  PasswordPicker.swift
//  Straight Up Browser
//
//  ⌥⌘\: fill a saved login without touching the mouse. One saved login for
//  the site fills straight away — the same thing clicking the suggestion
//  under the field does. Several open this picker: type to narrow, arrows to
//  choose, Return to fill, Escape to dismiss.
//
//  Scoped to the site you are on, because that is the only place a fill can
//  land: CredentialManager refuses to type a credential into a page whose
//  domain does not match it. Listing other sites here would only offer picks
//  that silently do nothing.
//
//  Reuses OmnibarTextField for the arrow/Return/Escape handling.
//

import SwiftUI
import AppKit

// MARK: - Site tint

/// A quiet brand tint for a site, so a credential popup reads as "this site"
/// rather than a grey box: the average of the favicon's opaque, non-grey
/// pixels, falling back to a stable per-domain hue when there is no favicon.
enum SiteTint {
    // ponytail: favicons never change mid-session; cache the averaged ones and
    // never cache a fallback, so a late-arriving favicon still wins.
    private static var cache: [String: Color] = [:]

    static func color(domain: String, favicon: Data?) -> Color {
        if let cached = cache[domain] { return cached }
        guard let favicon, let averaged = average(favicon) else { return fallback(domain) }
        cache[domain] = averaged
        return averaged
    }

    private static func average(_ data: Data) -> Color? {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var red = 0.0, green = 0.0, blue = 0.0, counted = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            let r = min(1, Double(pixels[index]) / 255 / alpha)
            let g = min(1, Double(pixels[index + 1]) / 255 / alpha)
            let b = min(1, Double(pixels[index + 2]) / 255 / alpha)
            // Skip the white/grey most favicons pad themselves with, or every
            // tint averages out to the same lifeless grey.
            guard max(r, g, b) - min(r, g, b) > 0.12 else { continue }
            red += r; green += g; blue += b; counted += 1
        }
        guard counted > 0 else { return nil }
        return Color(red: red / counted, green: green / counted, blue: blue / counted)
    }

    /// Stable across launches — Swift's own hashValue is seeded per process.
    private static func fallback(_ domain: String) -> Color {
        let hue = domain.utf8.reduce(UInt32(7)) { ($0 &* 31 &+ UInt32($1)) % 360 }
        return Color(hue: Double(hue) / 360, saturation: 0.5, brightness: 0.7)
    }
}

// MARK: - Site icon

/// The site's favicon, or a key glyph in the site's tint when it has none.
struct SiteIcon: View {
    let favicon: Data?
    let tint: Color
    var size: CGFloat = 14

    var body: some View {
        if let favicon, let image = NSImage(data: favicon) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            Image(systemName: "key.fill")
                .font(.system(size: size * 0.8))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Picker

struct PasswordPickerView: View {
    @Binding var isPresented: Bool
    let domain: String?
    let favicon: Data?
    let onPick: (String) -> Void

    @State private var query = ""
    @State private var selectedIndex = 0

    static let width: CGFloat = 320

    private var tint: Color { SiteTint.color(domain: domain ?? "", favicon: favicon) }

    private var usernames: [String] {
        guard let domain else { return [] }
        let saved = SavedCredentialStore.usernames(domain: domain)
        guard !query.isEmpty else { return saved }
        return saved.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if usernames.isEmpty {
                Text(query.isEmpty ? "No saved passwords for this site" : "No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(usernames.enumerated()), id: \.element) { index, username in
                                row(username, isSelected: index == selectedIndex)
                                    .id(index)
                                    .onTapGesture {
                                        onPick(username)
                                        isPresented = false
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    .onChange(of: selectedIndex) { _, newValue in
                        proxy.scrollTo(newValue)
                    }
                }
            }
        }
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.5), lineWidth: 1))
        .shadow(radius: 16, y: 6)
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Saved passwords for \(domain ?? "this site")"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            SiteIcon(favicon: favicon, tint: tint, size: 16)
            VStack(alignment: .leading, spacing: 0) {
                OmnibarTextField(
                    text: $query,
                    placeholder: "Search logins",
                    shouldFocus: true,
                    onArrowUp: { move(-1) },
                    onArrowDown: { move(1) },
                    onCommit: { _ in commit() },
                    onCancel: { isPresented = false }
                )
                if let domain {
                    Text(domain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func move(_ delta: Int) {
        guard !usernames.isEmpty else { return }
        selectedIndex = max(0, min(usernames.count - 1, selectedIndex + delta))
    }

    private func commit() {
        guard usernames.indices.contains(selectedIndex) else { return }
        onPick(usernames[selectedIndex])
        isPresented = false
    }

    private func row(_ username: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? tint : .secondary)
                .frame(width: 14)
            Text(username)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? tint.opacity(0.18) : .clear)
        .contentShape(Rectangle())
    }
}
