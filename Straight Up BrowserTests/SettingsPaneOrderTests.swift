import Foundation
import Testing
@testable import Browser

struct SettingsPaneOrderTests {
    @Test func dragForwardLandsRightAfterTarget() {
        let order: [SettingsPane] = [.general, .agent, .shortcuts, .autofill]
        let result = reorderedSettingsPanes(order, moving: .general, to: .shortcuts)
        #expect(result == [.agent, .shortcuts, .general, .autofill])
    }

    @Test func dragBackwardLandsAtTarget() {
        let order: [SettingsPane] = [.general, .agent, .shortcuts, .autofill]
        let result = reorderedSettingsPanes(order, moving: .autofill, to: .agent)
        #expect(result == [.general, .autofill, .agent, .shortcuts])
    }

    @Test func draggingOntoSelfIsANoOp() {
        let order: [SettingsPane] = [.general, .agent, .shortcuts]
        #expect(reorderedSettingsPanes(order, moving: .agent, to: .agent) == order)
    }
}
