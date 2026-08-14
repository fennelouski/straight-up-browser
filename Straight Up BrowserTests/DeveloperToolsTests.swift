import Testing
@testable import Browser

@MainActor
struct DeveloperToolsTests {
    @Test func networkCategoriesGroupWebKitInitiatorTypes() {
        #expect(DeveloperNetworkCategory.all.matches("other"))
        #expect(DeveloperNetworkCategory.document.matches("document"))
        #expect(!DeveloperNetworkCategory.document.matches("fetch"))
        #expect(DeveloperNetworkCategory.fetch.matches("fetch"))
        #expect(DeveloperNetworkCategory.fetch.matches("xmlhttprequest"))
        #expect(DeveloperNetworkCategory.script.matches("script"))
        #expect(DeveloperNetworkCategory.style.matches("css"))
        #expect(DeveloperNetworkCategory.style.matches("link"))
        #expect(DeveloperNetworkCategory.image.matches("img"))
        #expect(DeveloperNetworkCategory.image.matches("image"))
    }

    @Test func everyDeveloperToolsPlacementHasAPersistableValue() {
        #expect(DeveloperToolsPlacement.allCases.count == 4)
        for placement in DeveloperToolsPlacement.allCases {
            #expect(DeveloperToolsPlacement(rawValue: placement.rawValue) == placement)
            #expect(!placement.title.isEmpty)
        }
    }
}
