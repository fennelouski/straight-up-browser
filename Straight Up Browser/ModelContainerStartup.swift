import Foundation
import SwiftData

/// The browser prefers its durable/CloudKit store, but a corrupt or unavailable
/// store must not turn launch into an unrecoverable crash. Recovery mode keeps
/// the app usable in memory and tells the user that changes will not persist.
@MainActor
struct ModelContainerStartup {
    let container: ModelContainer?
    let didRecover: Bool
    let errorDescription: String?

    static func recover(
        persistent: () throws -> ModelContainer,
        ephemeral: () throws -> ModelContainer
    ) -> ModelContainerStartup {
        do {
            return ModelContainerStartup(
                container: try persistent(),
                didRecover: false,
                errorDescription: nil
            )
        } catch {
            let persistentError = error
            do {
                return ModelContainerStartup(
                    container: try ephemeral(),
                    didRecover: true,
                    errorDescription: persistentError.localizedDescription
                )
            } catch {
                return ModelContainerStartup(
                    container: nil,
                    didRecover: false,
                    errorDescription: """
                    Persistent store: \(persistentError.localizedDescription)
                    Recovery store: \(error.localizedDescription)
                    """
                )
            }
        }
    }

    static func makeDefault() -> ModelContainerStartup {
        // Two configurations in one container: everything syncs except page
        // archives, which are far too large for CloudKit. A model in the local
        // configuration cannot be the target of a SwiftData relationship from a
        // synced model, which is why the ledger links by UUID throughout.
        let schema = Schema(TabSync.cloudBackedModelTypes + TabSync.localOnlyModelTypes)
        let cloudSchema = Schema(TabSync.cloudBackedModelTypes)
        let localSchema = Schema(TabSync.localOnlyModelTypes)
        let isRunningUnderTests = ProcessInfo.processInfo.arguments.contains("-uiTesting")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
        let persistentConfiguration = ModelConfiguration(
            schema: cloudSchema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: TabSync.cloudKitDatabase
        )
        let archiveConfiguration = ModelConfiguration(
            "LocalArchives",
            schema: localSchema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        let ephemeralConfiguration = ModelConfiguration(
            schema: cloudSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let ephemeralArchiveConfiguration = ModelConfiguration(
            "LocalArchives",
            schema: localSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        // UI-test hosts launch several app instances against the same user
        // container. Keep those instances isolated so SwiftData does not race
        // on the user's persistent store while XCTest is exercising the shell.
        let launchConfigurations = isRunningUnderTests
            ? [ephemeralConfiguration, ephemeralArchiveConfiguration]
            : [persistentConfiguration, archiveConfiguration]
        func makeContainer(configurations: [ModelConfiguration]) throws -> ModelContainer {
            let container = try ModelContainer(
                for: schema,
                configurations: configurations
            )
            NewspaperStore(modelContext: container.mainContext).reconcileInterruptedWork()
            // Idempotent, version-gated data migrations for the research ledger.
            LedgerMigrator(modelContext: container.mainContext).migrateIfNeeded()
            return container
        }
        return recover(
            persistent: {
                try makeContainer(configurations: launchConfigurations)
            },
            ephemeral: {
                try makeContainer(configurations: [ephemeralConfiguration, ephemeralArchiveConfiguration])
            }
        )
    }
}
