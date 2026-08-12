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
        let schema = Schema(TabSync.cloudBackedModelTypes)
        let isRunningUnderTests = ProcessInfo.processInfo.arguments.contains("-uiTesting")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
        let persistentConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: TabSync.cloudKitDatabase
        )
        let ephemeralConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        // UI-test hosts launch several app instances against the same user
        // container. Keep those instances isolated so SwiftData does not race
        // on the user's persistent store while XCTest is exercising the shell.
        let launchConfiguration = isRunningUnderTests
            ? ephemeralConfiguration
            : persistentConfiguration
        func makeContainer(configuration: ModelConfiguration) throws -> ModelContainer {
            let container = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
            NewspaperStore(modelContext: container.mainContext).reconcileInterruptedWork()
            return container
        }
        return recover(
            persistent: {
                try makeContainer(configuration: launchConfiguration)
            },
            ephemeral: {
                try makeContainer(configuration: ephemeralConfiguration)
            }
        )
    }
}
