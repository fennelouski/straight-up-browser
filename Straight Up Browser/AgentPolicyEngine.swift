import CryptoKit
import Foundation

nonisolated enum AgentBrowserSession: Codable, Equatable, Hashable, Sendable {
    case normal
    case incognito
    case container(UUID)
}

nonisolated struct AgentPageTarget: Codable, Equatable, Sendable {
    var pageID: String
    var origin: String
    var session: AgentBrowserSession
    var elementIdentity: String?

    init(
        pageID: String,
        origin: String,
        session: AgentBrowserSession,
        elementIdentity: String? = nil
    ) {
        self.pageID = pageID
        self.origin = origin
        self.session = session
        self.elementIdentity = elementIdentity
    }
}

nonisolated struct AgentCoworkTarget: Codable, Equatable, Sendable {
    var rootIdentity: String
    var canonicalRelativePath: String
}

nonisolated struct AgentMCPServerTarget: Codable, Equatable, Sendable {
    var connectionID: UUID
    var serverIdentity: String
    var trustVersion: String
    var toolName: String
}

nonisolated enum AgentResolvedTarget: Codable, Equatable, Sendable {
    case none
    case page(AgentPageTarget)
    case cowork(AgentCoworkTarget)
    case mcp(AgentMCPServerTarget)
}

nonisolated struct AgentRunScope: Codable, Equatable, Sendable {
    var capabilities: Set<AgentCapability>
    var pageIDs: Set<String>
    var origins: Set<String>
    var session: AgentBrowserSession
    var coworkRootIdentity: String?
    var mcpServerIdentities: Set<String>
    var preauthorizedScheduledEffects: Set<String>

    init(
        capabilities: Set<AgentCapability>,
        pageIDs: Set<String> = [],
        origins: Set<String> = [],
        session: AgentBrowserSession = .normal,
        coworkRootIdentity: String? = nil,
        mcpServerIdentities: Set<String> = [],
        preauthorizedScheduledEffects: Set<String> = []
    ) {
        self.capabilities = capabilities
        self.pageIDs = pageIDs
        self.origins = origins
        self.session = session
        self.coworkRootIdentity = coworkRootIdentity
        self.mcpServerIdentities = mcpServerIdentities
        self.preauthorizedScheduledEffects = preauthorizedScheduledEffects
    }
}

nonisolated struct AgentInvocationContext: Codable, Equatable, Sendable {
    var runID: UUID
    var entryPoint: AgentRunEntryPoint
    var humanPresent: Bool
    var toolName: String
    var arguments: JSONValue
    var target: AgentResolvedTarget
    var runScope: AgentRunScope
    var dataLeavesDevice: Bool
    var effectSummary: String

    init(
        runID: UUID,
        entryPoint: AgentRunEntryPoint,
        humanPresent: Bool,
        toolName: String,
        arguments: JSONValue,
        target: AgentResolvedTarget,
        runScope: AgentRunScope,
        dataLeavesDevice: Bool = false,
        effectSummary: String = ""
    ) {
        self.runID = runID
        self.entryPoint = entryPoint
        self.humanPresent = humanPresent
        self.toolName = toolName
        self.arguments = arguments
        self.target = target
        self.runScope = runScope
        self.dataLeavesDevice = dataLeavesDevice
        self.effectSummary = effectSummary
    }
}

