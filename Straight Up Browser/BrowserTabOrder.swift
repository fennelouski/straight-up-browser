import Foundation

struct BrowserTabSection {
    let group: TabGroup?
    let tabs: [Tab]
}

enum BrowserTabOrder {
    static func sections(tabs: [Tab], groups: [TabGroup]) -> [BrowserTabSection] {
        let orderedGroups = groups.sorted { $0.orderIndex < $1.orderIndex }
        let knownGroupIDs = Set(orderedGroups.map(\.id))
        let byGroup = Dictionary(grouping: tabs) { tab -> UUID? in
            guard let groupID = tab.groupId, knownGroupIDs.contains(groupID) else {
                return nil
            }
            return groupID
        }

        var result: [BrowserTabSection] = []
        if let ungrouped = byGroup[nil], !ungrouped.isEmpty {
            result.append(
                BrowserTabSection(group: nil, tabs: BrowserLibrary.sortedTabs(ungrouped))
            )
        }
        for group in orderedGroups {
            guard let groupTabs = byGroup[group.id], !groupTabs.isEmpty else { continue }
            result.append(
                BrowserTabSection(group: group, tabs: BrowserLibrary.sortedTabs(groupTabs))
            )
        }
        return result
    }

    static func flattened(tabs: [Tab], groups: [TabGroup]) -> [Tab] {
        sections(tabs: tabs, groups: groups).flatMap(\.tabs)
    }
}
