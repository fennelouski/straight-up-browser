import Foundation

nonisolated enum PageHandleError: Error, Equatable, Sendable {
    case invalidFormat(String)
}

nonisolated struct PageHandle: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    let windowID: UUID
    let tabID: UUID

    init(windowID: UUID, tabID: UUID) {
        self.windowID = windowID
        self.tabID = tabID
    }

    init(parsing value: String) throws {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let windowID = UUID(uuidString: String(parts[0])),
              let tabID = UUID(uuidString: String(parts[1])) else {
            throw PageHandleError.invalidFormat(value)
        }
        self.init(windowID: windowID, tabID: tabID)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(parsing: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid PageHandle automation address"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    var description: String {
        "\(windowID.uuidString):\(tabID.uuidString)"
    }
}

nonisolated struct PageNavigationGeneration: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    func advanced() -> Self {
        Self(rawValue: rawValue &+ 1)
    }
}

nonisolated struct PageDocumentGeneration: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

nonisolated enum SemanticDOMPathComponent: Codable, Equatable, Hashable, Sendable {
    case sameOriginFrame(localID: String, origin: String?)
    case openShadowRoot(hostLocalID: String)
}

nonisolated struct SemanticFrameContext: Codable, Equatable, Hashable, Sendable {
    static let mainDocument = Self(path: [])

    var path: [SemanticDOMPathComponent]

    init(path: [SemanticDOMPathComponent]) {
        self.path = path
    }
}

nonisolated enum SemanticFrameBoundaryReason: String, Codable, Equatable, Hashable, Sendable {
    case crossOrigin
    case inaccessible
}

nonisolated struct SemanticFrameBoundary: Codable, Equatable, Hashable, Sendable {
    var parentContext: SemanticFrameContext
    var frameLocalID: String
    var sourceURL: URL?
    var reason: SemanticFrameBoundaryReason
}

nonisolated struct SemanticGeometryDigest: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        rawValue = [x, y, width, height]
            .map { String(Int($0.rounded())) }
            .joined(separator: ":")
    }
}

nonisolated enum SemanticElementState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case visible
    case enabled
    case disabled
    case checked
    case selected
    case expanded
    case editable
    case focused
}

nonisolated enum SemanticElementIdentifier: Codable, Equatable, Hashable, Sendable {
    case local(String)
    case legacySub(Int)

    init(parsing value: String) throws {
        if value.hasPrefix("sub-") {
            guard let ordinal = Int(value.dropFirst(4)), ordinal > 0 else {
                throw SemanticReferenceResolutionError.invalidIdentifier(value)
            }
            self = .legacySub(ordinal)
        } else if !value.isEmpty {
            self = .local(value)
        } else {
            throw SemanticReferenceResolutionError.invalidIdentifier(value)
        }
    }

    var compatibilityString: String {
        switch self {
        case .local(let value): value
        case .legacySub(let ordinal): "sub-\(ordinal)"
        }
    }
}

nonisolated struct SemanticElementReference: Codable, Equatable, Hashable, Sendable {
    let page: PageHandle
    let navigationGeneration: PageNavigationGeneration
    let documentGeneration: PageDocumentGeneration
    let identifier: SemanticElementIdentifier
    let role: String
    let name: String
    let states: Set<SemanticElementState>
    let frameContext: SemanticFrameContext
    let geometryDigest: SemanticGeometryDigest

    var localID: String? {
        guard case .local(let value) = identifier else { return nil }
        return value
    }
}

