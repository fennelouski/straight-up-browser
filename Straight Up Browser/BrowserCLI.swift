//
//  BrowserCLI.swift
//  Straight Up Browser
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation

// MARK: - Structured agent automation

nonisolated enum BrowserAutomationCompletionKind: String, Equatable, Sendable {
    case succeeded
    case failed
    case malformed
    case timedOut
}

/// Classifies the transient browser response without retaining its body in the
/// durable run record. The raw bytes exist only long enough to return them to
/// the MCP caller, then both response files are removed.
nonisolated struct BrowserAutomationInvocationResult: Equatable, Sendable {
    let kind: BrowserAutomationCompletionKind
    let responseData: Data

    init(responseData: Data) {
        self.responseData = responseData
        guard let object = try? JSONSerialization.jsonObject(with: responseData),
              let dictionary = object as? [String: Any] else {
            kind = .malformed
            return
        }
        if dictionary["error"] != nil || dictionary["ok"] as? Bool == false {
            kind = .failed
        } else {
            kind = .succeeded
        }
    }

    static func generated(
        kind: BrowserAutomationCompletionKind,
        message: String
    ) -> Self {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": message]))
            ?? Data(#"{"error":"Browser automation failed."}"#.utf8)
        return Self(kind: kind, responseData: data)
    }

    private init(kind: BrowserAutomationCompletionKind, responseData: Data) {
        self.kind = kind
        self.responseData = responseData
    }

    var durableMetadata: JSONValue {
        .object([
            "completion": .string(kind.rawValue),
            "responseBodyRetained": .boolean(false),
        ])
    }
}

nonisolated struct BrowserAutomationPageAuthoritySnapshot: Equatable, Sendable {
    let target: AgentPageTarget
    /// Unforgeable identity created in the browser's isolated semantic world.
    /// A same-URL reload creates a different generation.
    let document: PageDocumentGeneration
}

nonisolated enum BrowserAutomationPageBindingError: Error, Equatable, Sendable {
    case missingOrStaleTarget
    case pageMismatch
    case incognitoDenied
    case sessionMismatch
    case originMismatch
    case versionMismatch
}

/// Immutable authority evidence captured at policy time and revalidated against
/// the host's live Page immediately before local-MCP dispatch.
nonisolated struct BrowserAutomationPageDispatchBinding: Equatable, Sendable {
    let target: AgentPageTarget
    let version: AgentPageLeaseVersion

    func validate(
        live binding: BrowserAutomationPageDispatchBinding?,
        allowIncognito: Bool = false
    ) throws {
        guard let binding else {
            throw BrowserAutomationPageBindingError.missingOrStaleTarget
        }
        guard target.pageID == binding.target.pageID else {
            throw BrowserAutomationPageBindingError.pageMismatch
        }
        guard allowIncognito
                || (target.session != .incognito && binding.target.session != .incognito) else {
            throw BrowserAutomationPageBindingError.incognitoDenied
        }
        guard target.session == binding.target.session else {
            throw BrowserAutomationPageBindingError.sessionMismatch
        }
        guard target.origin == binding.target.origin else {
            throw BrowserAutomationPageBindingError.originMismatch
        }
        guard version == binding.version else {
            throw BrowserAutomationPageBindingError.versionMismatch
        }
    }
}

/// Routes structured agent requests to the browser window that owns the target
/// page.  The original CLI predates multi-window automation and broadcasts
/// NotificationCenter messages, which means two open browser windows can both
/// react to one command.  MCP uses this registry instead: page IDs include the
/// owning window ID, so parallel clients never have to steal the user's focus
/// just to address a background page.
final class BrowserAutomationRegistry {
    static let shared = BrowserAutomationRegistry()

    private final class WeakManager {
        weak var value: NotificationManager?
        init(_ value: NotificationManager) { self.value = value }
    }

    private var managers: [UUID: WeakManager] = [:]
    private struct PageAuthorityState {
        let document: PageDocumentGeneration
        let target: AgentPageTarget
        let version: AgentPageLeaseVersion
    }
    private var pageAuthorityStates: [PageHandle: PageAuthorityState] = [:]

    private init() {}

    func register(_ manager: NotificationManager) {
        managers[manager.automationWindowId] = WeakManager(manager)
    }

    func unregister(_ manager: NotificationManager) {
        managers.removeValue(forKey: manager.automationWindowId)
    }

    private func liveManagers() -> [NotificationManager] {
        managers = managers.filter { $0.value.value != nil }
        return managers.values.compactMap(\.value)
    }

    var hasLiveManagers: Bool { !liveManagers().isEmpty }

    private func manager(windowId: String?, pageId: String?) -> NotificationManager? {
        let live = liveManagers()
        if let windowId {
            guard let id = UUID(uuidString: windowId), let manager = managers[id]?.value else {
                return nil
            }
            return manager
        }
        if let pageId {
            guard let prefix = pageId.split(separator: ":", maxSplits: 1).first,
                  let id = UUID(uuidString: String(prefix)),
                  let manager = managers[id]?.value else {
                return nil
            }
            return manager
        }
        return live.first(where: \.isAutomationKeyWindow) ?? live.first
    }

    static func externallyVisiblePageSummaries(
        _ pages: [[String: Any]]
    ) -> [[String: Any]] {
        pages.compactMap { page in
            guard page["incognito"] as? Bool != true,
                  (page["sessionKind"] as? String)?.lowercased() != "incognito" else {
                return nil
            }
            var safe = page
            // Do not expose a privacy-mode discriminator through local MCP,
            // even with a false value. Private Pages are omitted altogether.
            safe.removeValue(forKey: "incognito")
            return safe
        }
    }

    static func externallyVisibleWindowSummary(
        _ summary: [String: Any],
        pages: [[String: Any]]
    ) -> [String: Any]? {
        let visiblePages = externallyVisiblePageSummaries(pages)
        guard !visiblePages.isEmpty else { return nil }
        var safe = summary
        safe["title"] = "Browser"
        safe["pageCount"] = visiblePages.count
        return safe
    }

    func execute(
        _ request: [String: Any],
        responseFilePath: String?,
        permit: AgentExecutionPermit? = nil,
        authorizedPageBindings: [BrowserAutomationPageDispatchBinding] = [],
        authorizedToolName: String? = nil
    ) {
        guard let tool = request["tool"] as? String else {
            BrowserCLI.writeResponse(["error": "agent request is missing tool"], to: responseFilePath)
            return
        }
        if let permit {
            let policyToolName = authorizedToolName ?? tool
            guard permit.toolName == policyToolName,
                  let descriptor = AgentToolCatalog.canonical.descriptor(
                      named: policyToolName
                  ) else {
                BrowserCLI.writeResponse(
                    ["error": "policy authorization does not match requested tool"],
                    to: responseFilePath
                )
                return
            }
            if descriptor.requiresLivePageTarget {
                guard !authorizedPageBindings.isEmpty else {
                    BrowserCLI.writeResponse(
                        ["error": "authorized Page binding is required"],
                        to: responseFilePath
                    )
                    return
                }
                Task { [weak self] in
                    await self?.performAuthorizedAfterLivePageValidation(
                        request,
                        descriptor: descriptor,
                        authorizedPageBindings: authorizedPageBindings,
                        responseFilePath: responseFilePath
                    )
                }
                return
            }
            performAuthorized(request, responseFilePath: responseFilePath)
            return
        }
        Task { [weak self] in
            await self?.authorizeExternalInvocation(request, responseFilePath: responseFilePath)
        }
    }

    private func performAuthorizedAfterLivePageValidation(
        _ request: [String: Any],
        descriptor: AgentToolDescriptor,
        authorizedPageBindings: [BrowserAutomationPageDispatchBinding],
        responseFilePath: String?
    ) async {
        let arguments = request["arguments"] as? [String: Any] ?? [:]
        let requestedPageIDs: [String]
        if descriptor.acceptsMultiplePageTargets {
            requestedPageIDs = arguments["pageIds"] as? [String] ?? []
        } else if let requested = arguments["pageId"] as? String {
            requestedPageIDs = [requested]
        } else if authorizedPageBindings.count == 1 {
            requestedPageIDs = [authorizedPageBindings[0].target.pageID]
        } else {
            requestedPageIDs = []
        }
        guard !requestedPageIDs.isEmpty,
              Set(requestedPageIDs)
                == Set(authorizedPageBindings.map(\.target.pageID)) else {
            BrowserCLI.writeResponse(
                ["error": "authorized Page identity does not match the request"],
                to: responseFilePath
            )
            return
        }
        do {
            for authorized in authorizedPageBindings {
                guard let targetManager = manager(
                    windowId: arguments["windowId"] as? String,
                    pageId: authorized.target.pageID
                ), let snapshot = await targetManager.automationPageAuthoritySnapshot(
                    pageID: authorized.target.pageID
                ) else {
                    throw BrowserAutomationPageBindingError.missingOrStaleTarget
                }
                try authorized.validate(
                    live: BrowserAutomationPageDispatchBinding(
                        target: snapshot.target,
                        version: AgentPageLeaseVersion(
                            navigation: authorized.version.navigation,
                            document: snapshot.document
                        )
                    ),
                    allowIncognito: true
                )
            }
        } catch {
            BrowserCLI.writeResponse(
                ["error": "authorized Page changed before browser dispatch"],
                to: responseFilePath
            )
            return
        }
        var boundArguments = arguments
        if !descriptor.acceptsMultiplePageTargets,
           boundArguments["pageId"] == nil {
            boundArguments["pageId"] = requestedPageIDs[0]
        }
        var boundRequest = request
        boundRequest["arguments"] = boundArguments
        performAuthorized(boundRequest, responseFilePath: responseFilePath)
    }

    private func performAuthorized(_ request: [String: Any], responseFilePath: String?) {
        guard let tool = request["tool"] as? String else {
            BrowserCLI.writeResponse(["error": "agent request is missing tool"], to: responseFilePath)
            return
        }
        let arguments = request["arguments"] as? [String: Any] ?? [:]
        let live = liveManagers()

        switch tool {
        case "list_pages":
            let pages = Self.externallyVisiblePageSummaries(
                live.flatMap { $0.automationPageSummaries() }
            )
            BrowserCLI.writeResponse(["ok": true, "pages": pages], to: responseFilePath)
        case "list_windows":
            let windows = live.compactMap {
                Self.externallyVisibleWindowSummary(
                    $0.automationWindowSummary(),
                    pages: $0.automationPageSummaries()
                )
            }
            BrowserCLI.writeResponse(["ok": true, "windows": windows], to: responseFilePath)
        case "get_active_page":
            guard let manager = manager(
                windowId: arguments["windowId"] as? String,
                pageId: arguments["pageId"] as? String
            ), let page = manager.automationActivePageSummary() else {
                BrowserCLI.writeResponse(["error": "no active browser page"], to: responseFilePath)
                return
            }
            guard Self.externallyVisiblePageSummaries([page]).count == 1 else {
                BrowserCLI.writeResponse(
                    ["error": "incognito pages are unavailable to local MCP"],
                    to: responseFilePath
                )
                return
            }
            BrowserCLI.writeResponse(["ok": true, "page": page], to: responseFilePath)
        case "create_window", "create_hidden_window":
            guard let source = manager(windowId: nil, pageId: nil) else {
                BrowserCLI.writeResponse(["error": "no browser window is ready"], to: responseFilePath)
                return
            }
            let existing = Set(live.map(\.automationWindowId))
            source.requestAutomationWindow()
            waitForNewWindow(
                excluding: existing,
                hidden: tool == "create_hidden_window",
                url: arguments["url"] as? String,
                responseFilePath: responseFilePath
            )
        default:
            guard let manager = manager(
                windowId: arguments["windowId"] as? String,
                pageId: arguments["pageId"] as? String
            ) else {
                BrowserCLI.writeResponse(["error": "no browser window is ready"], to: responseFilePath)
                return
            }
            manager.performAutomationTool(tool, arguments: arguments, responseFilePath: responseFilePath)
        }
    }

    private func performAuthorizedAndAwaitResult(
        _ request: [String: Any],
        permit: AgentExecutionPermit,
        authorizedPageBindings: [BrowserAutomationPageDispatchBinding],
        maximumElapsedMilliseconds: Int64
    ) async -> BrowserAutomationInvocationResult {
        guard let canonicalTool = request["tool"] as? String,
              canonicalTool == permit.toolName,
              let descriptor = AgentToolCatalog.canonical.descriptor(
                  named: canonicalTool
              ) else {
            return .generated(
                kind: .failed,
                message: "Policy authorization does not match the requested tool."
            )
        }

        let canonicalArguments = request["arguments"] as? [String: Any] ?? [:]
        if descriptor.requiresLivePageTarget {
            guard await externalPageBindingsRemainAuthorized(
                arguments: canonicalArguments,
                descriptor: descriptor,
                authorizedPageBindings: authorizedPageBindings
            ) else {
                return .generated(
                    kind: .failed,
                    message: "The authorized Page target is missing, stale, or changed."
                )
            }
        }

        if NotificationManager.handlesSemanticAutomationTool(canonicalTool) {
            let boundPageID = authorizedPageBindings.first?.target.pageID
                ?? canonicalArguments["pageId"] as? String
            guard let targetManager = manager(
                windowId: canonicalArguments["windowId"] as? String,
                pageId: boundPageID
            ) else {
                return .generated(
                    kind: .failed,
                    message: "The authorized Page target is no longer available."
                )
            }
            var boundArguments = canonicalArguments
            if boundArguments["pageId"] == nil, let boundPageID {
                boundArguments["pageId"] = boundPageID
            }
            let operation: () async -> BrowserAutomationInvocationResult = { [self] in
                guard await externalPageBindingsRemainAuthorized(
                    arguments: boundArguments,
                    descriptor: descriptor,
                    authorizedPageBindings: authorizedPageBindings
                ) else {
                    return .generated(
                        kind: .failed,
                        message: "The authorized Page changed immediately before dispatch."
                    )
                }
                let response = await targetManager.semanticAutomationJSONResult(
                    tool: canonicalTool,
                    arguments: boundArguments,
                    permit: permit
                )
                await BrowserAgentWebKitSignalRuntime.shared.finishRun(permit.runID)
                return BrowserAutomationInvocationResult(
                    responseData: Data(response.utf8)
                )
            }
            guard let authorizedBinding = authorizedPageBindings.first else {
                return await operation()
            }
            return await AgentReplayCaptureCoordinator.around(
                descriptor: descriptor,
                authorizedBinding: authorizedBinding,
                permit: permit,
                capture: { expectedBinding in
                    await targetManager.captureAgentReplayFrame(
                        expectedBinding: expectedBinding
                    )
                },
                operationSucceeded: { $0.kind == .succeeded },
                resolvePostOperationBinding: { [self] in
                    await resolvedExternalPageBindings(
                        arguments: boundArguments,
                        descriptor: descriptor
                    )?.first {
                        $0.target.pageID == authorizedBinding.target.pageID
                    }
                },
                operation: operation
            )
        }

        var dispatchArguments = canonicalArguments
        if descriptor.requiresLivePageTarget,
           dispatchArguments["pageId"] == nil,
           !descriptor.acceptsMultiplePageTargets,
           let boundPageID = authorizedPageBindings.first?.target.pageID {
            // Bind optional active-Page calls to the Page that policy actually
            // authorized. A focus change must never retarget the operation.
            dispatchArguments["pageId"] = boundPageID
        }
        let expanded = expandedExternalRequest(
            tool: canonicalTool,
            arguments: dispatchArguments
        )

        let responseURL = BrowserCLI.responseDirectory.appendingPathComponent(
            "tracked-\(UUID().uuidString).json"
        )
        defer { try? FileManager.default.removeItem(at: responseURL) }
        let boundedMilliseconds = max(
            50,
            min(maximumElapsedMilliseconds, 60_000)
        )
        let attempts = Int((boundedMilliseconds + 49) / 50)
        let operation: () async -> BrowserAutomationInvocationResult = { [self] in
            guard await externalPageBindingsRemainAuthorized(
                arguments: dispatchArguments,
                descriptor: descriptor,
                authorizedPageBindings: authorizedPageBindings
            ) else {
                return .generated(
                    kind: .failed,
                    message: "The authorized Page changed immediately before dispatch."
                )
            }
            performAuthorized(
                ["tool": expanded.tool, "arguments": expanded.arguments],
                responseFilePath: responseURL.path
            )
            for _ in 0..<attempts {
                if let data = try? Data(contentsOf: responseURL), !data.isEmpty {
                    return BrowserAutomationInvocationResult(responseData: data)
                }
                if Task.isCancelled {
                    return .generated(
                        kind: .failed,
                        message: "Browser automation was cancelled."
                    )
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return .generated(
                kind: .timedOut,
                message: "Browser automation timed out."
            )
        }
        guard descriptor.requiresLivePageTarget,
              let authorizedBinding = authorizedPageBindings.first,
              let targetManager = manager(
                  windowId: dispatchArguments["windowId"] as? String,
                  pageId: authorizedBinding.target.pageID
              ) else {
            return await operation()
        }
        return await AgentReplayCaptureCoordinator.around(
            descriptor: descriptor,
            authorizedBinding: authorizedBinding,
            permit: permit,
            capture: { expectedBinding in
                await targetManager.captureAgentReplayFrame(
                    expectedBinding: expectedBinding
                )
            },
            operationSucceeded: { $0.kind == .succeeded },
            resolvePostOperationBinding: { [self] in
                await resolvedExternalPageBindings(
                    arguments: dispatchArguments,
                    descriptor: descriptor
                )?.first {
                    $0.target.pageID == authorizedBinding.target.pageID
                }
            },
            operation: operation
        )
    }

    private func externalPageBindingsRemainAuthorized(
        arguments: [String: Any],
        descriptor: AgentToolDescriptor,
        authorizedPageBindings: [BrowserAutomationPageDispatchBinding]
    ) async -> Bool {
        guard descriptor.requiresLivePageTarget else { return true }
        guard !authorizedPageBindings.isEmpty,
              let liveBindings = await resolvedExternalPageBindings(
                  arguments: arguments,
                  descriptor: descriptor
              ), liveBindings.count == authorizedPageBindings.count else {
            return false
        }
        let liveByPageID = Dictionary(uniqueKeysWithValues: liveBindings.map {
            ($0.target.pageID, $0)
        })
        do {
            for authorized in authorizedPageBindings {
                try authorized.validate(live: liveByPageID[authorized.target.pageID])
            }
            return true
        } catch {
            return false
        }
    }

    /// Expands canonical MCP tools only after policy approval. The helper sends
    /// the original tool and arguments, so policy identity, risk, and durable
    /// metadata can never be replaced by the `evaluate_script` transport used
    /// to implement higher-level browser actions.
    private func expandedExternalRequest(
        tool: String,
        arguments: [String: Any]
    ) -> (tool: String, arguments: [String: Any]) {
        func literal(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: .fragmentsAllowed
            ) else { return "\"\"" }
            return String(data: data, encoding: .utf8) ?? "\"\""
        }
        func scriptRequest(_ script: String) -> (String, [String: Any]) {
            var expanded = arguments
            expanded["script"] = script
            return ("evaluate_script", expanded)
        }

        switch tool {
        case "get_page_content":
            return scriptRequest(Self.externalMarkdownScript)
        case "get_page_links":
            return scriptRequest(#"Array.from(new Map(Array.from(document.querySelectorAll('a[href]')).map(a=>[a.href,{text:String(a.innerText||a.getAttribute('aria-label')||'').trim(),url:a.href}])).values())"#)
        case "get_dom":
            let expression = (arguments["selector"] as? String).map {
                "document.querySelector(\(literal($0)))?.outerHTML||null"
            } ?? "document.documentElement.outerHTML"
            return scriptRequest(expression)
        case "search_dom":
            let query = arguments["query"] as? String ?? ""
            let mode = arguments["mode"] as? String ?? "text"
            let limit = max(1, min(arguments["limit"] as? Int ?? 50, 500))
            return scriptRequest(
                "(function(q,m,n){var a=[];if(m==='css')a=Array.from(document.querySelectorAll(q));else if(m==='xpath'){var x=document.evaluate(q,document,null,XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,null);for(var i=0;i<x.snapshotLength;i++)a.push(x.snapshotItem(i))}else a=Array.from(document.querySelectorAll('body *')).filter(e=>e.children.length===0&&String(e.textContent||'').toLowerCase().includes(q.toLowerCase()));return a.slice(0,n).map(e=>({tag:e.tagName?.toLowerCase()||'',text:String(e.innerText||e.textContent||'').trim().slice(0,500),html:e.outerHTML?.slice(0,2000)||''}))})(\(literal(query)),\(literal(mode)),\(limit))"
            )
        case "click_at":
            let x = arguments["x"] as? Double ?? 0
            let y = arguments["y"] as? Double ?? 0
            return scriptRequest("var el=document.elementFromPoint(\(x),\(y));if(!el)throw new Error('no element at point');el.click();({tag:el.tagName,x:\(x),y:\(y)})")
        case "press_key":
            let combo = arguments["key"] as? String ?? ""
            let parts = combo.split(separator: "+").map(String.init)
            let key = parts.last ?? combo
            let modifiers = Set(parts.dropLast().map { $0.lowercased() })
            let options = "{key:\(literal(key)),code:\(literal(key)),bubbles:true,cancelable:true,metaKey:\(modifiers.contains("meta") || modifiers.contains("cmd")),ctrlKey:\(modifiers.contains("ctrl") || modifiers.contains("control")),altKey:\(modifiers.contains("alt") || modifiers.contains("option")),shiftKey:\(modifiers.contains("shift"))}"
            return scriptRequest("var el=document.activeElement||document.body,o=\(options);el.dispatchEvent(new KeyboardEvent('keydown',o));el.dispatchEvent(new KeyboardEvent('keyup',o));'pressed'")
        case "save_screenshot":
            return ("take_screenshot", arguments)
        default:
            return (tool, arguments)
        }
    }

    private static let externalMarkdownScript = #"""
    (function(){var r=document.querySelector('main,article,[role=main]')||document.body;if(!r)return'';function c(s){return String(s||'').replace(/[ \t]+/g,' ').replace(/\n{3,}/g,'\n\n').trim()}var o=[];Array.from(r.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,table,a[href]')).forEach(function(e){if(e.closest('nav,header,footer,aside')&&!e.matches('a[href]'))return;var t=c(e.innerText||e.textContent);if(!t)return;if(/^H[1-6]$/.test(e.tagName))o.push('#'.repeat(Number(e.tagName[1]))+' '+t);else if(e.tagName==='LI')o.push('- '+t);else if(e.tagName==='BLOCKQUOTE')o.push('> '+t.replace(/\n/g,'\n> '));else if(e.tagName==='PRE')o.push('```\n'+t+'\n```');else if(e.tagName==='A'&&!e.closest('p,li,h1,h2,h3,h4,h5,h6'))o.push('['+t+']('+e.href+')');else o.push(t)});return o.join('\n\n').slice(0,100000)})()
    """#

    private func authorizeExternalInvocation(
        _ request: [String: Any],
        responseFilePath: String?
    ) async {
        guard let tool = request["tool"] as? String,
              let descriptor = AgentToolCatalog.canonical.descriptor(named: tool) else {
            BrowserCLI.writeResponse(["error": "unknown agent tool"], to: responseFilePath)
            return
        }
        let arguments = request["arguments"] as? [String: Any] ?? [:]
        guard let argumentValue = try? JSONValue(foundationValue: arguments) else {
            BrowserCLI.writeResponse(["error": "tool arguments are not valid JSON"], to: responseFilePath)
            return
        }
        if (tool == "new_page" || tool == "new_hidden_page"),
           arguments["incognito"] as? Bool == true {
            BrowserCLI.writeResponse(
                ["error": "incognito pages are unavailable to local MCP"],
                to: responseFilePath
            )
            return
        }
        let pageBindings = await resolvedExternalPageBindings(
            arguments: arguments,
            descriptor: descriptor
        ) ?? []
        let target: AgentResolvedTarget = if descriptor.requiresLivePageTarget {
            pageBindings.first.map { .page($0.target) } ?? .none
        } else {
            resolvedExternalTarget(arguments: arguments, descriptor: descriptor)
        }
        let scope = externalRunScope(
            descriptor: descriptor,
            target: target,
            pageBindings: pageBindings
        )
        let isIncognito = if case .page(let page) = target {
            page.session == .incognito
        } else {
            arguments["incognito"] as? Bool == true
        }
        do {
            let store = try AgentRunStoreRegistry.store(baseDirectory: BrowserCLI.supportDirectory)
            let run = try await store.createRun(
                conversationID: nil,
                entryPoint: .localMCP,
                configuration: AgentConfigurationSnapshot(
                    toolCatalogVersion: 1,
                    enabledCapabilities: descriptor.requiredCapabilities,
                    settings: ["transport": .string("local-mcp")]
                ),
                incognito: isIncognito
            )
            _ = try await store.transitionRun(run.id, to: .running, reason: "Local MCP invocation received")
            let limits = AgentObservabilitySettings.executionLimits()
            let meter = AgentRunMeter(
                runID: run.id,
                taskDefinitionID: nil,
                incognito: isIncognito,
                limits: limits
            )
            guard try await Self.handleLocalMCPAdmission(
                await meter.admitToolCall(),
                runID: run.id,
                store: store,
                responseFilePath: responseFilePath
            ) else { return }

            let context = AgentInvocationContext(
                runID: run.id,
                entryPoint: .localMCP,
                humanPresent: false,
                toolName: tool,
                arguments: argumentValue,
                target: target,
                runScope: scope,
                // Every local-MCP result crosses the browser process boundary,
                // including navigation and mutation acknowledgements.
                dataLeavesDevice: true,
                effectSummary: descriptor.description
            )
            let decision = try AgentPolicyEngine().evaluate(descriptor: descriptor, context: context)
            switch decision {
            case .allow(let authorization):
                let policyStep = try await store.appendStep(
                    runID: run.id,
                    kind: .policyDecision,
                    summary: "Allowed local MCP invocation",
                    payload: .object([
                        "decision": .string("allow"),
                        "tool": .string(tool),
                        "invocationDigest": .string(authorization.invocationDigest),
                    ]),
                    redactionState: .metadataOnly
                )
                let invocationStep = try await store.appendStep(
                    runID: run.id,
                    kind: .toolInvocation,
                    summary: tool,
                    payload: .object(["tool": .string(tool)]),
                    policyDecisionStepID: policyStep.id,
                    redactionState: .redacted
                )
                let permit = authorization
                    .recording(decisionStepID: policyStep.id)
                    .recording(invocationStepID: invocationStep.id)
                let outcome = await performAuthorizedAndAwaitResult(
                    request,
                    permit: permit,
                    authorizedPageBindings: pageBindings,
                    maximumElapsedMilliseconds: limits.maximumElapsedMilliseconds
                )
                let metricOutcome: AgentToolMetricOutcome = switch outcome.kind {
                case .succeeded: .succeeded
                case .timedOut: .ambiguousTimeout
                case .failed, .malformed: .failed
                }
                await meter.recordToolLatency(
                    milliseconds: Int64(
                        max(0, Date().timeIntervalSince(run.createdAt) * 1_000)
                    ),
                    toolName: tool,
                    outcome: metricOutcome
                )
                // Local-MCP response bytes share the bounded model-result byte
                // dimension: both are untrusted result material crossing into
                // an agent context, and neither is retained in durable history.
                guard try await Self.handleLocalMCPAdmission(
                    await meter.admitModelResult(bytes: outcome.responseData.count),
                    runID: run.id,
                    store: store,
                    responseFilePath: responseFilePath
                ) else { return }
                do {
                    _ = try await store.appendStep(
                        runID: run.id,
                        kind: outcome.kind == .succeeded ? .toolResult : .error,
                        summary: outcome.kind == .succeeded
                            ? "Browser automation completed"
                            : "Browser automation did not complete successfully",
                        payload: outcome.durableMetadata,
                        policyDecisionStepID: policyStep.id,
                        redactionState: .metadataOnly
                    )
                    _ = try await store.transitionRun(
                        run.id,
                        to: outcome.kind == .succeeded ? .succeeded : .failed,
                        reason: outcome.kind == .succeeded
                            ? "Browser automation succeeded"
                            : "Browser automation failed"
                    )
                } catch {
                    Logger.log(
                        "Could not finalize local MCP run metadata",
                        type: "BrowserCLI"
                    )
                }
                _ = try? await AgentRunStoreRegistry.enforceRetention(
                    store,
                    baseDirectory: BrowserCLI.supportDirectory
                )
                BrowserCLI.writeResponseData(outcome.responseData, to: responseFilePath)

            case .deny(let code, _):
                _ = try await store.appendStep(
                    runID: run.id,
                    kind: .policyDecision,
                    summary: "Denied local MCP invocation: \(code.rawValue)",
                    payload: .object(["decision": .string("deny"), "code": .string(code.rawValue)]),
                    redactionState: .metadataOnly
                )
                _ = try await store.transitionRun(run.id, to: .failed, reason: "Policy denied invocation")
                _ = try? await AgentRunStoreRegistry.enforceRetention(
                    store,
                    baseDirectory: BrowserCLI.supportDirectory
                )
                BrowserCLI.writeResponse(
                    ["error": "policy denied invocation", "code": code.rawValue, "runId": run.id.uuidString],
                    to: responseFilePath
                )

            case .requiresApproval(let approval):
                try await Self.terminateUnattendedApproval(
                    approval,
                    runID: run.id,
                    waitingStatus: .waitingForApproval,
                    store: store,
                    responseFilePath: responseFilePath
                )

            case .requiresHuman(let approval):
                try await Self.terminateUnattendedApproval(
                    approval,
                    runID: run.id,
                    waitingStatus: .waitingForHuman,
                    store: store,
                    responseFilePath: responseFilePath
                )
            }
        } catch {
            BrowserCLI.writeResponse(
                ["error": "could not record or authorize invocation"],
                to: responseFilePath
            )
        }
    }

    static func terminateUnattendedApproval(
        _ approval: AgentApprovalRequest,
        runID: UUID,
        waitingStatus: AgentRunStatus,
        store: AgentRunStore,
        responseFilePath: String?
    ) async throws {
        _ = try await store.appendStep(
            runID: runID,
            kind: .approvalRequest,
            summary: approval.effectSummary,
            payload: .object([
                "requestID": .string(approval.id.uuidString),
                "tool": .string(approval.toolName),
                "invocationDigest": .string(approval.invocationDigest),
            ]),
            redactionState: .redacted
        )
        _ = try await store.transitionRun(
            runID,
            to: waitingStatus,
            reason: "Local MCP invocation requires an attended decision"
        )
        _ = try await store.appendStep(
            runID: runID,
            kind: .approvalResponse,
            summary: "Local MCP has no attended continuation channel",
            payload: .object([
                "approved": .boolean(false),
                "terminal": .boolean(true),
            ]),
            redactionState: .metadataOnly
        )
        _ = try await store.transitionRun(
            runID,
            to: .cancelled,
            reason: "Invocation was not executed because no attended continuation is available"
        )
        _ = try? await AgentRunStoreRegistry.enforceRetention(
            store,
            baseDirectory: BrowserCLI.supportDirectory
        )
        BrowserCLI.writeResponse(
            [
                "error": "This invocation requires an attended human decision and was not executed. Start a new attended request instead.",
                "code": "human_interaction_required",
                "status": AgentRunStatus.cancelled.rawValue,
                "retryable": false,
                "runId": runID.uuidString,
                "requestId": approval.id.uuidString,
            ],
            to: responseFilePath
        )
    }

    static func handleLocalMCPAdmission(
        _ admission: AgentBudgetAdmission,
        runID: UUID,
        store: AgentRunStore,
        responseFilePath: String?
    ) async throws -> Bool {
        switch admission {
        case .admitted:
            return true
        case .limited(let limit):
            _ = try await store.appendStep(
                runID: runID,
                kind: .limit,
                summary: limit.summary,
                payload: .object([
                    "dimension": .string(limit.dimension.rawValue),
                    "reason": .string(limit.reason.rawValue),
                    "current": limit.current.map { .number(Double($0)) } ?? .null,
                    "attempted": limit.attempted.map { .number(Double($0)) } ?? .null,
                    "maximum": limit.maximum.map { .number(Double($0)) } ?? .null,
                ]),
                redactionState: .metadataOnly
            )
            _ = try await store.transitionRun(
                runID,
                to: .failed,
                reason: "Local MCP hard limit reached"
            )
            _ = try? await AgentRunStoreRegistry.enforceRetention(
                store,
                baseDirectory: BrowserCLI.supportDirectory
            )
            BrowserCLI.writeResponse(
                [
                    "error": limit.summary,
                    "code": "limit_exceeded",
                    "dimension": limit.dimension.rawValue,
                    "runId": runID.uuidString,
                ],
                to: responseFilePath
            )
            return false
        case .cancelled(let cancellation):
            _ = try await store.transitionRun(
                runID,
                to: .cancelled,
                reason: cancellation.reason
            )
            _ = try? await AgentRunStoreRegistry.enforceRetention(
                store,
                baseDirectory: BrowserCLI.supportDirectory
            )
            BrowserCLI.writeResponse(
                ["error": "Local MCP run was cancelled.", "code": "cancelled"],
                to: responseFilePath
            )
            return false
        case .interrupted:
            _ = try await store.transitionRun(
                runID,
                to: .interrupted,
                reason: "Local MCP budget accounting was interrupted"
            )
            _ = try? await AgentRunStoreRegistry.enforceRetention(
                store,
                baseDirectory: BrowserCLI.supportDirectory
            )
            BrowserCLI.writeResponse(
                ["error": "Local MCP run was interrupted.", "code": "interrupted"],
                to: responseFilePath
            )
            return false
        }
    }

    private func resolvedExternalPageBindings(
        arguments: [String: Any],
        descriptor: AgentToolDescriptor
    ) async -> [BrowserAutomationPageDispatchBinding]? {
        guard descriptor.requiresLivePageTarget else { return [] }
        let requestedPageIDs: [String?]
        if descriptor.acceptsMultiplePageTargets {
            let pageIDs = arguments["pageIds"] as? [String] ?? []
            guard !pageIDs.isEmpty else { return nil }
            requestedPageIDs = pageIDs.map(Optional.some)
        } else {
            requestedPageIDs = [arguments["pageId"] as? String]
        }
        var seen = Set<PageHandle>()
        var bindings: [BrowserAutomationPageDispatchBinding] = []
        for requestedPageID in requestedPageIDs {
            guard let manager = manager(
                windowId: arguments["windowId"] as? String,
                pageId: requestedPageID
            ), let snapshot = await manager.automationPageAuthoritySnapshot(
                pageID: requestedPageID
            ), let page = try? PageHandle(parsing: snapshot.target.pageID),
                  seen.insert(page).inserted else { return nil }
            var invocationTarget = snapshot.target
            invocationTarget.elementIdentity = arguments["elementId"] as? String
                ?? arguments["selector"] as? String
            let prior = pageAuthorityStates[page]
            let sameDocument = prior?.document == snapshot.document
                && prior?.target.pageID == snapshot.target.pageID
                && prior?.target.origin == snapshot.target.origin
                && prior?.target.session == snapshot.target.session
            let version = if sameDocument, let prior {
                prior.version
            } else {
                AgentPageLeaseVersion(
                    navigation: prior?.version.navigation.advanced()
                        ?? PageNavigationGeneration(rawValue: 0),
                    document: snapshot.document
                )
            }
            var stateTarget = snapshot.target
            stateTarget.elementIdentity = nil
            pageAuthorityStates[page] = PageAuthorityState(
                document: snapshot.document,
                target: stateTarget,
                version: version
            )
            bindings.append(BrowserAutomationPageDispatchBinding(
                target: invocationTarget,
                version: version
            ))
        }
        guard let session = bindings.first?.target.session,
              bindings.allSatisfy({ $0.target.session == session }) else {
            return nil
        }
        return bindings.sorted { $0.target.pageID < $1.target.pageID }
    }

    private func resolvedExternalTarget(
        arguments: [String: Any],
        descriptor: AgentToolDescriptor
    ) -> AgentResolvedTarget {
        let pageCapabilities: Set<AgentCapability> = [.pageRead, .pageScript, .screenshot, .download]
        guard arguments["pageId"] != nil
                || !descriptor.requiredCapabilities.isDisjoint(with: pageCapabilities),
              let manager = manager(
                windowId: arguments["windowId"] as? String,
                pageId: arguments["pageId"] as? String
              ) else { return .none }
        let pages = manager.automationPageSummaries()
        let requested = arguments["pageId"] as? String
        guard let summary = requested.flatMap({ id in pages.first { ($0["pageId"] as? String) == id } })
                ?? manager.automationActivePageSummary(),
              let pageID = summary["pageId"] as? String,
              let rawURL = summary["url"] as? String,
              let url = URL(string: rawURL), let scheme = url.scheme, let host = url.host else {
            return .none
        }
        let session: AgentBrowserSession = (summary["sessionKind"] as? String) == "incognito"
            ? .incognito : .normal
        let port = url.port.map { ":\($0)" } ?? ""
        return .page(AgentPageTarget(
            pageID: pageID,
            origin: "\(scheme.lowercased())://\(host.lowercased())\(port)",
            session: session,
            elementIdentity: arguments["elementId"] as? String ?? arguments["selector"] as? String
        ))
    }

    private func externalRunScope(
        descriptor: AgentToolDescriptor,
        target: AgentResolvedTarget,
        pageBindings: [BrowserAutomationPageDispatchBinding]
    ) -> AgentRunScope {
        if let session = pageBindings.first?.target.session {
            return AgentRunScope(
                capabilities: descriptor.requiredCapabilities,
                pageIDs: Set(pageBindings.map(\.target.pageID)),
                origins: Set(pageBindings.map(\.target.origin)),
                session: session
            )
        }
        if case .page(let page) = target {
            return AgentRunScope(
                capabilities: descriptor.requiredCapabilities,
                pageIDs: [page.pageID],
                origins: [page.origin],
                session: page.session
            )
        }
        return AgentRunScope(capabilities: descriptor.requiredCapabilities)
    }

    private func waitForNewWindow(
        excluding existing: Set<UUID>,
        hidden: Bool,
        url: String?,
        responseFilePath: String?,
        attemptsRemaining: Int = 40
    ) {
        if let created = liveManagers().first(where: { !existing.contains($0.automationWindowId) }) {
            if hidden { created.setAutomationWindowHidden(true) }
            if let url {
                created.performAutomationTool(
                    hidden ? "new_hidden_page" : "new_page",
                    arguments: ["url": url],
                    responseFilePath: responseFilePath
                )
            } else {
                BrowserCLI.writeResponse(
                    ["ok": true, "window": created.automationWindowSummary()],
                    to: responseFilePath
                )
            }
            return
        }
        guard attemptsRemaining > 0 else {
            BrowserCLI.writeResponse(["error": "timed out creating browser window"], to: responseFilePath)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForNewWindow(
                excluding: existing,
                hidden: hidden,
                url: url,
                responseFilePath: responseFilePath,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }
}

// File-based CLI IPC. The browser owns a named pipe (FIFO) in its own
// Application Support directory with owner-only permissions. Those permissions
// limit callers to the signed-in user; explicit in-app settings authorize what
// their processes may ask the browser to do. The CLI tool writes one command
// per line; data commands pass --response-file <path>, which must live inside
// our response directory, and the app writes the JSON result there.
enum CLICapability: Equatable {
    case control
    case pageRead
    case pageScript
    case screenshot
}

struct CLIAuthorization {
    enum Key {
        static let enabled = "cliAutomationEnabled"
        static let pageRead = "cliPageReadEnabled"
        static let pageScript = "cliPageScriptEnabled"
        static let screenshot = "cliScreenshotEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func capability(for action: String) -> CLICapability {
        switch action {
        case "tabs", "get":
            return .pageRead
        case "js", "realclick":
            return .pageScript
        case "screenshot":
            return .screenshot
        default:
            return .control
        }
    }

    static func capability(forAgentTool tool: String) -> CLICapability {
        guard let descriptor = AgentToolCatalog.canonical.descriptor(named: tool) else {
            return .control
        }
        let capabilities = descriptor.requiredCapabilities
        if capabilities.contains(.screenshot) { return .screenshot }
        if capabilities.contains(.pageScript) || capabilities.contains(.download) {
            return .pageScript
        }
        if !capabilities.intersection([
            .pageRead, .bookmarkRead, .historyRead, .tabGroups, .coworkRead,
        ]).isEmpty {
            return .pageRead
        }
        return .control
    }

    func allows(action: String) -> Bool {
        guard defaults.bool(forKey: Key.enabled) else { return false }

        switch Self.capability(for: action) {
        case .control:
            return true
        case .pageRead:
            return defaults.bool(forKey: Key.pageRead)
        case .pageScript:
            return defaults.bool(forKey: Key.pageScript)
        case .screenshot:
            return defaults.bool(forKey: Key.screenshot)
        }
    }

    func allows(capability: CLICapability) -> Bool {
        guard defaults.bool(forKey: Key.enabled) else { return false }
        switch capability {
        case .control: return true
        case .pageRead: return defaults.bool(forKey: Key.pageRead)
        case .pageScript: return defaults.bool(forKey: Key.pageScript)
        case .screenshot: return defaults.bool(forKey: Key.screenshot)
        }
    }

    func denialMessage(for action: String) -> String {
        guard defaults.bool(forKey: Key.enabled) else {
            return "CLI automation is disabled. Enable it in Settings > Security > CLI Automation."
        }

        switch Self.capability(for: action) {
        case .control:
            return "CLI automation is disabled."
        case .pageRead:
            return "CLI page reading is disabled. Enable it in Settings > Security > CLI Automation."
        case .pageScript:
            return "CLI JavaScript and synthetic interaction are disabled. Enable them in Settings > Security > CLI Automation."
        case .screenshot:
            return "CLI screenshots are disabled. Enable them in Settings > Security > CLI Automation."
        }
    }

    func denialMessage(for capability: CLICapability) -> String {
        guard defaults.bool(forKey: Key.enabled) else {
            return "Agent automation is disabled. Enable it in Settings > Security > Agent Automation."
        }
        switch capability {
        case .control: return "Agent browser control is disabled."
        case .pageRead: return "Agent page reading is disabled in Settings > Security > Agent Automation."
        case .pageScript: return "Agent JavaScript and synthetic interaction are disabled in Settings > Security > Agent Automation."
        case .screenshot: return "Agent screenshots are disabled in Settings > Security > Agent Automation."
        }
    }
}

class BrowserCLI {
    static let shared = BrowserCLI()

    static let supportDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Straight Up Browser", isDirectory: true)
    static let pipeURL = supportDirectory.appendingPathComponent("cli.pipe")
    static let responseDirectory = supportDirectory.appendingPathComponent("responses", isDirectory: true)

    private var isPipeSetup = false

    private init() {
        setupCommandInterface()
    }

    private func setupCommandInterface() {
        guard !isPipeSetup else { return }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.responseDirectory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            Logger.log("Failed to create CLI directories: \(error)", type: "BrowserCLI")
            return
        }

        let pipePath = Self.pipeURL.path
        try? fm.removeItem(atPath: pipePath)

        guard mkfifo(pipePath, 0o600) == 0 else {
            Logger.log("Failed to create command pipe at \(pipePath)", type: "BrowserCLI")
            return
        }

        Logger.log("Browser CLI pipe created at: \(pipePath)", type: "BrowserCLI")
        isPipeSetup = true

        DispatchQueue.global(qos: .background).async {
            BrowserCLI.listenForCommands(at: pipePath) { command in
                Task { @MainActor in
                    BrowserCLI.shared.handleCommand(command)
                }
            }
        }
    }

    nonisolated private static func listenForCommands(
        at pipePath: String,
        onCommand: @escaping @Sendable (String) -> Void
    ) {
        // O_RDWR on our own FIFO: never blocks on open, keeps a reader alive so
        // clients' O_NONBLOCK writes succeed (Darwin returns ENXIO to a
        // nonblocking writer unless the read end is fully open), and read()
        // blocks instead of returning EOF between clients. No polling, no spin.
        let fd = open(pipePath, O_RDWR)
        guard fd >= 0 else {
            Logger.log("Failed to open command pipe for reading", type: "BrowserCLI")
            return
        }
        let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        var buffer = Data()
        while true {
            let chunk = fileHandle.availableData // blocks until data arrives
            if chunk.isEmpty { continue }
            buffer.append(chunk)

            // One command per line; writes under PIPE_BUF are atomic
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])
                if let command = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !command.isEmpty {
                    onCommand(command)
                }
            }
        }
    }

    // Every response the app writes lives inside its own responses/ dir.
    // Errors and acks share one JSON shape: {"ok":true,...} or {"error":"..."}.
    static func writeResponse(_ dict: [String: Any], to path: String?) {
        guard let path = path else { return }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    static func writeResponseData(_ data: Data, to path: String?) {
        guard let path, !data.isEmpty else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func handleCommand(_ command: String) {
        // The command may contain a base64-encoded tool payload with form data,
        // scripts, or tokens. Never copy it into durable diagnostic logs.
        Logger.log("BrowserCLI received a command", type: "BrowserCLI")

        var commandParts = command.split(separator: " ")
        var responseFilePath: String? = nil

        if let responseFlagIndex = commandParts.firstIndex(of: "--response-file"),
           responseFlagIndex + 1 < commandParts.count {
            // Bare filename only (the response dir path contains spaces, and we
            // never take an arbitrary write path from input anyway) - the app
            // resolves it inside its own response directory
            let name = String(commandParts[responseFlagIndex + 1])
            commandParts.remove(at: responseFlagIndex + 1)
            commandParts.remove(at: responseFlagIndex)

            if !name.contains("/") && !name.contains("..") {
                responseFilePath = Self.responseDirectory.appendingPathComponent(name).path
            } else {
                Logger.log("Rejected response file name: \(name)", type: "BrowserCLI")
            }
        }

        var newTab = false
        if let newFlagIndex = commandParts.firstIndex(of: "--new") {
            commandParts.remove(at: newFlagIndex)
            newTab = true
        }

        // screenshot-only flags, reusing the same generic strip-before-dispatch
        // approach as --new above.
        var fullPage = false
        if let index = commandParts.firstIndex(of: "--full-page") {
            commandParts.remove(at: index)
            fullPage = true
        }
        var toClipboard = false
        if let index = commandParts.firstIndex(of: "--clipboard") {
            commandParts.remove(at: index)
            toClipboard = true
        }
        var toShared = false
        if let index = commandParts.firstIndex(of: "--shared") {
            commandParts.remove(at: index)
            toShared = true
        }

        guard let action = commandParts.first?.lowercased() else {
            Self.writeResponse(["error": "missing command"], to: responseFilePath)
            return
        }
        let parameter = commandParts.count > 1 ? commandParts[1..<commandParts.count].joined(separator: " ") : nil

        let agentRequest: [String: Any]? = {
            guard action == "agent", let parameter,
                  let data = Data(base64Encoded: parameter),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let request = object as? [String: Any] else { return nil }
            return request
        }()

        let authorization = CLIAuthorization()
        let allowed: Bool
        if action == "agent", let tool = agentRequest?["tool"] as? String {
            allowed = authorization.allows(capability: CLIAuthorization.capability(forAgentTool: tool))
        } else {
            allowed = authorization.allows(action: action)
        }
        guard allowed else {
            let agentCapability = (agentRequest?["tool"] as? String)
                .map(CLIAuthorization.capability(forAgentTool:)) ?? .control
            let message = action == "agent"
                ? authorization.denialMessage(for: agentCapability)
                : authorization.denialMessage(for: action)
            Self.writeResponse(["error": message], to: responseFilePath)
            return
        }

        // Same cold-launch race App Intents guard against: observers attach in
        // ContentView.onAppear. We're on the dedicated pipe thread and commands
        // are serial, so a bounded blocking wait is fine. Authorization is
        // checked first so denied commands never wait for or touch browser state.
        if !NotificationManager.observersReady {
            for _ in 0..<100 where !NotificationManager.observersReady {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if !NotificationManager.observersReady {
                Self.writeResponse(["error": "Browser window not ready (first-run EULA screen?)"], to: responseFilePath)
                return
            }
        }

        // Acks mean "accepted for execution on the main queue" - agents follow
        // navigation with `wait`. Commands that can fail respond from their
        // observer instead.
        switch action {
        case "agent":
            guard let agentRequest else {
                Self.writeResponse(["error": "agent requires a base64-encoded JSON request"], to: responseFilePath)
                return
            }
            BrowserAutomationRegistry.shared.execute(agentRequest, responseFilePath: responseFilePath)
        case "open":
            if let urlString = parameter {
                var userInfo: [String: Any] = ["url": urlString]
                if newTab { userInfo["newTab"] = true }
                NotificationCenter.default.post(name: .browserOpenURL, object: nil, userInfo: userInfo)
                Self.writeResponse(["ok": true], to: responseFilePath)
            } else {
                Self.writeResponse(["error": "open requires a URL"], to: responseFilePath)
            }
        case "search":
            if let query = parameter {
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                NotificationCenter.default.post(name: .browserOpenURL, object: nil,
                                                userInfo: ["url": "https://www.google.com/search?q=" + encoded])
                Self.writeResponse(["ok": true], to: responseFilePath)
            } else {
                Self.writeResponse(["error": "search requires a query"], to: responseFilePath)
            }
        case "new":
            NotificationCenter.default.post(name: .browserNewTab, object: nil)
            Self.writeResponse(["ok": true], to: responseFilePath)
        case "close":
            NotificationCenter.default.post(name: .browserCloseTab, object: nil)
            Self.writeResponse(["ok": true], to: responseFilePath)
        case "back", "forward", "reload":
            NotificationCenter.default.post(name: .browserNavigate, object: nil, userInfo: ["action": action])
            Self.writeResponse(["ok": true], to: responseFilePath)
        case "switch":
            if let parameter = parameter, let index = Int(parameter) {
                var userInfo: [String: Any] = ["index": index]
                if let responseFilePath = responseFilePath { userInfo["responseFilePath"] = responseFilePath }
                NotificationCenter.default.post(name: .browserSwitchTab, object: nil, userInfo: userInfo)
            } else {
                Self.writeResponse(["error": "switch requires a tab index (1-based, see `tabs`)"], to: responseFilePath)
            }
        case "wait":
            let timeout = parameter.flatMap(Double.init) ?? 15
            var userInfo: [String: Any] = ["timeout": timeout]
            if let responseFilePath = responseFilePath { userInfo["responseFilePath"] = responseFilePath }
            NotificationCenter.default.post(name: .browserWaitForLoad, object: nil, userInfo: userInfo)
        case "js":
            // Code is base64'd by the CLI so newlines/spaces survive the
            // one-line pipe protocol
            if let encoded = parameter, let data = Data(base64Encoded: encoded),
               let script = String(data: data, encoding: .utf8) {
                var userInfo: [String: Any] = ["script": script]
                if let responseFilePath = responseFilePath { userInfo["responseFilePath"] = responseFilePath }
                NotificationCenter.default.post(name: .browserRunJS, object: nil, userInfo: userInfo)
            } else {
                Self.writeResponse(["error": "js requires base64-encoded code"], to: responseFilePath)
            }
        case "realclick":
            if let encoded = parameter, let data = Data(base64Encoded: encoded),
               let selector = String(data: data, encoding: .utf8) {
                var userInfo: [String: Any] = ["selector": selector]
                if let responseFilePath = responseFilePath { userInfo["responseFilePath"] = responseFilePath }
                NotificationCenter.default.post(name: .browserRealClick, object: nil, userInfo: userInfo)
            } else {
                Self.writeResponse(["error": "realclick requires a base64-encoded selector"], to: responseFilePath)
            }
        case "screenshot":
            var userInfo: [String: Any] = [:]
            if let responseFilePath = responseFilePath { userInfo["responseFilePath"] = responseFilePath }
            if fullPage { userInfo["fullPage"] = true }
            if toClipboard { userInfo["clipboard"] = true }
            if toShared { userInfo["shared"] = true }
            NotificationCenter.default.post(name: .browserScreenshot, object: nil, userInfo: userInfo)
        case "notify":
            NotificationCenter.default.post(name: .browserNotifyUser, object: nil,
                                            userInfo: ["message": parameter ?? "The browser needs your attention."])
            Self.writeResponse(["ok": true], to: responseFilePath)
        case "focus":
            NotificationCenter.default.post(name: .browserFocusWindow, object: nil)
            Self.writeResponse(["ok": true], to: responseFilePath)
        case "tabs":
            var userInfo: [String: Any] = [:]
            if let responseFilePath = responseFilePath {
                userInfo["responseFilePath"] = responseFilePath
            }
            NotificationCenter.default.post(name: .browserListTabs, object: nil, userInfo: userInfo)
        case "get":
            var userInfo: [String: Any] = [:]
            if let urlString = parameter, urlString != "current" {
                userInfo["url"] = urlString
            } else {
                userInfo["currentPage"] = true
            }
            if let responseFilePath = responseFilePath {
                userInfo["responseFilePath"] = responseFilePath
            }
            NotificationCenter.default.post(name: .browserGetPageData, object: nil, userInfo: userInfo)
        default:
            Logger.log("Unknown CLI command: \(command)", type: "BrowserCLI")
            Self.writeResponse(["error": "unknown command: \(action)"], to: responseFilePath)
        }
    }
}
