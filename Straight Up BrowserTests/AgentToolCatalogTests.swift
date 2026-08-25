import Foundation
import Testing
@testable import Browser

struct AgentToolCatalogTests {
    private let compatibilityNames = [
        "get_active_page", "list_pages", "navigate_page", "new_page",
        "new_hidden_page", "show_page", "move_page", "close_page",
        "take_snapshot", "take_enhanced_snapshot", "get_page_content",
        "get_page_links", "get_dom", "search_dom", "take_screenshot",
        "evaluate_script", "click", "click_at", "hover", "focus", "fill",
        "clear", "check", "uncheck", "select_option", "press_key", "drag",
        "scroll", "upload_file", "handle_dialog", "save_pdf",
        "save_screenshot", "download_file", "list_windows", "create_window",
        "create_hidden_window", "close_window", "activate_window",
        "list_tab_groups", "group_tabs", "update_tab_group", "ungroup_tabs",
        "close_tab_group", "get_bookmarks", "create_bookmark",
        "remove_bookmark", "update_bookmark", "move_bookmark",
        "search_bookmarks", "search_history", "get_recent_history",
        "delete_history_url", "delete_history_range",
    ]

    @Test func compatibilityProfileIsTheDocumented53ToolContract() throws {
        let catalog = AgentToolCatalog.canonical
        try catalog.validate()

        let descriptors = catalog.descriptors(visibleIn: .browserOSMCP)
        #expect(descriptors.map(\.name) == compatibilityNames)
        #expect(descriptors.count == 53)
        #expect(Set(descriptors.map(\.name)).count == 53)
        #expect(descriptors.allSatisfy { !$0.requiredCapabilities.isEmpty })
        #expect(descriptors.allSatisfy { $0.version == 1 })
    }

    @Test func builtInAndMCPRenderingsShareDescriptors() throws {
        let catalog = AgentToolCatalog.canonical
        let builtIn = catalog.descriptors(visibleIn: .builtInAgent)
        let mcp = Dictionary(uniqueKeysWithValues: catalog
            .descriptors(visibleIn: .browserOSMCP)
            .map { ($0.name, $0) })

        #expect(builtIn.count == 46)
        #expect(builtIn.contains { $0.name == "search_research" })
        #expect(builtIn.contains { $0.name == "wait_for" })
        #expect(builtIn.contains { $0.name == "observe_webkit_signals" })
        #expect(builtIn.contains { $0.name == "wait_for_webkit_signal" })
        #expect(builtIn.contains { $0.name == "delegate_child_run" })
        #expect(builtIn.contains { $0.name == "inspect_run_group" })
        #expect(builtIn.contains { $0.name == "cancel_child_run" })
        #expect(builtIn.contains { $0.name == "commit_cowork_transaction" })
        #expect(builtIn.contains { $0.name == "cancel_cowork_transaction" })
        #expect(builtIn.contains { $0.name == "rollback_cowork_transaction" })
        #expect(builtIn.contains { $0.name == "propose_agent_memory" })
        #expect(builtIn.contains { $0.name == "search_agent_memory" })
        #expect(builtIn.contains { $0.name == "forget_agent_memory" })
        #expect(catalog.descriptor(named: "wait_for_page")?.name == "wait_for")
        #expect(builtIn.contains { $0.name == "write_file" })
        for descriptor in builtIn where mcp[descriptor.name] != nil {
            #expect(mcp[descriptor.name] == descriptor)
        }

        let openAI = try catalog.openAIFunctionTools(profile: .builtInAgent)
        let mcpTools = try catalog.mcpTools(profile: .browserOSMCP)
        #expect(openAI.count == builtIn.count)
        #expect(mcpTools.count == compatibilityNames.count)
        #expect(mcpTools.count == 53)
        #expect(!mcpTools.contains { ($0["name"] as? String) == "delegate_child_run" })
    }

    @Test func catalogValidationRejectsContractAmbiguity() {
        let base = AgentToolCatalog.canonical.descriptors(visibleIn: .browserOSMCP)[0]

        #expect(throws: AgentToolCatalog.ValidationError.self) {
            try AgentToolCatalog(descriptors: [base, base]).validate()
        }
        #expect(throws: AgentToolCatalog.ValidationError.self) {
            try AgentToolCatalog(
                descriptors: [base],
                aliases: [AgentToolAlias(name: "old_name", targetName: "missing")]
            ).validate()
        }
        var missingCapability = base
        missingCapability.requiredCapabilities = []
        #expect(throws: AgentToolCatalog.ValidationError.self) {
            try AgentToolCatalog(descriptors: [missingCapability]).validate()
        }
        var unsupported = base
        unsupported.inputSchema = .unsupported(keyword: "oneOf")
        #expect(throws: AgentToolCatalog.ValidationError.self) {
            try AgentToolCatalog(descriptors: [unsupported]).validate()
        }
    }

    @Test func schemaValidationHonorsRequiredEnumsAndAdditionalProperties() throws {
        let navigate = try #require(AgentToolCatalog.canonical.descriptor(named: "navigate_page"))
        #expect(navigate.inputSchema.validationErrors(for: .object([
            "action": .string("reload"),
        ])).isEmpty)
        #expect(!navigate.inputSchema.validationErrors(for: .object([
            "action": .string("launch"),
        ])).isEmpty)
        #expect(!navigate.inputSchema.validationErrors(for: .object([
            "surprise": .boolean(true),
        ])).isEmpty)

        let fill = try #require(AgentToolCatalog.canonical.descriptor(named: "fill"))
        #expect(!fill.inputSchema.validationErrors(for: .object([:])).isEmpty)
        #expect(fill.inputSchema.validationErrors(for: .object([
            "value": .string("hello"),
        ])).isEmpty)
    }

    @Test func checkedInMCPGoldenMatchesCanonicalRenderer() throws {
        let expected = try TestFixture.data("agent-tool-catalog-mcp.json")
        let rendered = try AgentToolCatalog.canonical.mcpSnapshotData()
        #expect(rendered == expected)
    }
}