nonisolated struct SemanticNodeSnapshot: Codable, Equatable, Hashable, Sendable {
    var localID: String
    var legacySubID: Int?
    var role: String
    var name: String
    var states: Set<SemanticElementState>
    var frameContext: SemanticFrameContext
    var geometryDigest: SemanticGeometryDigest
    var matchedSelectors: Set<String>
    var text: String

    init(
        localID: String,
        legacySubID: Int? = nil,
        role: String,
        name: String,
        states: Set<SemanticElementState> = [],
        frameContext: SemanticFrameContext = .mainDocument,
        geometryDigest: SemanticGeometryDigest,
        matchedSelectors: Set<String> = [],
        text: String = ""
    ) {
        self.localID = localID
        self.legacySubID = legacySubID
        self.role = role
        self.name = name
        self.states = states
        self.frameContext = frameContext
        self.geometryDigest = geometryDigest
        self.matchedSelectors = matchedSelectors
        self.text = text
    }

    func reference(
        on page: PageHandle,
        navigationGeneration: PageNavigationGeneration,
        documentGeneration: PageDocumentGeneration,
        preferLegacyIdentifier: Bool = false
    ) -> SemanticElementReference {
        let identifier: SemanticElementIdentifier
        if preferLegacyIdentifier, let legacySubID {
            identifier = .legacySub(legacySubID)
        } else {
            identifier = .local(localID)
        }
        return SemanticElementReference(
            page: page,
            navigationGeneration: navigationGeneration,
            documentGeneration: documentGeneration,
            identifier: identifier,
            role: role,
            name: name,
            states: states,
            frameContext: frameContext,
            geometryDigest: geometryDigest
        )
    }
}

nonisolated struct SemanticPageSnapshot: Codable, Equatable, Sendable {
    var page: PageHandle
    var navigationGeneration: PageNavigationGeneration
    var documentGeneration: PageDocumentGeneration
    var nodes: [SemanticNodeSnapshot]
    var inaccessibleFrameBoundaries: [SemanticFrameBoundary]
    var visibleText: String

    init(
        page: PageHandle,
        navigationGeneration: PageNavigationGeneration,
        documentGeneration: PageDocumentGeneration,
        nodes: [SemanticNodeSnapshot],
        inaccessibleFrameBoundaries: [SemanticFrameBoundary] = [],
        visibleText: String = ""
    ) {
        self.page = page
        self.navigationGeneration = navigationGeneration
        self.documentGeneration = documentGeneration
        self.nodes = nodes
        self.inaccessibleFrameBoundaries = inaccessibleFrameBoundaries
        self.visibleText = visibleText
    }
}

nonisolated enum SemanticReferenceResolutionError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case pageChanged(expected: PageHandle, actual: PageHandle)
    case navigationChanged(
        expected: PageNavigationGeneration,
        actual: PageNavigationGeneration
    )
    case documentChanged(
        expected: PageDocumentGeneration,
        actual: PageDocumentGeneration
    )
    case missing(SemanticElementIdentifier)
    case substituted(SemanticElementIdentifier)
    case ambiguous(identifier: SemanticElementIdentifier, matches: Int)
}

nonisolated enum SemanticElementResolver {
    static func resolve(
        _ reference: SemanticElementReference,
        in snapshot: SemanticPageSnapshot
    ) throws -> SemanticNodeSnapshot {
        guard reference.page == snapshot.page else {
            throw SemanticReferenceResolutionError.pageChanged(
                expected: reference.page,
                actual: snapshot.page
            )
        }
        guard reference.navigationGeneration == snapshot.navigationGeneration else {
            throw SemanticReferenceResolutionError.navigationChanged(
                expected: reference.navigationGeneration,
                actual: snapshot.navigationGeneration
            )
        }
        guard reference.documentGeneration == snapshot.documentGeneration else {
            throw SemanticReferenceResolutionError.documentChanged(
                expected: reference.documentGeneration,
                actual: snapshot.documentGeneration
            )
        }

        let identifierMatches = snapshot.nodes.filter { node in
            switch reference.identifier {
            case .local(let localID): node.localID == localID
            case .legacySub(let ordinal): node.legacySubID == ordinal
            }
        }
        guard !identifierMatches.isEmpty else {
            throw SemanticReferenceResolutionError.missing(reference.identifier)
        }
        let matches = identifierMatches.filter {
            $0.frameContext == reference.frameContext
        }
        guard !matches.isEmpty else {
            throw SemanticReferenceResolutionError.substituted(reference.identifier)
        }
        guard matches.count == 1, let node = matches.first else {
            throw SemanticReferenceResolutionError.ambiguous(
                identifier: reference.identifier,
                matches: matches.count
            )
        }
        guard node.role == reference.role,
              node.name == reference.name,
              node.geometryDigest == reference.geometryDigest else {
            throw SemanticReferenceResolutionError.substituted(reference.identifier)
        }
        return node
    }
}
