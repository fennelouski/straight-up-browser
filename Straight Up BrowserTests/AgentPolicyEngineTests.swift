import Foundation
import Testing
@testable import Browser

struct AgentPolicyEngineTests {
    @Test func exactTargetApprovalIsBoundToConcreteInvocation() throws {
        let runID = UUID()
        let page = AgentPageTarget(
            pageID: "window:page",
            origin: "https://example.com",
            session: .normal
        )
        let scope = AgentRunScope(
            capabilities: [.pageRead, .pageScript],
            pageIDs: [page.pageID],
            origins: [page.origin],
            session: .normal
        )
        let context = AgentInvocationContext(
            runID: runID,
            entryPoint: .attended,
            humanPresent: true,
            toolName: "click",
            arguments: .object(["pageId": .string(page.pageID), "selector": .string("#buy")]),
            target: .page(page),
            runScope: scope
        )
        let descriptor = try #require(AgentToolCatalog.canonical.descriptor(named: "click"))
        let engine = AgentPolicyEngine()

        let initial = try engine.evaluate(descriptor: descriptor, context: context)
        guard case .requiresApproval(let request) = initial else {
            Issue.record("External-effect click must require concrete approval")
            return
        }
        let expectedDigest = try AgentInvocationDigest.make(descriptor: descriptor, context: context)
        #expect(request.invocationDigest == expectedDigest)

        let grant = AgentApprovalGrant(
            request: request,
            scope: .exactTargetForRun,
            approvedAt: Date(timeIntervalSince1970: 10),
            expiresAt: Date(timeIntervalSince1970: 100)
        )
        let allowed = try engine.evaluate(
            descriptor: descriptor,
            context: context,
            grants: [grant],
            at: Date(timeIntervalSince1970: 20)
        )
        guard case .allow(let authorization) = allowed else {
            Issue.record("Matching invocation should consume its approval")
            return
        }
        #expect(authorization.invocationDigest == request.invocationDigest)
        #expect(authorization.runID == runID)

        var changed = context
        changed.arguments = .object(["pageId": .string(page.pageID), "selector": .string("#other")])
        let invalidated = try engine.evaluate(
            descriptor: descriptor,
            context: changed,
            grants: [grant],
            at: Date(timeIntervalSince1970: 20)
        )
        guard case .requiresApproval = invalidated else {
            Issue.record("Changed arguments must invalidate an approval")
            return
        }
    }

    @Test func runScopeAndBrowserSessionFailClosed() throws {
        let descriptor = try #require(AgentToolCatalog.canonical.descriptor(named: "take_snapshot"))
        let scope = AgentRunScope(
            capabilities: [.pageRead],
            pageIDs: ["window:approved"],
            origins: ["https://approved.example"],
            session: .normal
        )
        let engine = AgentPolicyEngine()

        func decision(pageID: String, origin: String, session: AgentBrowserSession) throws -> AgentPolicyDecision {
            try engine.evaluate(
                descriptor: descriptor,
                context: AgentInvocationContext(
                    runID: UUID(),
                    entryPoint: .attended,
                    humanPresent: true,
                    toolName: descriptor.name,
                    arguments: .object(["pageId": .string(pageID)]),
                    target: .page(AgentPageTarget(pageID: pageID, origin: origin, session: session)),
                    runScope: scope
                )
            )
        }

        guard case .allow = try decision(
            pageID: "window:approved",
            origin: "https://approved.example",
            session: .normal
        ) else {
            Issue.record("Scoped observation should be allowed")
            return
        }
        #expect(try decision(
            pageID: "window:other",
            origin: "https://approved.example",
            session: .normal
        ).denialCode == .targetOutsideRunScope)
        #expect(try decision(
            pageID: "window:approved",
            origin: "https://approved.example",
            session: .incognito
        ).denialCode == .sessionMismatch)
    }

    @Test func unattendedConsequentialActionsCannotSelfApprove() throws {
        let destructive = try #require(AgentToolCatalog.canonical.descriptor(named: "delete_history_url"))
        let external = try #require(AgentToolCatalog.canonical.descriptor(named: "click"))
        let scope = AgentRunScope(
            capabilities: [.historyWrite, .pageRead, .pageScript],
            pageIDs: ["window:page"],
            origins: ["https://shop.example"],
            session: .normal
        )
        let scheduledDelete = AgentInvocationContext(
            runID: UUID(),
            entryPoint: .scheduled,
            humanPresent: false,
            toolName: destructive.name,
            arguments: .object(["url": .string("https://example.com")]),
            target: .none,
            runScope: scope
        )
        let scheduledClick = AgentInvocationContext(
            runID: UUID(),
            entryPoint: .scheduled,
            humanPresent: false,
            toolName: external.name,
            arguments: .object(["pageId": .string("window:page"), "selector": .string("#submit")]),
            target: .page(AgentPageTarget(
                pageID: "window:page",
                origin: "https://shop.example",
                session: .normal
            )),
            runScope: scope
        )

        #expect(try AgentPolicyEngine().evaluate(
            descriptor: destructive,
            context: scheduledDelete
        ).denialCode == .unattendedConsequentialEffect)
        guard case .requiresHuman = try AgentPolicyEngine().evaluate(
            descriptor: external,
            context: scheduledClick
        ) else {
            Issue.record("An unattended external effect must pause for a human")
            return
        }
    }

    @Test func executorPermitRequiresRecordedPolicyStep() throws {
        let descriptor = try #require(AgentToolCatalog.canonical.descriptor(named: "list_pages"))
        let context = AgentInvocationContext(
            runID: UUID(),
            entryPoint: .localMCP,
            humanPresent: true,
            toolName: descriptor.name,
            arguments: .object([:]),
            target: .none,
            runScope: AgentRunScope(capabilities: [.pageRead])
        )
        let decision = try AgentPolicyEngine().evaluate(descriptor: descriptor, context: context)
        guard case .allow(let authorization) = decision else {
            Issue.record("In-scope observation should be allowed")
            return
        }
        let stepID = UUID()
        let permit = authorization.recording(decisionStepID: stepID)
        #expect(permit.runID == context.runID)
        #expect(permit.toolName == descriptor.name)
        #expect(permit.decisionStepID == stepID)
    }
}

private extension AgentPolicyDecision {
    var denialCode: AgentPolicyDenialCode? {
        guard case .deny(let code, _) = self else { return nil }
        return code
    }
}
