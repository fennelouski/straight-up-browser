import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Browser

@MainActor
struct BrowserAgentTests {
    // Parallel full-suite runs contend for the main actor (the whole target
    // defaults to MainActor isolation), so the agent loop can run an order of
    // magnitude slower than in serial or isolated runs. Fixed spin counts sized
    // to serial timing made these tests fail every parallel run; wait on
    // wall-clock with a deadline far beyond any healthy run instead.
    private func waitWhile(
        upTo deadline: Duration = .seconds(120),
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while condition(), clock.now - start < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func assistantMarkdownRendererPreservesFormattingAndLinks() {
        let rendered = AgentMarkdownRenderer.attributedString(
            from: "A **useful** answer with [details](https://example.com) and `code`."
        )

        #expect(String(rendered.characters) == "A useful answer with details and code.")
        #expect(rendered.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        #expect(rendered.runs.contains { run in
            run.inlinePresentationIntent?.contains(.code) == true
        })
        #expect(rendered.runs.contains { run in
            run.link?.absoluteString == "https://example.com"
        })

        let structured = AgentMarkdownRenderer.attributedString(
            from: "## Options\n\n- **First** choice\n- Second choice\n\n```\nlet answer = 2\n```"
        )
        #expect(String(structured.characters) ==
            "Options\n\n• First choice\n• Second choice\n\n\nlet answer = 2\n")
        #expect(structured.runs.contains { run in
            run.inlinePresentationIntent?.contains(.code) == true
        })
    }

    @Test func providerTemplatesCoverCloudLocalAndCustomEndpoints() {
        #expect(BrowserAgentProvider.allCases == [
            .appleIntelligence, .openAI, .openAIResponses, .anthropicMessages, .gemini,
            .openRouter, .ollama, .lmStudio, .compatible,
        ])
        #expect(BrowserAgentProvider.appleIntelligence.defaultModel == "apple-intelligence:on-device")
        #expect(!BrowserAgentProvider.appleIntelligence.needsAPIKey)
        #expect(BrowserAgentProvider.openAI.defaultEndpoint ==
            "https://api.openai.com/v1/responses")
        #expect(BrowserAgentProvider.openAIResponses.defaultEndpoint ==
            "https://api.openai.com/v1/responses")
        #expect(BrowserAgentProvider.anthropicMessages.defaultEndpoint ==
            "https://api.anthropic.com/v1/messages")
        #expect(BrowserAgentProvider.gemini.defaultEndpoint ==
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:streamGenerateContent?alt=sse")
        #expect(BrowserAgentProvider.openRouter.defaultEndpoint.hasPrefix("https://"))
        #expect(BrowserAgentProvider.ollama.defaultEndpoint.contains("11434"))
        #expect(BrowserAgentProvider.lmStudio.defaultEndpoint.contains("1234"))
        #expect(BrowserAgentProvider.compatible.defaultEndpoint.isEmpty)
        #expect(BrowserAgentProvider.openAI.defaultModel == "gpt-5.6-luna")
        #expect(BrowserAgentProvider.openAIResponses.defaultModel == "gpt-5.6-luna")
        #expect(BrowserAgentProvider.anthropicMessages.defaultModel == "claude-sonnet-5")
        #expect(BrowserAgentProvider.gemini.defaultModel == "gemini-3.6-flash")
        #expect(BrowserAgentProvider.openRouter.defaultModel == "openai/gpt-latest")
        // Local providers deliberately ship no default: discovery plus the model
        // picker makes a hardcoded guess at what's installed worse than none.
        #expect(BrowserAgentProvider.ollama.defaultModel.isEmpty)
        #expect(BrowserAgentProvider.lmStudio.defaultModel.isEmpty)
        #expect(BrowserAgentProvider.compatible.defaultModel.isEmpty)
        #expect(BrowserAgentProvider.openAI.needsAPIKey)
        #expect(!BrowserAgentProvider.ollama.needsAPIKey)
        #expect(!BrowserAgentProvider.lmStudio.needsAPIKey)
        #expect(BrowserAgentProvider.openAI.dialect == .openAIResponses)
        #expect(BrowserAgentProvider.openAIResponses.dialect == .openAIResponses)
        #expect(BrowserAgentProvider.anthropicMessages.dialect == .anthropicMessages)
        #expect(BrowserAgentProvider.gemini.dialect == .geminiGenerateContent)
        #expect(BrowserAgentProvider.openRouter.dialect == .openAICompatibleChat)
        #expect(BrowserAgentProvider.ollama.dialect == .openAICompatibleChat)
        #expect(BrowserAgentProvider.lmStudio.dialect == .openAICompatibleChat)
        #expect(BrowserAgentProvider.compatible.dialect == .openAICompatibleChat)
        #expect(BrowserAgentProvider.gemini.endpoint(model: "gemini-custom") ==
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-custom:streamGenerateContent?alt=sse")
        #expect(BrowserAgentProvider.gemini.endpointIdentity(model: "gemini-custom") ==
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-custom:streamGenerateContent")
    }

    @Test func builtInAgentToolCatalogueIsUniqueAndComplete() {
        let names = BrowserAgent.builtInToolNames
        #expect(names.count == 45)
        #expect(Set(names).count == names.count)
        #expect(names.contains("take_snapshot"))
        #expect(names.contains("wait_for"))
        #expect(names.contains("observe_webkit_signals"))
        #expect(names.contains("wait_for_webkit_signal"))
        #expect(names.contains("delegate_child_run"))
        #expect(names.contains("inspect_run_group"))
        #expect(names.contains("cancel_child_run"))
        #expect(names.contains("create_bookmark"))
        #expect(names.contains("write_file"))
        #expect(names.contains("delete_file"))
        #expect(names.contains("commit_cowork_transaction"))
        #expect(names.contains("rollback_cowork_transaction"))
        #expect(names.contains("propose_agent_memory"))
        #expect(names.contains("search_agent_memory"))
        #expect(names.contains("forget_agent_memory"))
    }

    @Test func articleCountQuestionsReceiveAnArticleIndexInsteadOfGenericMainText() {
        #expect(AgentLocalPageRouter.heuristicCommand(
            for: "How many articles on this page are about Apple?"
        ) == .articleIndex)
        #expect(AgentLocalPageRouter.heuristicCommand(
            for: "Summarize this article"
        ) == .mainText)
    }

    @Test func referentialFollowUpsKeepTheEarlierPageQuestionAndTopic() {
        let routingPrompt = AgentConversationPageIntent.routingPrompt(
            current: "What are they?",
            recentUserMessages: ["How many articles on this page are about Apple?"]
        )
        #expect(AgentLocalPageRouter.heuristicCommand(for: routingPrompt) == .articleIndex)

        let candidates = [
            AgentArticleCandidate(
                title: "DeepSeek's AI models are about to cost four times more",
                url: "https://example.com/deepseek",
                context: "AI DeepSeek has announced price hikes"
            ),
            AgentArticleCandidate(
                title: "Apple proposes taking a cut from external App Store payments",
                url: "https://example.com/app-store",
                context: "Apple App Store payments"
            ),
            AgentArticleCandidate(
                title: "Apple sends warnings to targets of mercenary spyware attacks",
                url: "https://example.com/spyware",
                context: "Cybersecurity Apple warnings"
            ),
            AgentArticleCandidate(
                title: "Apple is reportedly turning to publishers for help with Siri AI",
                url: "https://example.com/siri",
                context: "Apple Siri AI"
            ),
            AgentArticleCandidate(
                title: "You can now watch classic movies on Apple TV",
                url: "https://example.com/apple-tv",
                context: "News Apple TV streaming"
            ),
        ]
        let index = AgentArticleIndexFormatter.content(
            candidates: candidates,
            prompt: routingPrompt
        )
        #expect(index.contains("Topic-matching article candidates (4)"))
        #expect(index.contains("App Store payments"))
        #expect(index.contains("mercenary spyware"))
        #expect(index.contains("Siri AI"))
        #expect(index.contains("Apple TV"))
        #expect(!index.contains("Topic match 1. DeepSeek"))
    }

    @Test func indirectArticleQuestionsRequireWholePageResearch() async throws {
        let question = "Are there other articles that indirectly reference Apple?"
        #expect(AgentLocalPageRouter.heuristicCommand(for: question) == .articleResearch)
        #expect(AgentArticleResearchRequirement.infer(from: question)?.minimumVerifiedPages == 2)

        let evidence = AgentArticlePageEvidence(
            candidates: [
                AgentArticleCandidate(
                    title: "A rare Computer Space arcade machine is up for auction",
                    url: "https://example.com/computer-space",
                    context: "A retro tech auction focused on Steve Jobs and the computer revolution."
                ),
            ],
            pageText: String(repeating: "Earlier page content. ", count: 700)
                + "Later story: the auction is focused on Steve Jobs."
        )
        let formatted = AgentArticleIndexFormatter.researchContent(
            evidence: evidence,
            prompt: question
        )
        #expect(formatted.contains("All rendered article candidates (1)"))
        #expect(formatted.contains("Later story: the auction is focused on Steve Jobs."))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-related-research-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let adapter = RelatedArticleResearchProviderAdapter()
        let recorder = ResearchToolRecorder()
        let agent = BrowserAgent(
            storageDirectory: directory,
            runStore: store,
            providerAdapterFactory: { _ in adapter }
        )

        agent.submit(
            question + "\n\nLocal page context (article research): candidate URLs supplied.",
            displayPrompt: question,
            pageTitle: "Engadget",
            pageURL: "https://www.engadget.com/",
            configuration: fixtureConfiguration(),
            resolvePageAuthority: { pageIDs in
                await recorder.resolve(pageIDs: pageIDs)
            },
            execute: { tool, arguments, _, _ in
                await recorder.execute(
                    tool: tool,
                    url: arguments["url"] as? String,
                    pageID: arguments["pageId"] as? String
                )
            }
        )
        try await waitWhile { agent.isRunning }

        #expect(adapter.recordedRequests().count == 4)
        let researchToolNames = await recorder.toolNames
        #expect(Array(researchToolNames.prefix(4)) == [
            "new_hidden_page", "new_hidden_page",
            "get_page_content", "get_page_content",
        ])
        #expect(researchToolNames.filter { $0 == "close_page" }.count == 2)
        #expect(!agent.messages.contains { $0.text == "Two articles are about Apple." })
        #expect(agent.messages.last?.text.contains("Steve Jobs") == true)
        #expect(agent.messages.last?.text.contains("indirect") == true)
    }

    @Test func tabOpeningRequestCannotFinishWithATextOnlyClaim() async throws {
        let requirement = AgentActionCompletionRequirement.infer(
            from: "Can you open them in new tabs?",
            evidencePrompt: "Topic-matching article candidates (4):\nTopic match 1. One"
        )
        #expect(requirement?.minimumSuccessfulCalls == 4)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-action-proof-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let adapter = ActionProofAgentProviderAdapter()
        let recorder = ToolExecutionRecorder()
        let agent = BrowserAgent(
            storageDirectory: directory,
            runStore: store,
            providerAdapterFactory: { _ in adapter }
        )

        agent.submit(
            "Can you open them in new tabs?",
            pageTitle: "Stories",
            pageURL: "https://example.com",
            configuration: fixtureConfiguration(),
            execute: { tool, _, _, _ in
                await recorder.recordAndReturnPage(tool: tool)
            }
        )
        try await waitWhile { agent.isRunning }

        #expect(adapter.recordedRequests().count == 3)
        #expect(await recorder.toolNames == ["new_page", "new_page"])
        #expect(!agent.messages.contains { $0.text == "I opened them." })
        #expect(agent.messages.last?.text == "Opened both Apple stories in background tabs.")
    }

    @Test func offerDateQuestionsCannotBeReroutedToArticleContent() {
        #expect(AgentLocalPageRouter.heuristicCommand(
            for: "What dates is this good for?"
        ) == .offerValidity)
        #expect(AgentLocalPageRouter.heuristicCommand(
            for: "When does this offer expire?"
        ) == .offerValidity)
    }

    @Test func appleIntelligenceDefaultsToACompactUsefulAnswer() {
        let instructions = AppleIntelligenceResponsePolicy.instructions(
            base: "General browser safety instructions"
        )
        #expect(instructions.contains("two to four sentences"))
        #expect(instructions.contains("No greeting"))
        #expect(instructions.contains("name the matching items"))
        #expect(instructions.contains("relative date"))
        #expect(instructions.count <= AppleIntelligenceResponsePolicy.maximumInstructionCharacters)
    }

    @Test func chatScopesAndSlashCommandsAreStableAndKeyboardParseable() {
        let first = AgentConversationScope.site(
            pageURL: "https://Example.COM/inbox/message?id=1"
        )
        let second = AgentConversationScope.site(
            pageURL: "https://example.com/another/path"
        )
        #expect(first?.key == "site:https://example.com")
        #expect(first == second)
        #expect(AgentConversationScope.site(pageURL: "about:blank") == nil)
        #expect(AgentChatSlashCommand.parse("/clear") == .clear)
        #expect(AgentChatSlashCommand.parse("/resume birthday") == .resume(query: "birthday"))
        #expect(AgentChatSlashCommand.parse("/continuous") == .continuous)
        #expect(AgentChatSlashCommand.parse("/site") == .site)
        #expect(AgentChatSlashCommand.parse("/promote 2") == .promote(indexFromLatest: 2))
        #expect(AgentChatSlashCommand.parse("/promote nope") == nil)
    }

    @Test func continuousConversationActuallyIncludesPriorVisibleTurns() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-continuous-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let recorder = RequestRecordingAgentProviderAdapter(answer: "Remembered answer")
        let agent = BrowserAgent(
            storageDirectory: directory,
            runStore: store,
            providerAdapterFactory: { _ in recorder }
        )
        agent.startNewConversation(scopeKey: AgentConversationScope.continuousKey)

        for prompt in ["First question", "Follow-up question"] {
            agent.submit(
                prompt,
                pageTitle: "Test",
                pageURL: "https://example.com",
                configuration: fixtureConfiguration(),
                execute: { _, _, _, _ in "{}" }
            )
            try await waitWhile { agent.isRunning }
        }

        let requests = recorder.recordedRequests()
        let secondRequest = try #require(requests.last)
        let visibleText = secondRequest.messages.flatMap { message in
            message.content.compactMap { part -> String? in
                guard case .text(let text) = part else { return nil }
                return text
            }
        }
        #expect(visibleText.contains("First question"))
        #expect(visibleText.contains("Remembered answer"))
        #expect(visibleText.contains("Follow-up question"))
    }

    @Test func siteAnswerCanBePromotedAndTheSiteChatResumed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-promote-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let siteKey = "site:https://example.com"
        let siteConversation = try await store.createConversation(
            title: "Example answer",
            scopeKey: siteKey
        )
        let run = try await store.createRun(
            conversationID: siteConversation.id,
            entryPoint: .attended
        )
        _ = try await store.transitionRun(run.id, to: .running, reason: "Test")
        let answer = try await store.appendStep(
            runID: run.id,
            kind: .modelText,
            summary: "Useful site-specific answer",
            payload: .object(["text": .string("Useful site-specific answer")]),
            redactionState: .retained
        )
        _ = try await store.transitionRun(run.id, to: .succeeded, reason: "Test")

        let agent = BrowserAgent(storageDirectory: directory, runStore: store)
        await agent.refreshHistory()
        await agent.openConversation(siteConversation.id)
        let promoted = await agent.promoteAssistantMessage(answer.id)
        #expect(promoted)

        let conversations = try await store.listConversations()
        let continuous = try #require(conversations.first {
            $0.scopeKey == AgentConversationScope.continuousKey
        })
        let promotedRuns = await store.listRuns(matching: AgentRunQuery(
            conversationID: continuous.id
        ))
        let promotedRun = try #require(promotedRuns.first)
        let promotedSteps = try await store.steps(runID: promotedRun.id)
        #expect(promotedSteps.contains { step in
            step.kind == .modelText && step.summary == "Useful site-specific answer"
        })

        agent.startNewConversation(scopeKey: siteKey)
        let resumed = await agent.resumeConversation(in: siteKey)
        #expect(resumed)
        #expect(agent.selectedConversationID == siteConversation.id)
    }

    @Test func activityPresentationCollapsesConsecutiveToolsWithReadableLabels() throws {
        let snapshot = BrowserAgentMessage(
            role: .tool,
            text: "",
            toolName: "take_snapshot"
        )
        let content = BrowserAgentMessage(
            role: .tool,
            text: "",
            toolName: "get_page_content"
        )
        let answer = BrowserAgentMessage(role: .assistant, text: "One article")

        let items = AgentActivityPresentation.items(from: [snapshot, content, answer])
        #expect(items.count == 2)
        guard case .activity(let group) = items[0] else {
            Issue.record("Expected the consecutive tool messages to become one activity group")
            return
        }
        #expect(group.messages.map(\.toolName) == ["take_snapshot", "get_page_content"])
        #expect(group.collapsedLabel == "Read the page · 2 steps")
        #expect(AgentActivityPresentation.label(for: "take_snapshot", active: false) == "Looked at the page")
        #expect(AgentActivityPresentation.label(for: "get_page_content", active: true) == "Reading the page")
        guard case .message(let projectedAnswer) = items[1] else {
            Issue.record("Expected the assistant answer to remain a normal message")
            return
        }
        #expect(projectedAnswer == answer)
    }

    @Test func failedJSONToolResultsAreMarkedAsErrorsForTheProvider() {
        let result = BrowserAgent.modelToolResult(
            callID: "call-1",
            toolName: "get_page_content",
            result: #"{"error":"page reading unavailable"}"#
        )
        #expect(result.isError)
        #expect(result.content == .object(["error": .string("page reading unavailable")]))

        let success = BrowserAgent.modelToolResult(
            callID: "call-2",
            toolName: "get_page_content",
            result: #"{"ok":true,"result":"Apple"}"#
        )
        #expect(!success.isError)
    }

    @Test func childPageCreationCannotExpandOriginOrSessionAuthority() {
        let scope = AgentRunScope(
            capabilities: [.browserControl],
            origins: ["https://allowed.example"],
            session: .normal
        )

        #expect(BrowserAgent.pageCreationDenial(
            arguments: [
                "url": "https://escaped.example/path",
                "incognito": false,
            ],
            scope: scope,
            restrictOrigin: true
        )?.contains("origin scope") == true)
        #expect(BrowserAgent.pageCreationDenial(
            arguments: [
                "url": "https://allowed.example/path",
                "incognito": true,
            ],
            scope: scope,
            restrictOrigin: true
        )?.contains("browser Session") == true)
        #expect(BrowserAgent.pageCreationDenial(
            arguments: [
                "url": "https://allowed.example/path",
                "incognito": false,
            ],
            scope: scope,
            restrictOrigin: true
        ) == nil)
    }

    @Test func schedulesCalculateAllSupportedCadences() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let minutes = BrowserAgentTaskDefinition(
            name: "Minutes",
            prompt: "Run",
            scheduleKind: .minutes,
            interval: 5,
            dailyHour: 8,
            dailyMinute: 0,
            now: now
        )
        let hours = BrowserAgentTaskDefinition(
            name: "Hours",
            prompt: "Run",
            scheduleKind: .hours,
            interval: 3,
            dailyHour: 8,
            dailyMinute: 0,
            now: now
        )
        let daily = BrowserAgentTaskDefinition(
            name: "Daily",
            prompt: "Run",
            scheduleKind: .daily,
            interval: 1,
            dailyHour: 9,
            dailyMinute: 30,
            now: now
        )

        #expect(minutes.nextRunAt.timeIntervalSince(now) == 300)
        #expect(hours.nextRunAt.timeIntervalSince(now) == 10_800)
        #expect(daily.nextRunAt > now)
        #expect(daily.nextRunAt.timeIntervalSince(now) <= 86_400)
        #expect(minutes.scheduleDescription == "Every 5 minutes")
        #expect(hours.scheduleDescription == "Every 3 hours")
        #expect(daily.scheduleDescription == "Daily at 09:30")

        let run = BrowserAgentTaskRun(startedAt: Date().addingTimeInterval(-1), status: .succeeded, output: "Done")
        #expect(run.status == .succeeded)
        #expect(run.finishedAt >= run.startedAt)
        let roundTrip = try JSONDecoder().decode(
            BrowserAgentTaskDefinition.self,
            from: JSONEncoder().encode(minutes)
        )
        #expect(roundTrip.id == minutes.id)
        #expect(roundTrip.scheduleKind == .minutes)
    }

    @Test func invalidModelConfigurationBecomesAVisibleAgentError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let agent = BrowserAgent(storageDirectory: directory, runStore: store)

        agent.submit(
            "Inspect this page",
            pageTitle: "Test",
            pageURL: "https://example.com",
            configuration: BrowserAgentConfiguration(
                provider: .compatible,
                endpoint: "",
                model: "",
                apiKey: ""
            ),
            execute: { _, _, _, _ in "{\"ok\":true}" }
        )
        try await waitWhile { agent.isRunning }

        #expect(!agent.isRunning)
        #expect(agent.messages.map(\.role) == [.user, .error])
        #expect(agent.messages.last?.text.contains("valid endpoint") == true)
        let runs = await store.listRuns()
        let run = try #require(runs.first)
        #expect(run.status == .failed)
        #expect(run.entryPoint == .attended)
        #expect(run.configuration.provider?.endpointIdentity == "invalid")
        let persistedSteps = try await store.steps(runID: run.id)
        #expect(persistedSteps.map(\.kind).contains(.userMessage))
        #expect(persistedSteps.map(\.kind).contains(.error))
        let transitionCount = persistedSteps.reduce(into: 0) { count, step in
            if step.kind == .stateTransition { count += 1 }
        }
        #expect(transitionCount == 2)

        let conversationID = try #require(run.conversationID)
        let reopened = BrowserAgent(storageDirectory: directory, runStore: store)
        await reopened.openConversation(conversationID)
        #expect(reopened.messages.map(\.role) == [.user, .error])
        #expect(reopened.messages.first?.id == agent.messages.first?.id)
        agent.clear()
        #expect(agent.messages.isEmpty)
    }

    @Test func appConnectionDefinitionRoundTripsWithoutPersistingSecrets() throws {
        let connection = BrowserAgentMCPConnection(
            name: "Calendar",
            endpoint: "http://127.0.0.1:8000/mcp"
        )
        let decoded = try JSONDecoder().decode(
            BrowserAgentMCPConnection.self,
            from: JSONEncoder().encode(connection)
        )
        #expect(decoded == connection)
        #expect(decoded.enabled)
    }

    @Test func normalizedProviderStreamUpdatesThePanelAndPersistsUsageAndFinish() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-stream-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let adapter = ScriptedAgentProviderAdapter(script: [
            .event(.responseStarted(id: "response-1")),
            .event(.textDelta("Hel")),
            .event(.textDelta("lo")),
            .event(.usage(.reported(
                inputTokens: 4,
                outputTokens: 2,
                totalTokens: 6,
                cachedInputTokens: nil
            ))),
            .event(.finished(.stop)),
        ])
        let agent = BrowserAgent(
            storageDirectory: directory,
            runStore: store,
            providerAdapterFactory: { _ in adapter }
        )

        agent.submit(
            "Say hello",
            pageTitle: "Test",
            pageURL: "https://example.com",
            configuration: fixtureConfiguration(apiKey: "never-persist-this-secret"),
            localContextMetadata: AgentLocalPageContext(
                command: .offerValidity,
                content: "Active for one full week after today."
            ).safeMetadata,
            execute: { _, _, _, _ in "{}" }
        )
        try await waitWhile { agent.isRunning }

        #expect(agent.messages.last?.role == .assistant)
        #expect(agent.messages.last?.text == "Hello")
        let persistedRuns = await store.listRuns()
        let run = try #require(persistedRuns.first)
        #expect(run.status == .succeeded)
        #expect(run.configuration.provider?.supportsStreaming == true)
        let steps = try await store.steps(runID: run.id)
        #expect(steps.filter { $0.kind == .modelText }.count == 2)
        #expect(steps.contains { $0.kind == .usage && $0.summary.contains("6 tokens") })
        #expect(steps.contains {
            $0.kind == .system && $0.summary == "Provider stream finished"
        })
        #expect(steps.contains { step in
            guard step.kind == .system,
                  step.summary == "Prepared local page context",
                  case .object(let payload) = step.payload else { return false }
            return payload["command"] == .string("offer_validity")
                && payload["relativeDateEvidence"] == .boolean(true)
        })
        let persisted = try persistedText(in: directory)
        #expect(!persisted.contains("never-persist-this-secret"))
    }

    @Test func completedIncognitoSubmissionRetainsPromptOnlyInMemory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-incognito-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let adapter = ScriptedAgentProviderAdapter(script: [
            .event(.responseStarted(id: "incognito-response")),
            .event(.textDelta("Private answer")),
            .event(.usage(.unknown)),
            .event(.finished(.stop)),
        ])
        let agent = BrowserAgent(
            storageDirectory: directory,
            runStore: store,
            providerAdapterFactory: { _ in adapter }
        )
        let promptMarker = "incognito-prompt-marker-\(UUID().uuidString)"

        agent.submit(
            promptMarker,
            pageTitle: "Private Page",
            pageURL: "https://private.example/path",
            configuration: fixtureConfiguration(),
            incognito: true,
            execute: { _, _, _, _ in "{}" }
        )
        try await waitWhile { agent.isRunning }

        #expect(!agent.isRunning)
        #expect(agent.messages.first?.text == promptMarker)
        #expect(agent.selectedConversationID == nil)
        #expect(try await store.listConversations().isEmpty)
        #expect(await store.listRuns().isEmpty)
        #expect(try !persistedText(in: directory).contains(promptMarker))
    }

    @Test func incognitoWaitingRunRemainsRecoverableUntilItBecomesTerminal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-incognito-waiting-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let run = try await store.createRun(
            conversationID: nil,
            entryPoint: .attended,
            incognito: true
        )
        _ = try await store.transitionRun(run.id, to: .running, reason: "Started")
        _ = try await store.transitionRun(
            run.id,
            to: .waitingForHuman,
            reason: "Waiting for explicit approval"
        )

        #expect(try await !BrowserAgentIncognitoRetention.discardTerminalRun(
            run.id,
            from: store,
            cleanupPrivateCoworkState: { _ in }
        ))
        #expect(await store.run(id: run.id)?.status == .waitingForHuman)
    }

    @Test func cancellationOfAProviderStreamCannotExecuteALaterTool() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-agent-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentRunStore(baseDirectory: directory)
        let counter = ToolExecutionCounter()
        let call = AgentToolCall(id: "late-call", index: 0, name: "take_snapshot")
        let adapter = ScriptedAgentProviderAdapter(script: [
            .event(.textDelta("Working")),
            .delay(nanoseconds: 5_000_000_000),
            .event(.toolCallStarted(call)),
            .event(.toolCallCompleted(call: call, arguments: .valid(.object([:])))),
            .event(.usage(.unknown)),
            .event(.finished(.toolCalls)),
        ])
        let agent = BrowserAgent(
            storageDirectory: directory,
            runStore: store,
            providerAdapterFactory: { _ in adapter }
        )

        agent.submit(
            "Inspect",
            pageTitle: "Test",
            pageURL: "https://example.com",
            configuration: fixtureConfiguration(),
            execute: { _, _, _, _ in
                await counter.increment()
                return "{}"
            }
        )
        try await waitWhile { agent.messages.last?.text != "Working" }
        agent.cancel()
        try await waitWhile { agent.isRunning }

        let executionCount = await counter.count
        let finalStatus = await store.listRuns().first?.status
        #expect(executionCount == 0)
        #expect(finalStatus == .cancelled)
    }

    @Test func newAgentSurfacesConstruct() {
        let agent = BrowserAgent(storageDirectory: FileManager.default.temporaryDirectory)
        let panel = BrowserAgentPanel(
            agent: agent,
            pageTitle: "Example",
            pageURL: "https://example.com",
            pageTarget: nil,
            onClose: {},
            resolvePageAuthority: { _ in nil },
            execute: { _, _, _, _ in "{}" }
        )
        _ = panel.body
        _ = BrowserAgentMCPConnectionsView().body
        _ = BrowserAgentTasksView().body
        _ = BrowserAgentAuditView().body
    }

    private func fixtureConfiguration(apiKey: String = "fixture-key") -> BrowserAgentConfiguration {
        BrowserAgentConfiguration(
            provider: .compatible,
            endpoint: "https://provider.invalid/v1/chat/completions",
            model: "fixture-model",
            apiKey: apiKey
        )
    }

    private func persistedText(in directory: URL) throws -> String {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var text = ""
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  let value = String(data: data, encoding: .utf8) else { continue }
            text += value
        }
        return text
    }
}

