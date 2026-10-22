import SwiftUI

struct MobileChromeSettingsView: View {
    var moveBar: (() -> Void)? = nil
    @AppStorage(MobileChromeSettings.customPosition) private var custom = false
    @AppStorage(MobileChromeSettings.x) private var x = 0.5
    @AppStorage(MobileChromeSettings.y) private var y = 1.0
    @AppStorage(MobileChromeSettings.width) private var width = 0.4
    @AppStorage(MobileChromeSettings.snapping) private var snapping = true
    @AppStorage(MobileChromeSettings.hidden) private var hidden = false
    @AppStorage(MobileChromeSettings.hideGesture) private var hideGesture = false
    @AppStorage(MobileChromeSettings.visualTabsGesture) private var visualTabsGesture = false
    @AppStorage(MobileChromeSettings.rotationRules) private var rotationRules = Data()
    @State private var domain = ""

    var body: some View {
        Form {
            Section {
                Toggle("Custom gesture bar position", isOn: $custom)
                if custom {
                    positionSlider("Horizontal position", value: $x)
                    positionSlider("Vertical position", value: $y)
                    VStack(alignment: .leading) {
                        Text("Width: \(Int(MobileChromeLayout.widthFraction(width) * 100))%")
                        Slider(value: Binding(get: { MobileChromeLayout.widthFraction(width) }, set: { width = $0 }), in: 0.3...1, step: 0.01)
                            .accessibilityLabel("Gesture bar width")
                    }
                    Toggle("Snap while moving", isOn: $snapping)
                }
                if let moveBar { Button("Move Bar on Page", action: moveBar) }
                Button("Reset Position and Width") { custom = false; x = 0.5; y = 1; width = 0.4; hidden = false }
            } header: { Text("Gesture Bar") } footer: {
                Text("Choose Move Bar on Page, drag, then choose Done Moving. Width is at least 30% of this window’s width, limited only by available safe-area space. Position adjusts to the keyboard, safe areas and rotation. Snapping uses viewport edges and stable fixed page borders when available; scrolling never moves the bar. Existing per-site edge choices apply when Custom Position is off.")
            }
            Section {
                Toggle("Show gesture bar", isOn: Binding(get: { !hidden }, set: { hidden = !$0 }))
                Toggle("Double-tap near top controls to hide or show", isOn: $hideGesture)
                Toggle("Edge-pan or swipe bar up for Visual Tabs", isOn: $visualTabsGesture)
            } header: { Text("Optional Gestures") } footer: {
                Text("Double-tap just below the top circles, or just inside the sensor-side strip in landscape. Page Menu always offers Show Gesture Bar and Settings. When enabled, swipe inward from the right edge or swipe the bar up for Visual Tabs. Use the Page Menu for Forward; left-edge Back and system gestures stay available. Visual Tabs also opens from the Tabs menu. Reduce Motion disables the page zoom.")
            }
            Section {
                HStack {
                    TextField("Exact domain, e.g. example.com", text: $domain)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Add") {
                        guard let url = domainURL else { return }
                        rotationRules = MobileDomainRotation.setting("locked", for: url, in: rotationRules)
                        domain = ""
                    }.disabled(domainURL == nil)
                }
                ForEach(MobileDomainRotation.rules(rotationRules).keys.sorted(), id: \.self) { host in
                    VStack(alignment: .leading) {
                        Text(host).font(.headline)
                        Picker("Rotation", selection: Binding(get: { MobileDomainRotation.rules(rotationRules)[host] ?? "allow" }, set: { value in
                            var rules = MobileDomainRotation.rules(rotationRules); rules[host] = value
                            rotationRules = (try? JSONEncoder().encode(rules)) ?? rotationRules
                        })) {
                            Text("Allow").tag("allow")
                            Text("Lock while on this domain").tag("locked")
                        }
                        Button("Use App Setting", role: .destructive) {
                            var rules = MobileDomainRotation.rules(rotationRules); rules.removeValue(forKey: host)
                            rotationRules = (try? JSONEncoder().encode(rules)) ?? rotationRules
                        }
                    }
                }
                Button("Reset All Domain Rotation Rules", role: .destructive) { rotationRules = Data() }
            } header: { Text("Domain Rotation") } footer: {
                Text("Rules match the exact host on HTTP and HTTPS, including www and subdomains separately. A locked domain keeps the orientation in use when you enter it. Page Menu → Rotation Lock can lock this site immediately. iOS rotation lock, supported device orientations and iPad windowing can limit requests; these settings cannot override the system.")
            }
            Section("Address Suggestions") {
                Text("Suggestions rank bookmarks, open regular tabs and this device’s history locally. Open tabs already received through your enabled private iCloud sync can appear too; other devices must use the same iCloud account and sync may be delayed. History itself is local. Incognito browsing does not use these suggestions. Typed text is not sent to a suggestion service; submitting a search uses your selected search engine.")
            }
        }.navigationTitle("Mobile Controls")
    }

    private var domainURL: URL? {
        let text = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace), let url = URL(string: text.contains("://") ? text : "https://" + text), MobileDomainRotation.host(url) != nil else { return nil }
        return url
    }
    private func positionSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(Int(MobileChromeLayout.unit(value.wrappedValue) * 100))%")
            Slider(value: Binding(get: { MobileChromeLayout.unit(value.wrappedValue) }, set: { value.wrappedValue = $0 }), in: 0...1, step: 0.01)
                .accessibilityLabel(title)
        }
    }
}
