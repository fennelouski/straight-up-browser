import Foundation
#if os(macOS)
import Security
#endif

/// Reads the entitlements that are effective for the running process. CloudKit
/// raises an Objective-C exception (rather than a Swift error) when a container
/// is resolved without its entitlement, so callers must fail closed before
/// constructing `CKContainer`.
nonisolated enum CloudKitEntitlements {
    static let containerIdentifiersKey =
        "com.apple.developer.icloud-container-identifiers"

    static func effectiveContainerIdentifiers() -> Set<String> {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task,
                  containerIdentifiersKey as CFString,
                  nil
              )
        else {
            return []
        }

        if let identifiers = value as? [String] {
            return Set(identifiers)
        }
        if let identifier = value as? String {
            return [identifier]
        }
        return []
        #else
        #if targetEnvironment(simulator)
        // Simulator apps are ad-hoc signed without the iCloud entitlement even
        // when the device archive is correctly provisioned. Treat CloudKit as
        // unavailable so settings and test hosts never cross the synchronous
        // CKContainer exception boundary.
        return []
        #else
        // iOS doesn't publish SecTask entitlement inspection. The mobile Info
        // plist mirrors the allowed identifiers, while the release gate checks
        // this declaration against both the archive's effective signature and
        // embedded App Store provisioning profile before export. Installable
        // device builds are necessarily signed, so a missing entitlement is
        // caught during install/export before this declaration is trusted.
        return Set(
            Bundle.main.object(
                forInfoDictionaryKey: "SUCloudKitContainerIdentifiers"
            ) as? [String] ?? []
        )
        #endif
        #endif
    }

    static func permits(
        _ containerIdentifier: String,
        effectiveIdentifiers: Set<String>? = nil
    ) -> Bool {
        (effectiveIdentifiers ?? effectiveContainerIdentifiers())
            .contains(containerIdentifier)
    }
}