private actor ToolExecutionCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor ToolExecutionRecorder {
    private(set) var toolNames: [String] = []

    func recordAndReturnPage(tool: String) -> String {
        toolNames.append(tool)
        let windowID = UUID().uuidString
        let tabID = UUID().uuidString
        return """
        {"ok":true,"page":{"pageId":"\(windowID):\(tabID)","url":"https://example.com/apple-\(toolNames.count)","sessionKind":"normal"}}
        """
    }
}

private nonisolated enum ResearchPageFixture {
    static let windowID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    static let firstTabID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    static let secondTabID = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    static let firstPageID = "\(windowID):\(firstTabID)"
    static let secondPageID = "\(windowID):\(secondTabID)"
}

private actor ResearchToolRecorder {
    private(set) var toolNames: [String] = []

    func resolve(pageIDs: [String]) -> [BrowserAutomationPageAuthoritySnapshot]? {
        let known = Set([ResearchPageFixture.firstPageID, ResearchPageFixture.secondPageID])
        guard Set(pageIDs).isSubset(of: known) else { return nil }
        return pageIDs.map { pageID in
            BrowserAutomationPageAuthoritySnapshot(
                target: AgentPageTarget(
                    pageID: pageID,
                    origin: "https://example.com",
                    session: .normal
                ),
                document: PageDocumentGeneration(rawValue: UUID())
            )
        }
    }

    func execute(tool: String, url: String?, pageID: String?) -> String {
        toolNames.append(tool)
        switch tool {
        case "new_hidden_page":
            let url = url ?? ""
            let pageID = url.contains("computer-space")
                ? ResearchPageFixture.firstPageID
                : ResearchPageFixture.secondPageID
            return """
            {"ok":true,"page":{"pageId":"\(pageID)","url":"\(url)","sessionKind":"normal"}}
            """
        case "get_page_content":
            let pageID = pageID ?? ""
            if pageID == ResearchPageFixture.firstPageID {
                return "This auction covers Steve Jobs memorabilia and Apple history."
            }
            return "This story covers classic movies newly available on Apple TV."
        case "close_page":
            return "{\"ok\":true}"
        default:
            return "{\"error\":\"unexpected tool\"}"
        }
    }
}

