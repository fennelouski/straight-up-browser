//
//  SettingsSearch.swift
//  Straight Up Browser
//
//  The index that powers ⌘F in the Settings window: one entry per settings section, searchable
//  by its header title and the labels of the controls inside it. Picking a result jumps to that
//  section's pane and briefly highlights it — see CollapsibleSection's searchID/highlight and
//  SettingsWindow's ScrollViewReader wiring. macOS only: SettingsWindow.swift, the only thing
//  that reads this index, is AppKit-only.
//

#if os(macOS)
import SwiftUI

struct SettingsSearchEntry: Identifiable {
    let id: String
    let pane: SettingsPane
    let title: String
    let keywords: String

    // AND semantics: "clear cookies" matches keywords containing both words, non-contiguously.
    func matches(_ query: String) -> Bool {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return false }
        let haystack = "\(title) \(keywords)".lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }
}

@MainActor
@Observable
final class SettingsSearchNavigation {
    static let shared = SettingsSearchNavigation()
    private init() {}

    var pendingScrollID: String?
    var highlightedID: String?
}

enum SettingsSearchIndex {
    static let entries: [SettingsSearchEntry] = {
        var entries: [SettingsSearchEntry] = [
            // General
            .init(id: "general.sync", pane: .general, title: "Sync",
                  keywords: "sync browser data across your devices icloud tab closing live page state cookies local storage session storage saved logins"),
            .init(id: "general.fast-forward", pane: .general, title: "Fast Forward",
                  keywords: "fast forward searches a destination results head start"),
            .init(id: "general.new-tab-links", pane: .general, title: "Links That Open New Tabs",
                  keywords: "mitosis animation sidebar open new tab beside its source command-click"),
            .init(id: "general.research-anchors", pane: .general, title: "Research Anchors",
                  keywords: "anchor links open peek beside the document as a tab workspace"),
            .init(id: "general.head-start", pane: .general, title: "Head Start",
                  keywords: "start loading before you press return prefetch"),
            .init(id: "general.site-nicknames", pane: .general, title: "Site Nicknames",
                  keywords: "learn what you call your sites apple intelligence gmail hn"),
            .init(id: "general.search", pane: .general, title: "Search",
                  keywords: "default search engine google duckduckgo bing yahoo omnibar position find bar position find emphasis"),
            .init(id: "general.behavior", pane: .general, title: "Behavior",
                  keywords: "spacebar scrolls cmd p creates a pdf print back forward navigate quick open override website shortcuts default browser nudge global omnibar hotkey"),
            .init(id: "general.back-guard", pane: .general, title: "Confirm Before Going Back",
                  keywords: "back guard call meeting camera microphone full screen video leave confirm split pane always ask never ask"),
            .init(id: "general.quit-safety", pane: .general, title: "Quit Safety",
                  keywords: "hold cmd q to quit safety"),

            // Shortcuts
            .init(id: "shortcuts.keyboard", pane: .shortcuts, title: "Keyboard Shortcuts",
                  keywords: "click a shortcut press the new keys reset all import from preset"),
            .init(id: "shortcuts.tab-switching", pane: .shortcuts, title: "Tab Switching",
                  keywords: "control tab cycles tabs in the order you used them recent"),
            .init(id: "shortcuts.website-priority", pane: .shortcuts, title: "When a Website Uses the Same Shortcut",
                  keywords: "website shortcut priority claim override per site all sites"),

            // Content
            .init(id: "content.web-content", pane: .content, title: "Web Content",
                  keywords: "enable javascript static pages"),
            .init(id: "content.zoom", pane: .content, title: "Zoom",
                  keywords: "pinch to zoom trackpad two-finger double-tap actual size"),
            .init(id: "content.translation", pane: .content, title: "Translation",
                  keywords: "auto-translate pages languages you read on-device manage languages translation history"),

            // Downloads
            .init(id: "downloads.option-click", pane: .downloads, title: "Option-Click Image Downloads",
                  keywords: "option-click downloads images bare images file types always on never on domains"),
            .init(id: "downloads.folder", pane: .downloads, title: "Download Folder",
                  keywords: "where downloaded files are saved system downloads folder choose"),

            // Screenshots
            .init(id: "screenshots.all", pane: .screenshots, title: "All Screenshots",
                  keywords: "shared folder set every format to png jpeg pdf split captures cmd s"),
            .init(id: "screenshots.kind.visible", pane: .screenshots, title: "Visible Area",
                  keywords: "what the page is showing right now"),
            .init(id: "screenshots.kind.fullPage", pane: .screenshots, title: "Full Page",
                  keywords: "the whole document top to bottom however far it scrolls"),
            .init(id: "screenshots.kind.element", pane: .screenshots, title: "Element Under Cursor",
                  keywords: "whatever the mouse is over an image a field or a block of text"),
            .init(id: "screenshots.kind.window", pane: .screenshots, title: "Window and Tab Bar",
                  keywords: "the entire window tab bar and all capture screen recording permission"),

            // Appearance
            .init(id: "appearance.tabs", pane: .appearance, title: "Tabs",
                  keywords: "tab sidebar side traditional tabs across the top auto-hide adaptive preview cards visual tab shape live previews tab thumbnails switching new tab button apple intelligence names"),
            .init(id: "appearance.developer-tools", pane: .appearance, title: "Developer Tools",
                  keywords: "open developer tools dock bottom left right window"),
            .init(id: "appearance.window", pane: .appearance, title: "Window",
                  keywords: "place the window on launch width position square corners shift cmd f snap"),
            .init(id: "appearance.theme", pane: .appearance, title: "Theme",
                  keywords: "light dark system appearance chrome toolbar tabs menus"),
            .init(id: "appearance.ai-search", pane: .appearance, title: "AI Search",
                  keywords: "effect color sparkles"),
            .init(id: "appearance.loading-progress", pane: .appearance, title: "Loading Progress",
                  keywords: "progress bar top bottom left right favicon ring"),
            .init(id: "appearance.page-fade", pane: .appearance, title: "Page Fade",
                  keywords: "fade pages in once they've drawn white flash fade length"),
            .init(id: "appearance.white-point", pane: .appearance, title: "White Point",
                  keywords: "max page brightness extended range"),
            .init(id: "appearance.black-point", pane: .appearance, title: "Black Point",
                  keywords: "black level near-blacks grey"),
            .init(id: "appearance.schedule", pane: .appearance, title: "Schedule",
                  keywords: "apply always between set times sunset to sunrise focus dark mode white point black point"),

            // Security
            .init(id: "security.ssl", pane: .security, title: "SSL / TLS",
                  keywords: "refuse invalid certificates strict ssl tls"),
            .init(id: "security.ad-blocking", pane: .security, title: "Ad Blocking",
                  keywords: "block ads and trackers"),
            .init(id: "security.agent-automation", pane: .security, title: "Agent Automation",
                  keywords: "enable agent automation cli mcp tab and page reading javascript synthetic interaction screenshots genuine mouse clicks"),
            .init(id: "security.mcp", pane: .security, title: "Model Context Protocol",
                  keywords: "copy mcp configuration show agent audit logs"),

            // Memory
            .init(id: "memory.saving", pane: .memory, title: "Memory Saving",
                  keywords: "enable memory saving default policy for new tabs ram idle background tabs"),
            .init(id: "memory.pinned-sites", pane: .memory, title: "Never Release These Sites",
                  keywords: "pinned sites add a site reset streaming calls"),
            .init(id: "memory.open-tabs", pane: .memory, title: "Open Tabs",
                  keywords: "open tabs memory policy"),

            // Privacy
            .init(id: "privacy.incognito", pane: .privacy, title: "Incognito",
                  keywords: "switch a tab to incognito with a key command"),
            .init(id: "privacy.signed-in", pane: .privacy, title: "Signed In",
                  keywords: "signed in sites sign out cookies caches storage"),
            .init(id: "privacy.site-permissions", pane: .privacy, title: "Site Permissions",
                  keywords: "camera microphone revoke revoke all"),
            .init(id: "privacy.data", pane: .privacy, title: "Data",
                  keywords: "clear browsing data manage cookies cookie manager history cache local storage"),

            // Agent
            .init(id: "agent.availability", pane: .agent, title: "AI Features",
                  keywords: "show ai features agent panel ai search apple intelligence"),
            .init(id: "agent.panel", pane: .agent, title: "Agent Panel",
                  keywords: "panel side resize the page when the agent is open load more of the page before answering"),
            .init(id: "agent.provider", pane: .agent, title: "Model Provider",
                  keywords: "provider model endpoint api key chat completions url"),
            .init(id: "agent.pricing", pane: .agent, title: "Provider Pricing",
                  keywords: "pricing applies to currency code input cached-input output blended microunits per million tokens"),
            .init(id: "agent.cowork", pane: .agent, title: "Cowork Files",
                  keywords: "folder choose cowork folder remove access"),
            .init(id: "agent.automation-records", pane: .agent, title: "Automation & Records",
                  keywords: "run history retention scheduled tasks app integrations timeline audit replay delete all agent history"),
            .init(id: "agent.safety", pane: .agent, title: "Safety & Run Budgets",
                  keywords: "maximum turns tool calls wall time provider-token cap provider-cost cap open pages model-result cap downloads download-byte cap artifacts artifact-byte cap"),
            .init(id: "agent.delegation", pane: .agent, title: "Delegated Runs",
                  keywords: "authority page access engine ceilings depth fan-out children delegated child runs"),
            .init(id: "agent.memory", pane: .agent, title: "Scoped Agent Memory",
                  keywords: "use scoped memory in agent runs allow proposals for sensitive memory retrieve entries retrieval context budget default retention scope isolation review and manage stored memory"),
            .init(id: "agent.diagnostics", pane: .agent, title: "Observability & Page Signals",
                  keywords: "keep on-device run metrics metrics retention recorded metric events runs represented clear local metrics remote diagnostics redacted diagnostic preview capture console events webkit diagnostic content"),
            .init(id: "agent.sync", pane: .agent, title: "Agent Definition Sync",
                  keywords: "sync scheduled task definitions provider presets user-authored memory icloud"),

            // Autofill
            .init(id: "autofill.master", pane: .autofill, title: "Autofill",
                  keywords: "offer saved information when filling out forms also offer in incognito tabs"),
            .init(id: "autofill.contacts", pane: .autofill, title: "Contacts",
                  keywords: "suggest first use my card add contact"),
            .init(id: "autofill.profiles", pane: .autofill, title: "Manual Profiles",
                  keywords: "add profile"),
            .init(id: "autofill.categories", pane: .autofill, title: "Information to Include",
                  keywords: "categories name email phone address organization"),
            .init(id: "autofill.exceptions", pane: .autofill, title: "Excluded Sites",
                  keywords: "never autofill on this site allow"),
        ]

        // Dynamic: one entry per shortcut section, matching the .id() applied to its
        // CollapsibleSection in ShortcutsSettingsView. Keywords include every command title in
        // that section so searching a specific shortcut surfaces the group it lives in.
        entries += ShortcutSection.allCases.map { section in
            let commandTitles = ShortcutCommand.availableOnCurrentPlatform
                .filter { $0.section == section }
                .map { String(localized: $0.title) }
                .joined(separator: " ")
            return SettingsSearchEntry(
                id: "shortcuts.section.\(section.rawValue)",
                pane: .shortcuts,
                title: String(localized: section.title),
                keywords: commandTitles
            )
        }

        return entries
    }()
}
#endif
