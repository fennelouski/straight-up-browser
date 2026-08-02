import Foundation
import Combine
import WebKit

enum SitePermissionKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case camera
    case microphone

    var id: Self { self }

    var title: String {
        switch self {
        case .camera: String(localized: "Camera")
        case .microphone: String(localized: "Microphone")
        }
    }

    var systemImage: String {
        switch self {
        case .camera: "video"
        case .microphone: "mic"
        }
    }
}

enum SitePermissionDecision: String, Codable, Hashable {
    case allowed
    case denied

    var title: String {
        switch self {
        case .allowed: String(localized: "Allowed")
        case .denied: String(localized: "Blocked")
        }
    }

    var webKitDecision: WKPermissionDecision {
        switch self {
        case .allowed: .grant
        case .denied: .deny
        }
    }
}

struct SitePermissionRecord: Codable, Equatable, Identifiable {
    let origin: String
    let kind: SitePermissionKind
    var decision: SitePermissionDecision
    var updatedAt: Date

    var id: String { "\(origin)|\(kind.rawValue)" }
}

enum SitePermissionOrigin {
    static func canonical(
        scheme: String,
        host: String,
        port: Int
    ) -> String {
        let normalizedScheme = scheme.lowercased()
        let normalizedHost = host.lowercased()
        let isDefaultPort = (normalizedScheme == "https" && port == 443)
            || (normalizedScheme == "http" && port == 80)
        let portSuffix = port > 0 && !isDefaultPort ? ":\(port)" : ""
        return "\(normalizedScheme)://\(normalizedHost)\(portSuffix)"
    }

    static func canonical(_ origin: WKSecurityOrigin) -> String {
        canonical(
            scheme: origin.protocol,
            host: origin.host,
            port: origin.port
        )
    }
}

extension WKMediaCaptureType {
    var sitePermissionKinds: Set<SitePermissionKind> {
        switch self {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        @unknown default: [.camera, .microphone]
        }
    }
}

@MainActor
final class SitePermissionStore: ObservableObject {
    static let shared = SitePermissionStore()

    @Published private(set) var records: [SitePermissionRecord] = []

    private let defaults: UserDefaults
    private let storageKey = "sitePermissionRecords"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func decision(
        for kinds: Set<SitePermissionKind>,
        origin: String
    ) -> SitePermissionDecision? {
        guard !kinds.isEmpty else { return nil }
        let decisions = kinds.compactMap { kind in
            records.first {
                $0.origin == origin && $0.kind == kind
            }?.decision
        }
        guard decisions.count == kinds.count,
              Set(decisions).count == 1 else { return nil }
        return decisions[0]
    }

    func set(
        _ decision: SitePermissionDecision,
        for kinds: Set<SitePermissionKind>,
        origin: String,
        now: Date = Date()
    ) {
        for kind in kinds {
            if let index = records.firstIndex(where: {
                $0.origin == origin && $0.kind == kind
            }) {
                records[index].decision = decision
                records[index].updatedAt = now
            } else {
                records.append(
                    SitePermissionRecord(
                        origin: origin,
                        kind: kind,
                        decision: decision,
                        updatedAt: now
                    )
                )
            }
        }
        sortRecords()
        save()
    }

    func revoke(origin: String, kind: SitePermissionKind) {
        records.removeAll {
            $0.origin == origin && $0.kind == kind
        }
        save()
        NotificationCenter.default.post(
            name: .sitePermissionsChanged,
            object: nil
        )
    }

    func clear() {
        records.removeAll()
        defaults.removeObject(forKey: storageKey)
        NotificationCenter.default.post(
            name: .sitePermissionsChanged,
            object: nil
        )
    }

    private func sortRecords() {
        records.sort {
            if $0.origin != $1.origin { return $0.origin < $1.origin }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            records = try JSONDecoder().decode(
                [SitePermissionRecord].self,
                from: data
            )
            sortRecords()
        } catch {
            Logger.log(
                "Site permission ledger couldn't be decoded: \(error)",
                type: "Permissions"
            )
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            defaults.set(data, forKey: storageKey)
        } catch {
            Logger.log(
                "Site permission ledger couldn't be saved: \(error)",
                type: "Permissions"
            )
        }
    }
}
