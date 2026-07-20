//
//  SettingsDemos.swift
//  Straight Up Browser
//
//  One interactive demo per setting, shown in the "?" popover next to each control. Every demo is
//  the same shape: a preview on top, the control that drives it underneath. The popover seeds a
//  draft from the live value, so you can play with a setting without committing to it. Read-only
//  demos (the download-rule and folder previews) just report what's already configured.
//

import SwiftUI
import Combine

// MARK: - Shared chrome

/// A fill alone all but vanishes against the popover's own background, so the card carries a
/// hairline border to keep its edges legible in both appearances.
var demoCard: some View {
    RoundedRectangle(cornerRadius: 12)
        .fill(.quaternary)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
}

func demoCaption(_ text: LocalizedStringKey) -> some View {
    Text(text)
        .font(.caption2)
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
}

/// A little keycap, e.g. ⌘P.
func keycap(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
        )
}

/// A stand-in browser window: rounded frame, traffic lights, then whatever content the demo puts
/// inside. Reused by most of the spatial demos so they share one look.
struct WindowFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 8, height: 8)
                Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 8, height: 8)
                Circle().fill(Color(red: 0.24, green: 0.79, blue: 0.29)).frame(width: 8, height: 8)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.06))

            content
        }
        .background(Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

/// A grey text line, so mock pages have body copy to lay out around.
private func pageLine(width: CGFloat = .infinity) -> some View {
    Capsule()
        .fill(Color.primary.opacity(0.12))
        .frame(maxWidth: width)
        .frame(height: 6)
}

// MARK: - General

struct SearchEngineDemo: View {
    @Binding var engine: String
    private let engines = ["Google", "DuckDuckGo", "Bing", "Yahoo"]

    private var url: String {
        switch engine {
        case "DuckDuckGo": return "duckduckgo.com/?q=best+coffee+near+me"
        case "Bing": return "bing.com/search?q=best+coffee+near+me"
        case "Yahoo": return "search.yahoo.com/search?p=best+coffee+near+me"
        default: return "google.com/search?q=best+coffee+near+me"
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                demoCaption("You type in the omnibar")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("best coffee near me")
                }
                .font(.callout)

                Image(systemName: "arrow.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)

                demoCaption("Browser goes to")
                HStack(spacing: 6) {
                    Image(systemName: "globe").foregroundStyle(SettingsTint.general)
                    Text(url).fontDesign(.monospaced).font(.caption)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(demoCard)
            .animation(.easeInOut, value: engine)

            Picker("", selection: $engine) {
                ForEach(engines, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct OmnibarPositionDemo: View {
    @Binding var position: String

    private var yOffset: CGFloat {
        switch position {
        case "Top": return 6
        case "Center": return 56
        default: return 32 // Upper
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            WindowFrame {
                ZStack(alignment: .top) {
                    // Faint page content behind the omnibar.
                    VStack(spacing: 8) {
                        pageLine(width: 120)
                        pageLine()
                        pageLine()
                        pageLine(width: 90)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    omnibar
                        .padding(.horizontal, 14)
                        .offset(y: yOffset)
                        .animation(.smooth(duration: 0.3), value: position)
                }
                .frame(height: 130)
            }

            Picker("", selection: $position) {
                Text("Top").tag("Top")
                Text("Upper").tag("Upper")
                Text("Center").tag("Center")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var omnibar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.secondary)
            Text("Search or enter address")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            Capsule()
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(Capsule().strokeBorder(SettingsTint.general.opacity(0.6), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        )
    }
}

struct SpaceScrollDemo: View {
    @Binding var percent: Double
    @State private var offset: CGFloat = 0

    private let pageHeight: CGFloat = 320
    private let viewportHeight: CGFloat = 130

    var body: some View {
        VStack(spacing: 20) {
            WindowFrame {
                VStack(spacing: 9) {
                    ForEach(0..<22, id: \.self) { i in
                        pageLine(width: i.isMultiple(of: 4) ? 90 : .infinity)
                    }
                }
                .padding(14)
                .frame(width: 320, alignment: .top)
                .offset(y: -offset)
                .frame(height: viewportHeight, alignment: .top)
                .clipped()
            }

            HStack(spacing: 12) {
                Text("\(Int(percent))%").monospacedDigit().frame(width: 42, alignment: .leading)
                Slider(value: $percent, in: 10...100, step: 5)
                Button("Press Space") {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        let step = viewportHeight * CGFloat(percent / 100)
                        offset = min(offset + step, pageHeight - viewportHeight)
                        if offset >= pageHeight - viewportHeight { offset = 0 }
                    }
                }
            }
        }
    }
}

struct CmdPPDFDemo: View {
    @Binding var enabled: Bool

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                keycap("⌘P")
                Image(systemName: "arrow.down").font(.caption).foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    Image(systemName: enabled ? "doc.richtext.fill" : "printer.fill")
                        .foregroundStyle(enabled ? SettingsTint.general : .secondary)
                    Text(enabled ? "Saves the page as a PDF" : "Opens the print dialog")
                        .font(.callout).fontWeight(.medium)
                }
                Text(enabled ? "Print is still one keystroke away: ⇧⌘P."
                             : "Turn this on to make ⌘P export a PDF instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(demoCard)
            .animation(.easeInOut, value: enabled)

            Toggle("⌘P creates a PDF", isOn: $enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DefaultBrowserPromptDemo: View {
    @Binding var enabled: Bool

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                Text("New Tab").font(.caption).foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .foregroundStyle(enabled ? SettingsTint.general : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Make Browser your default?")
                            .font(.caption.weight(.semibold))
                        Text("Links from other apps will open here.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Set Default")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .opacity(enabled ? 1 : 0.25)
                Text(enabled ? "Appears in the corner until you answer it."
                             : "Never shown. Set the default in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(demoCard)
            .animation(.easeInOut, value: enabled)

            Toggle("Offer to make Browser your default", isOn: $enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct HotkeyDemo: View {
    @Binding var chord: String

    private var label: String {
        switch chord {
        case "ctrlOptSpace": return "⌃⌥Space"
        case "off": return "Off"
        default: return "⌥Space"
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                if chord == "off" {
                    Image(systemName: "keyboard").font(.title).foregroundStyle(.secondary)
                    Text("The global shortcut is disabled.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    keycap(label).font(.system(size: 16, weight: .medium, design: .rounded))
                    Text("Opens the omnibar from any app, even when Browser isn't focused.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(demoCard)
            .animation(.easeInOut, value: chord)

            Picker("", selection: $chord) {
                Text("⌥ Space").tag("optSpace")
                Text("⌃⌥ Space").tag("ctrlOptSpace")
                Text("Off").tag("off")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Content

struct JavaScriptDemo: View {
    @Binding var enabled: Bool
    @State private var count = 0

    var body: some View {
        VStack(spacing: 20) {
            WindowFrame {
                VStack(spacing: 12) {
                    if enabled {
                        Text("Counter: \(count)")
                            .font(.callout).fontWeight(.medium)
                        Button("Click me (+1)") { count += 1 }
                            .controlSize(.small)
                    } else {
                        Image(systemName: "curlybraces.square")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("This content requires JavaScript.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 130)
                .padding()
            }
            .animation(.easeInOut, value: enabled)

            Toggle("Enable JavaScript", isOn: $enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Shows a mock page magnifying, the way a trackpad pinch or two-finger double-tap zooms it.
struct PinchZoomDemo: View {
    @Binding var enabled: Bool

    var body: some View {
        VStack(spacing: 20) {
            WindowFrame {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The quick brown fox")
                        .font(.callout).fontWeight(.medium)
                    pageLine()
                    pageLine(width: 120)
                }
                .scaleEffect(enabled ? 1.4 : 1.0, anchor: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 130)
                .padding()
                .clipped()
            }
            .animation(.easeInOut, value: enabled)

            Toggle("Pinch to zoom", isOn: $enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Downloads

/// Read-only: reports what your *live* rules would do to a sample URL, using the same code path the
/// browser uses — so the demo can't drift from the behaviour. The popover shows Done, not Save.
struct DownloadRuleDemo: View {
    @State private var urlString = "https://example.com/report.pdf"
    @State private var isImage = false

    private var verdict: Bool? {
        guard let url = URL(string: urlString), url.host != nil else { return nil }
        return SettingsManager.shared.optionClickShouldDownload(url, isImage: isImage)
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                demoCaption("Option-click this URL")
                TextField("https://…", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                Toggle("Treat it as an image", isOn: $isImage)

                Divider()

                demoCaption("Browser will")
                if let verdict {
                    Label(
                        verdict ? "Download the file" : "Open it in a tab",
                        systemImage: verdict ? "arrow.down.circle.fill" : "macwindow"
                    )
                    .font(.callout).fontWeight(.medium)
                    .foregroundStyle(verdict ? Color.green : Color.secondary)
                } else {
                    Text("Enter a full URL, with a domain.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(demoCard)
            .animation(.easeInOut, value: verdict)

            Text("Follows your live rules in order: never-domains, the per-kind toggles, always-domains, then file types.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct DownloadFolderDemo: View {
    @Binding var path: String

    private var display: String {
        path.isEmpty ? "~/Downloads" : (path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc.fill").foregroundStyle(SettingsTint.downloads)
                    Text("report.pdf").fontDesign(.monospaced).font(.caption)
                }
                Image(systemName: "arrow.down").font(.caption).foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundStyle(SettingsTint.downloads)
                    Text(display).fontDesign(.monospaced).font(.caption)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(demoCard)
            .animation(.easeInOut, value: display)

            Text(path.isEmpty
                 ? "Empty means your system Downloads folder."
                 : "Downloaded files are saved here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Appearance

struct ThemeDemo: View {
    @Binding var theme: String

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                sample(.light, name: "Light")
                sample(.dark, name: "Dark")
            }
            .frame(maxWidth: .infinity)

            if theme == "System" {
                Text("System follows your Mac's appearance — and switches with it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Picker("", selection: $theme) {
                Text("Light").tag("Light")
                Text("Dark").tag("Dark")
                Text("System").tag("System")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sample(_ scheme: ColorScheme, name: String) -> some View {
        let selected = theme == name
        return VStack(spacing: 6) {
            WindowFrame {
                VStack(spacing: 6) {
                    pageLine(width: 60)
                    pageLine()
                    pageLine(width: 80)
                }
                .padding(10)
                .frame(width: 120, height: 74, alignment: .top)
            }
            .environment(\.colorScheme, scheme)

            Text(name.localized).font(.caption).fontWeight(selected ? .semibold : .regular)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
        )
    }
}

/// The one demo that edits live settings rather than a draft: the loading indicator spans five
/// toggles, and modelling a five-field draft isn't worth it. Read-only popover (Done), toggles
/// write straight through — the mock window animates a fake page load so you can see the result.
struct ProgressIndicatorDemo: View {
    @AppStorage("progressBarTop") private var top = true
    @AppStorage("progressBarBottom") private var bottom = false
    @AppStorage("progressBarLeft") private var left = false
    @AppStorage("progressBarRight") private var right = false
    @AppStorage("progressFaviconRing") private var ring = false

    @State private var progress: CGFloat = 0.15
    private let tick = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            mockWindow
                .frame(height: 130)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Toggle("Top", isOn: $top)
                    Toggle("Bottom", isOn: $bottom)
                    Toggle("Left", isOn: $left)
                    Toggle("Right", isOn: $right)
                }
                .toggleStyle(.checkbox)
                Toggle("Ring around the favicon", isOn: $ring)
                    .toggleStyle(.checkbox)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(tick) { _ in
            progress += 0.006
            if progress >= 1 { progress = 0 }
        }
    }

    private var mockWindow: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )

            VStack(spacing: 0) {
                // Tab bar with a favicon that can wear the progress ring.
                HStack(spacing: 6) {
                    ZStack {
                        if ring {
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 18, height: 18)
                        }
                        Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text("Loading…").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 28)

                Spacer()
            }

            // Edge bars grow from their leading/top corner as the page loads.
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack(alignment: .topLeading) {
                    if top {
                        bar(width: w * progress, height: 3)
                            .position(x: (w * progress) / 2, y: 1.5)
                    }
                    if bottom {
                        bar(width: w * progress, height: 3)
                            .position(x: (w * progress) / 2, y: h - 1.5)
                    }
                    if left {
                        bar(width: 3, height: h * progress)
                            .position(x: 1.5, y: (h * progress) / 2)
                    }
                    if right {
                        bar(width: 3, height: h * progress)
                            .position(x: w - 1.5, y: (h * progress) / 2)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        Rectangle().fill(Color.accentColor).frame(width: width, height: height)
    }
}

// MARK: - Security

struct SSLStrictDemo: View {
    @Binding var strict: Bool

    var body: some View {
        VStack(spacing: 20) {
            WindowFrame {
                VStack(spacing: 10) {
                    Image(systemName: strict ? "lock.trianglebadge.exclamationmark.fill"
                                             : "lock.open.trianglebadge.exclamationmark.fill")
                        .font(.title)
                        .foregroundStyle(strict ? Color.red : Color.orange)
                    Text(strict ? "Connection blocked" : "This site's certificate is invalid")
                        .font(.callout).fontWeight(.medium)
                    if strict {
                        Text("The certificate is invalid, so you can't continue.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            Text("Go back").controlSize(.small)
                            Text("Proceed anyway").fontWeight(.medium).foregroundStyle(.orange)
                        }
                        .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 130)
                .padding()
            }
            .animation(.easeInOut, value: strict)

            Toggle("Refuse invalid certificates (strict SSL)", isOn: $strict)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AdBlockDemo: View {
    @Binding var enabled: Bool

    var body: some View {
        VStack(spacing: 20) {
            WindowFrame {
                VStack(spacing: 9) {
                    pageLine(width: 100)
                    pageLine()
                    adSlot
                    pageLine()
                    pageLine(width: 80)
                }
                .padding(12)
                .frame(height: 130, alignment: .top)
            }
            .animation(.easeInOut, value: enabled)

            Toggle("Block ads and trackers", isOn: $enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var adSlot: some View {
        Group {
            if enabled {
                HStack(spacing: 5) {
                    Image(systemName: "nosign")
                    Text("Ad blocked")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3]))
                )
            } else {
                Text("ADVERTISEMENT")
                    .font(.caption2).fontWeight(.bold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange))
            }
        }
    }
}

struct CLIRealClicksDemo: View {
    @Binding var enabled: Bool

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").foregroundStyle(SettingsTint.security)
                    Text("browser-cli click --real").fontDesign(.monospaced).font(.caption)
                }

                Divider()

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: enabled ? "cursorarrow.click.2" : "cursorarrow.slash")
                        .foregroundStyle(enabled ? Color.green : Color.secondary)
                    Text(enabled
                         ? "The click posts a real mouse event — it counts as a user gesture, so video plays and pop-ups open."
                         : "The click is synthetic, and pages that require a genuine user gesture ignore it.")
                        .font(.callout)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(demoCard)
            .animation(.easeInOut, value: enabled)

            Label("Any process running as you can then click inside the browser window.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)

            Toggle("Allow the CLI to send real mouse clicks", isOn: $enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Memory

struct MemorySaverDemo: View {
    @Binding var enabled: Bool

    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                beat("A background tab you haven't touched", icon: "macwindow", tint: .secondary)
                beat(enabled ? "Memory runs low → the tab is released from RAM"
                             : "Stays in RAM whether or not memory runs low",
                     icon: enabled ? "memorychip" : "memorychip.fill",
                     tint: enabled ? SettingsTint.memory : .secondary)

                Divider()

                beat(enabled ? "You return → it reloads instantly, scroll and history kept"
                             : "Nothing is released, so nothing needs reloading",
                     icon: enabled ? "arrow.clockwise.circle.fill" : "circle",
                     tint: enabled ? .green : .secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(demoCard)
            .animation(.easeInOut, value: enabled)

            Toggle("Enable memory saving", isOn: $enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func beat(_ text: LocalizedStringKey, icon: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
            Text(text).font(.callout)
        }
    }
}