private final class RelatedArticleResearchProviderAdapter: AgentProviderAdapter, @unchecked Sendable {
    let providerID = "related-article-research"
    let capabilities = AgentProviderCapabilities(Set(AgentProviderCapability.allCases))

    private let lock = NSLock()
    private var requests: [AgentModelRequest] = []

    func recordedRequests() -> [AgentModelRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func events(
        for request: AgentModelRequest
    ) throws -> AsyncThrowingStream<AgentModelEvent, Error> {
        try validateCapabilities(for: request)
        lock.lock()
        requests.append(request)
        let requestCount = requests.count
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.responseStarted(id: "related-research-\(requestCount)"))
            switch requestCount {
            case 1:
                continuation.yield(.textDelta("Two articles are about Apple."))
                continuation.yield(.finished(.stop))
            case 2:
                for (index, url) in [
                    "https://example.com/computer-space",
                    "https://example.com/apple-tv",
                ].enumerated() {
                    let call = AgentToolCall(
                        id: "research-page-\(index)",
                        index: index,
                        name: "new_hidden_page"
                    )
                    continuation.yield(.toolCallStarted(call))
                    continuation.yield(.toolCallCompleted(
                        call: call,
                        arguments: .valid(.object(["url": .string(url)]))
                    ))
                }
                continuation.yield(.finished(.toolCalls))
            case 3:
                for (index, pageID) in [
                    ResearchPageFixture.firstPageID,
                    ResearchPageFixture.secondPageID,
                ].enumerated() {
                    let call = AgentToolCall(
                        id: "research-read-\(index)",
                        index: index,
                        name: "get_page_content"
                    )
                    continuation.yield(.toolCallStarted(call))
                    continuation.yield(.toolCallCompleted(
                        call: call,
                        arguments: .valid(.object(["pageId": .string(pageID)]))
                    ))
                }
                continuation.yield(.finished(.toolCalls))
            default:
                continuation.yield(.textDelta(
                    "Yes—beyond the direct Apple stories, the auction article is indirectly related through Steve Jobs, while the movie story is directly tied to Apple TV."
                ))
                continuation.yield(.finished(.stop))
            }
            continuation.yield(.usage(.unknown))
            continuation.finish()
        }
    }
}

