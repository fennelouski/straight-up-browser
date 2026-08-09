import Foundation

@main
struct GenerateAgentToolCatalog {
    static func main() throws {
        FileHandle.standardOutput.write(try AgentToolCatalog.canonical.mcpSnapshotData())
    }
}
