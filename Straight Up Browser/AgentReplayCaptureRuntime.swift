import Foundation

#if os(macOS)
/// A bounded, already-encoded visible-viewport image supplied by the browser
/// host. It carries only origin-level location metadata; paths, queries, DOM,
/// and response bodies never enter the replay manifest.
nonisolated struct AgentReplayCapturedFrame: Sendable {
    let data: Data
    let contentType: String
    let target: AgentPageTarget
    let viewport: AgentReplayViewport

    init(
        data: Data,
        contentType: String = "image/png",
        target: AgentPageTarget,
        viewport: AgentReplayViewport
    ) {
        self.data = data
        self.contentType = contentType
        self.target = target
        self.viewport = viewport
    }
}

/// Wraps one already-authorized page operation with policy-controlled replay
/// capture. Capture is strictly best-effort: an unavailable page, storage
/// failure, cancellation, or a disallowed policy position never delays or
/// changes the requested browser effect.
@MainActor
enum AgentReplayCaptureCoordinator {
    static func around<Result>(
        descriptor: AgentToolDescriptor,
        authorizedBinding: BrowserAutomationPageDispatchBinding,
        permit: AgentExecutionPermit,
        capture: (
            BrowserAutomationPageDispatchBinding
        ) async -> AgentReplayCapturedFrame?,
        operationSucceeded: (Result) -> Bool,
        resolvePostOperationBinding: () async -> BrowserAutomationPageDispatchBinding?,
        store providedStore: AgentRunStore? = nil,
        meter providedMeter: AgentRunMeter? = nil,
        operation: () async -> Result
    ) async -> Result {
        let authorizedTarget = authorizedBinding.target
        let store = providedStore ?? (try? AgentRunStoreRegistry.store(
            baseDirectory: BrowserCLI.supportDirectory
        ))
        let meter: AgentRunMeter?
        if let providedMeter {
            meter = providedMeter
        } else {
            meter = await AgentRunMeterRegistry.shared.meter(for: permit.runID)
        }
        guard descriptor.name == permit.toolName,
              let invocationStepID = permit.invocationStepID,
              authorizedTarget.session != .incognito,
              let page = try? PageHandle(parsing: authorizedTarget.pageID),
              let store,
              let meter,
              let run = await store.run(id: permit.runID),
              !run.incognito else {
            return await operation()
        }

        let positions = AgentReplayCapturePolicy().positions(
            for: run,
            descriptor: descriptor,
            page: authorizedTarget
        )
        guard !positions.isEmpty,
              let steps = try? await store.steps(runID: permit.runID),
              steps.contains(where: { step in
                  step.id == invocationStepID
                      && step.kind == .toolInvocation
                      && step.policyDecisionStepID == permit.decisionStepID
                      && toolName(in: step) == permit.toolName
              }) else {
            return await operation()
        }

        // Do not make the pre-effect frame durable yet. Dispatch performs its
        // own immediate authority revalidation; retaining only after a proven
        // successful result prevents a same-URL replacement document from
        // leaving replay evidence when the effect itself was rejected.
        var beforeFrame: AgentReplayCapturedFrame?
        if positions.contains(.beforeMutation), !Task.isCancelled {
            beforeFrame = await capture(authorizedBinding)
        }

        let result = await operation()
        guard operationSucceeded(result) else { return result }

        if let beforeFrame, !Task.isCancelled {
            await retain(
                beforeFrame,
                expectedPage: page,
                position: .beforeMutation,
                runID: permit.runID,
                invocationStepID: invocationStepID,
                meter: meter,
                store: store
            )
        }

        if positions.contains(.afterMutation), !Task.isCancelled,
           let postBinding = await resolvePostOperationBinding(),
           postBinding.target.session != .incognito,
           let postPage = try? PageHandle(parsing: postBinding.target.pageID),
           postPage == page,
           let frame = await capture(postBinding) {
            await retain(
                frame,
                expectedPage: page,
                position: .afterMutation,
                runID: permit.runID,
                invocationStepID: invocationStepID,
                meter: meter,
                store: store
            )
        }
        return result
    }

    private static func retain(
        _ captured: AgentReplayCapturedFrame,
        expectedPage: PageHandle,
        position: AgentReplayCapturePosition,
        runID: UUID,
        invocationStepID: UUID,
        meter: AgentRunMeter,
        store: AgentRunStore
    ) async {
        guard captured.target.session != .incognito,
              let capturedPage = try? PageHandle(parsing: captured.target.pageID),
              capturedPage == expectedPage,
              canonicalOrigin(captured.target.origin) == captured.target.origin else {
            return
        }
        let artifactID = UUID()
        let metadata = AgentReplayFrameMetadata(
            artifactID: artifactID,
            pageHandle: capturedPage,
            urlOrigin: captured.target.origin,
            viewport: captured.viewport,
            capturePosition: position
        )
        switch await meter.admitArtifact(
            runID: runID,
            bytes: captured.data.count
        ) {
        case .admitted:
            _ = try? await store.persistReplayFrame(
                id: artifactID,
                runID: runID,
                sourceStepID: invocationStepID,
                contentType: captured.contentType,
                data: captured.data,
                metadata: metadata
            )
        case .limited(let limit):
            await appendLimitEvidence(limit, to: store)
        case .cancelled, .interrupted:
            break
        }
    }

    private static func appendLimitEvidence(
        _ limit: AgentLimitResult,
        to store: AgentRunStore
    ) async {
        guard let steps = try? await store.steps(runID: limit.runID),
              !steps.contains(where: { step in
                  guard step.kind == .limit,
                        case .object(let payload) = step.payload,
                        case .string(let dimension) = payload["dimension"] else {
                      return false
                  }
                  return dimension == limit.dimension.rawValue
                      && step.summary == limit.summary
              }) else { return }
        _ = try? await store.appendStep(
            runID: limit.runID,
            kind: .limit,
            summary: limit.summary,
            payload: .object([
                "dimension": .string(limit.dimension.rawValue),
                "scope": .string(limit.scope.safeReplayLabel),
                "reason": .string(limit.reason.rawValue),
                "current": limit.current.map { .number(Double($0)) } ?? .null,
                "attempted": limit.attempted.map { .number(Double($0)) } ?? .null,
                "maximum": limit.maximum.map { .number(Double($0)) } ?? .null,
            ]),
            redactionState: .metadataOnly,
            at: limit.occurredAt
        )
    }

    private static func toolName(in step: AgentStep) -> String {
        if case .object(let payload) = step.payload,
           case .string(let name) = payload["tool"] {
            return name
        }
        return step.summary
    }

    private static func canonicalOrigin(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }
        var result = "\(scheme)://\(host)"
        if let port = components.port { result += ":\(port)" }
        return result
    }
}

private nonisolated extension AgentBudgetLimitScope {
    var safeReplayLabel: String {
        switch self {
        case .run: "run"
        case .taskDefinition: "taskDefinition"
        case .runGroup: "runGroup"
        }
    }
}
#endif