private final class ActionProofAgentProviderAdapter: AgentProviderAdapter, @unchecked Sendable {
    let providerID = "action-proof"
    let capabilities = AgentProviderCapabilities(Set(AgentProviderCapability.allCases))

    private let lock = NSLock()
    private var requests: [AgentModelRequest] = []

    func recordedRequests() -> [AgentModelRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func events(
        for request: AgentModelRequest
    ) throws -> AsyncThrowingStream<AgentModelEvent, Error> {
        try validateCapabilities(for: request)
        lock.lock()
        requests.append(request)
        let requestCount = requests.count
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.responseStarted(id: "action-proof-\(requestCount)"))
            switch requestCount {
            case 1:
                continuation.yield(.textDelta("I opened them."))
                continuation.yield(.finished(.stop))
            case 2:
                for index in 1...2 {
                    let call = AgentToolCall(
                        id: "new-page-\(index)",
                        index: index - 1,
                        name: "new_page"
                    )
                    continuation.yield(.toolCallStarted(call))
                    continuation.yield(.toolCallCompleted(
                        call: call,
                        arguments: .valid(.object([
                            "url": .string("https://example.com/apple-\(index)"),
                            "background": .boolean(true),
                        ]))
                    ))
                }
                continuation.yield(.finished(.toolCalls))
            default:
                continuation.yield(.textDelta("Opened both Apple stories in background tabs."))
                continuation.yield(.finished(.stop))
            }
            continuation.yield(.usage(.unknown))
            continuation.finish()
        }
    }
}

private final class RequestRecordingAgentProviderAdapter: AgentProviderAdapter, @unchecked Sendable {
    let providerID = "request-recorder"
    let capabilities = AgentProviderCapabilities(Set(AgentProviderCapability.allCases))

    private let lock = NSLock()
    private var requests: [AgentModelRequest] = []
    private let answer: String

    init(answer: String) {
        self.answer = answer
    }

    func recordedRequests() -> [AgentModelRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func events(
        for request: AgentModelRequest
    ) throws -> AsyncThrowingStream<AgentModelEvent, Error> {
        try validateCapabilities(for: request)
        lock.lock()
        requests.append(request)
        let requestCount = requests.count
        lock.unlock()
        let answer = self.answer
        return AsyncThrowingStream { continuation in
            continuation.yield(.responseStarted(id: "recorded-\(requestCount)"))
            continuation.yield(.textDelta(answer))
            continuation.yield(.usage(.unknown))
            continuation.yield(.finished(.stop))
            continuation.finish()
        }
    }
}