nonisolated enum AgentInvocationDigest {
    private struct DigestInput: Encodable {
        let runID: UUID
        let toolName: String
        let toolVersion: Int
        let schema: JSONValue
        let arguments: JSONValue
        let target: AgentResolvedTarget
        let dataLeavesDevice: Bool
    }

    static func make(
        descriptor: AgentToolDescriptor,
        context: AgentInvocationContext
    ) throws -> String {
        let input = DigestInput(
            runID: context.runID,
            toolName: descriptor.name,
            toolVersion: descriptor.version,
            schema: descriptor.inputSchema.jsonValue,
            arguments: context.arguments,
            target: context.target,
            dataLeavesDevice: context.dataLeavesDevice
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(input))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum AgentApprovalScope: String, Codable, Equatable, Sendable {
    case allowOnce
    case exactTargetForRun
}

nonisolated struct AgentApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let runID: UUID
    let invocationDigest: String
    let toolName: String
    let risk: AgentToolRisk
    let normalizedArguments: JSONValue
    let target: AgentResolvedTarget
    let effectSummary: String
    let dataLeavesDevice: Bool
    let createdAt: Date
    let expiresAt: Date
    let availableScopes: Set<AgentApprovalScope>
}

nonisolated struct AgentApprovalGrant: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let requestID: UUID
    let runID: UUID
    let invocationDigest: String
    let target: AgentResolvedTarget
    let scope: AgentApprovalScope
    let approvedAt: Date
    let expiresAt: Date
    var consumedAt: Date?

    init(
        id: UUID = UUID(),
        request: AgentApprovalRequest,
        scope: AgentApprovalScope,
        approvedAt: Date,
        expiresAt: Date,
        consumedAt: Date? = nil
    ) {
        self.id = id
        requestID = request.id
        runID = request.runID
        invocationDigest = request.invocationDigest
        target = request.target
        self.scope = scope
        self.approvedAt = approvedAt
        self.expiresAt = min(expiresAt, request.expiresAt)
        self.consumedAt = consumedAt
    }

    func authorizes(
        context: AgentInvocationContext,
        invocationDigest: String,
        at date: Date
    ) -> Bool {
        guard runID == context.runID,
              self.invocationDigest == invocationDigest,
              target == context.target,
              approvedAt <= date,
              date < expiresAt else { return false }
        return scope != .allowOnce || consumedAt == nil
    }
}

nonisolated struct AgentPolicyAuthorization: Codable, Equatable, Sendable {
    let runID: UUID
    let toolName: String
    let invocationDigest: String
    let grantID: UUID?
    let rationale: String

    func recording(decisionStepID: UUID) -> AgentExecutionPermit {
        AgentExecutionPermit(
            runID: runID,
            toolName: toolName,
            invocationDigest: invocationDigest,
            decisionStepID: decisionStepID
        )
    }
}

/// The only value accepted at an executor boundary. It can only be obtained by
/// attaching a persisted policy-decision step to an allow authorization.
nonisolated struct AgentExecutionPermit: Codable, Equatable, Sendable {
    let runID: UUID
    let toolName: String
    let invocationDigest: String
    let decisionStepID: UUID
}

nonisolated enum AgentPolicyDenialCode: String, Codable, Equatable, Sendable {
    case unknownTool
    case invalidArguments
    case capabilityOutsideRunScope
    case targetOutsideRunScope
    case sessionMismatch
    case unattendedConsequentialEffect
    case prohibitedDataEgress
}

nonisolated enum AgentPolicyDecision: Codable, Equatable, Sendable {
    case allow(AgentPolicyAuthorization)
    case deny(code: AgentPolicyDenialCode, reason: String)
    case requiresApproval(AgentApprovalRequest)
    case requiresHuman(AgentApprovalRequest)
}

