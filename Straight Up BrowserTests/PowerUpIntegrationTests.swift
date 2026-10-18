#if os(macOS)
import Foundation
import Testing
@testable import Browser

@MainActor struct PowerUpIntegrationTests {
    @Test func staticLibraryMatchesTasksWithoutLearningOrNetwork() {
        #expect(PowerUpSkill.all.first { $0.id == .globalOmnibar }?.matches("open from anywhere") == true)
        #expect(PowerUpSkill.all.first { $0.id == .swapPanes }?.matches("swap panes") == true)
        #expect(PowerUpSkill.all.first { $0.id == .savedWorkspace }?.matches("restore my setup") == true)
        #expect(PowerUpSkill.all.allSatisfy { $0.matches("") })
        #expect(PowerUpSkill.all.allSatisfy { !$0.matches("no-such-skill-9938") })
    }
    @Test func skillBindingsReadTheAuthoritativeRuntimeCommands() throws {
        let quickOpen = try #require(PowerUpSkill.all.first { $0.id == .quickOpen })
        #expect(quickOpen.commandID == ShortcutCommand.quickOpen.id)
        #expect(quickOpen.binding() == ShortcutStore.shared.shortcut(for: .quickOpen).displayString)
        for id in [PowerUpFeatureID.splitLayout, .swapPanes, .savedWorkspace] {
            let skill = try #require(PowerUpSkill.all.first { $0.id == id })
            #expect(skill.commandID == ShortcutCommand.arrangePanes.id)
            #expect(skill.binding() == ShortcutStore.shared.shortcut(for: .arrangePanes).displayString)
        }
    }
    @Test func settingsOrderRetainsKnownIDsAndAddsNewPaneWithoutDuplicates() {
        let order = SettingsNavigationLayout.orderedPanes("privacy,agent,unknown,privacy")
        #expect(Array(order.prefix(2)) == [.privacy, .agent])
        #expect(order.count == SettingsPane.allCases.count && Set(order).count == order.count)
        #expect(order.last == .powerUp)
        let width = SettingsNavigationLayout.sidebarWidth(labelWidths: [400])
        #expect(width > 400)
        #expect(SettingsNavigationLayout.usesCompactNavigation(availableWidth: 720, sidebarWidth: width))
        #expect(!SettingsNavigationLayout.usesCompactNavigation(availableWidth: 1200, sidebarWidth: width))
    }
}
#endif