nonisolated struct AgentPolicyEngine: Sendable {
    var approvalLifetime: TimeInterval

    init(approvalLifetime: TimeInterval = 10 * 60) {
        self.approvalLifetime = approvalLifetime
    }

    func evaluate(
        descriptor: AgentToolDescriptor,
        context: AgentInvocationContext,
        grants: [AgentApprovalGrant] = [],
        at date: Date = Date()
    ) throws -> AgentPolicyDecision {
        guard descriptor.name == context.toolName else {
            return .deny(code: .unknownTool, reason: "Tool identity does not match the resolved descriptor.")
        }
        let argumentErrors = descriptor.inputSchema.validationErrors(for: context.arguments)
        guard argumentErrors.isEmpty else {
            return .deny(code: .invalidArguments, reason: argumentErrors.joined(separator: "; "))
        }
        guard descriptor.requiredCapabilities.isSubset(of: context.runScope.capabilities) else {
            return .deny(
                code: .capabilityOutsideRunScope,
                reason: "The invocation requires capabilities not granted to this run."
            )
        }
        if let targetDenial = validateTarget(context.target, scope: context.runScope) {
            return targetDenial
        }
        if context.dataLeavesDevice,
           case .page(let page) = context.target,
           page.session == .incognito {
            return .deny(
                code: .prohibitedDataEgress,
                reason: "Incognito page data cannot leave the browser without a separately scoped attended flow."
            )
        }

        let digest = try AgentInvocationDigest.make(descriptor: descriptor, context: context)
        if let grant = grants.first(where: {
            $0.authorizes(context: context, invocationDigest: digest, at: date)
        }) {
            return .allow(AgentPolicyAuthorization(
                runID: context.runID,
                toolName: descriptor.name,
                invocationDigest: digest,
                grantID: grant.id,
                rationale: "Matching, unexpired \(grant.scope.rawValue) approval."
            ))
        }

        switch descriptor.risk {
        case .observe:
            return .allow(defaultAuthorization(
                descriptor: descriptor,
                context: context,
                digest: digest,
                rationale: "Observation is within the explicit run scope."
            ))
        case .navigate:
            if context.entryPoint == .scheduled,
               !context.runScope.preauthorizedScheduledEffects.contains(digest) {
                return .requiresHuman(makeRequest(
                    descriptor: descriptor,
                    context: context,
                    digest: digest,
                    at: date
                ))
            }
            return .allow(defaultAuthorization(
                descriptor: descriptor,
                context: context,
                digest: digest,
                rationale: "Navigation target is within the explicit run scope."
            ))
        case .mutateLocal, .externalEffect:
            if context.entryPoint == .scheduled || !context.humanPresent {
                return .requiresHuman(makeRequest(
                    descriptor: descriptor,
                    context: context,
                    digest: digest,
                    at: date
                ))
            }
            return .requiresApproval(makeRequest(
                descriptor: descriptor,
                context: context,
                digest: digest,
                at: date
            ))
        case .destructive:
            guard context.entryPoint != .scheduled, context.humanPresent else {
                return .deny(
                    code: .unattendedConsequentialEffect,
                    reason: "Destructive effects require an attended confirmation."
                )
            }
            return .requiresApproval(makeRequest(
                descriptor: descriptor,
                context: context,
                digest: digest,
                at: date
            ))
        }
    }

    private func defaultAuthorization(
        descriptor: AgentToolDescriptor,
        context: AgentInvocationContext,
        digest: String,
        rationale: String
    ) -> AgentPolicyAuthorization {
        AgentPolicyAuthorization(
            runID: context.runID,
            toolName: descriptor.name,
            invocationDigest: digest,
            grantID: nil,
            rationale: rationale
        )
    }

    private func makeRequest(
        descriptor: AgentToolDescriptor,
        context: AgentInvocationContext,
        digest: String,
        at date: Date
    ) -> AgentApprovalRequest {
        AgentApprovalRequest(
            id: UUID(),
            runID: context.runID,
            invocationDigest: digest,
            toolName: descriptor.name,
            risk: descriptor.risk,
            normalizedArguments: context.arguments,
            target: context.target,
            effectSummary: context.effectSummary.isEmpty ? descriptor.description : context.effectSummary,
            dataLeavesDevice: context.dataLeavesDevice,
            createdAt: date,
            expiresAt: date.addingTimeInterval(approvalLifetime),
            availableScopes: [.allowOnce, .exactTargetForRun]
        )
    }

    private func validateTarget(
        _ target: AgentResolvedTarget,
        scope: AgentRunScope
    ) -> AgentPolicyDecision? {
        switch target {
        case .none:
            return nil
        case .page(let page):
            guard page.session == scope.session else {
                return .deny(code: .sessionMismatch, reason: "Page and run browser Sessions differ.")
            }
            guard scope.pageIDs.contains(page.pageID), scope.origins.contains(page.origin) else {
                return .deny(code: .targetOutsideRunScope, reason: "Page or origin is outside the run scope.")
            }
        case .cowork(let file):
            guard file.rootIdentity == scope.coworkRootIdentity,
                  Self.isSafeRelativePath(file.canonicalRelativePath) else {
                return .deny(code: .targetOutsideRunScope, reason: "File is outside the approved Cowork root.")
            }
        case .mcp(let server):
            guard scope.mcpServerIdentities.contains(server.serverIdentity) else {
                return .deny(code: .targetOutsideRunScope, reason: "MCP server identity is outside the run scope.")
            }
        }
        return nil
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}
