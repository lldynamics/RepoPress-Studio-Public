import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchGeneralAIChatTests: XCTestCase {
  override func setUp() async throws {
    try await super.setUp()
    // Production defaults to automatic remote authorization. Tests that need
    // fail-closed fault injection install an explicit provider below.
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = nil
  }

  override func tearDown() async throws {
    AIOutboundPayloadApprovalBroker.shared.cancelPendingRequest()
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = nil
    AIOutboundPayloadApprovalBroker.shared.testingConfirmationDateProvider = nil
    try await super.tearDown()
  }

  func testConnectionProfileKeyAvailabilityIsScopedToDisplayedGeneralConnection() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchGeneralKeyAvailability-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.GeneralKeyAvailability.\(UUID().uuidString)",
      accountPrefix: "general-key-availability-tests",
      inMemory: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: tokenStore
    )
    let configured = store.createAIConnectionProfile(
      named: "已配置 Key",
      preset: .openAICompatible
    )
    let missing = store.createAIConnectionProfile(
      named: "未配置 Key",
      preset: .openAICompatible
    )
    try tokenStore.saveAIToken(
      "general-secret",
      forConnectionProfileID: configured.id
    )

    XCTAssertTrue(
      store.aiStore.aiKeyAvailability(
        forConnectionProfileID: configured.id
      ).hasToken
    )
    XCTAssertFalse(
      store.aiStore.aiKeyAvailability(
        forConnectionProfileID: missing.id
      ).hasToken
    )
  }

  func testGeneralRequestDoesNotReadCurrentDraftIntoEnvelopeOrKnowledgeQuery() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")
      )
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    let conversation = AIConversation(
      scope: .general,
      messages: [
        AIPublishingChatMessage(role: .user, content: "请解释 actor 隔离")
      ]
    )
    store.aiStore.aiConversations = [conversation]
    store.aiStore.activeAIConversationIDsByScope = ["general": conversation.id]

    let request = try await store.aiStore.generalAIChatRequest(for: conversation)

    XCTAssertFalse(request.context.includesImplicitArticleContext)
    XCTAssertTrue(request.context.explicitContextReferences.isEmpty)
    if let query = request.context.knowledgeContext?.query {
      XCTAssertEqual(query, "请解释 actor 隔离")
      XCTAssertFalse(query.contains(draft.title))
      XCTAssertFalse(query.contains(draft.bodyMarkdown))
    }
  }

  func testGeneralKnowledgePolicyOffRoutesToGeneralConversationAndSkipsRetrieval() async throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchGeneralKnowledgePolicy-\(UUID().uuidString).json")
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: persistenceURL
      )
    )
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let conversation = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation()
    )
    XCTAssertTrue(
      store.aiStore.setGeneralAIChatKnowledgePolicy(
        .off,
        conversationID: conversation.id
      )
    )
    let updatedConversation = try XCTUnwrap(
      store.aiStore.generalAIChatConversation(withID: conversation.id)
    )
    let userMessage = AIPublishingChatMessage(
      role: .user,
      content: "不要自动查资料库",
      contextMode: .general
    )
    var requestConversation = updatedConversation
    requestConversation.messages = [userMessage]

    let request = try await store.aiStore.generalAIChatRequest(for: requestConversation)

    XCTAssertEqual(updatedConversation.knowledgePolicy, .off)
    XCTAssertNil(request.context.knowledgeContext)
    XCTAssertFalse(request.context.includesImplicitArticleContext)
  }

  func testGeneralRequestIncludesOnlyExplicitlyReferencedArticleContext() async throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchGeneralExplicitReference-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = "明确附加的文章标题"
    draft.bodyMarkdown = "明确附加的文章正文"
    store.updateDraft(draft)
    let reference = AIContextReference.currentArticle(
      draftID: draft.id,
      title: draft.title,
      characterCount: draft.bodyMarkdown.count
    )
    let conversation = AIConversation(
      scope: .general,
      messages: [
        AIPublishingChatMessage(
          role: .user,
          content: "只看我明确附加的文章",
          contextMode: .general,
          contextReferences: [reference]
        )
      ]
    )

    let request = try await store.aiStore.generalAIChatRequest(for: conversation)

    XCTAssertEqual(request.context.explicitContextReferences, [reference])
    XCTAssertTrue(request.context.explicitContextPrompt?.contains("明确附加的文章正文") == true)
    XCTAssertFalse(request.context.includesImplicitArticleContext)
  }

  func testGeneralConversationCRUDKeepsConnectionBindingAndDoesNotCreateDrafts() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")
      )
    )
    let initialDraftCount = store.drafts.count
    let connection = store.activeAIConnectionProfile

    let first = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation(
        connectionProfileID: connection.id
      )
    )
    let second = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation(
        connectionProfileID: connection.id
      )
    )

    XCTAssertEqual(store.drafts.count, initialDraftCount)
    XCTAssertEqual(first.scope, .general)
    XCTAssertEqual(second.connectionProfileID, connection.id)
    XCTAssertEqual(store.aiStore.generalAIChatConversations().count, 2)
    XCTAssertEqual(store.aiStore.activeGeneralAIChatConversationID, second.id)

    XCTAssertTrue(store.aiStore.selectGeneralAIChatConversation(first.id))
    XCTAssertTrue(store.aiStore.archiveAIChatConversation(first.id))
    XCTAssertEqual(store.aiStore.generalAIChatConversations().count, 1)
    XCTAssertTrue(store.aiStore.restoreAIChatConversation(first.id))
    XCTAssertTrue(store.aiStore.deleteAIChatConversation(first.id))
    XCTAssertEqual(store.aiStore.generalAIChatConversations().map(\.id), [second.id])
  }

  func testConnectionProfileDeletionIsBlockedWhileGeneralConversationUsesIt() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchGeneralProfileDelete-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let profile = store.createAIConnectionProfile(
      named: "通用会话专用档案",
      preset: .custom
    )
    let conversation = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation(connectionProfileID: profile.id)
    )

    XCTAssertFalse(store.canDeleteAIConnectionProfile(profile.id))
    XCTAssertFalse(store.deleteAIConnectionProfile(profile.id))
    XCTAssertNotNil(store.aiConnectionProfile(for: profile.id))
    XCTAssertTrue(
      store.aiActionMessage?.contains("通用对话绑定") == true
        || store.aiActionMessage?.contains("通用对话") == true
    )
    XCTAssertEqual(
      store.aiStore.generalAIChatConversation(withID: conversation.id)?.connectionProfileID,
      profile.id
    )
  }

  func testMissingGeneralConnectionBindingFailsClosedForSendAndPreservesMessageState() async throws
  {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: FileManager.default.temporaryDirectory
          .appendingPathComponent("WorkbenchGeneralMissingProfileSend-\(UUID().uuidString).json")
      )
    )
    let conversation = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation()
    )
    var missingBinding = conversation
    missingBinding.connectionProfileID = UUID()
    store.aiStore.aiConversations = [missingBinding]
    store.aiStore.activeAIConversationIDsByScope = ["general": conversation.id]

    let reply = await store.aiStore.sendGeneralAIChatMessage(
      "保留这条输入",
      conversationID: conversation.id
    )

    XCTAssertNil(reply)
    XCTAssertTrue(
      store.aiStore.generalAIChatConversation(withID: conversation.id)?.messages.isEmpty == true
    )
    XCTAssertTrue(store.aiChatMessage?.contains("连接档案") == true)
    XCTAssertFalse(store.isAIChatRunning)
  }

  func testMissingGeneralConnectionBindingFailsClosedForRetryAndPreservesRetryState() async throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: FileManager.default.temporaryDirectory
          .appendingPathComponent("WorkbenchGeneralMissingProfileRetry-\(UUID().uuidString).json")
      )
    )
    let conversation = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation()
    )
    let userMessage = AIPublishingChatMessage(
      role: .user,
      content: "保留失败后的重试",
      contextMode: .general
    )
    var missingBinding = conversation
    missingBinding.connectionProfileID = UUID()
    missingBinding.messages = [userMessage]
    store.aiStore.aiConversations = [missingBinding]
    store.aiStore.activeAIConversationIDsByScope = ["general": conversation.id]
    let retryState = AIGeneralChatManualRetryState(
      conversationID: conversation.id,
      requiresDuplicateChargeConfirmation: false
    )
    store.aiStore.aiGeneralChatManualRetryState = retryState

    let reply = await store.aiStore.retryLastFailedGeneralAIChatReply(
      conversationID: conversation.id
    )

    XCTAssertNil(reply)
    XCTAssertEqual(store.aiStore.aiGeneralChatManualRetryState, retryState)
    XCTAssertEqual(
      store.aiStore.generalAIChatConversation(withID: conversation.id)?.messages,
      [userMessage]
    )
    XCTAssertTrue(store.aiChatMessage?.contains("连接档案") == true)
  }

  func testImageBudgetRejectsTwoAttachmentsBeforeTransportWithoutDroppingThem() async throws {
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let config = capabilitySupportedConfig(
      AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.example/v1",
        model: "image-budget-model",
        requiresAPIKey: false
      ),
      capabilities: [.visionInput]
    )
    let consentStore = AIDataSharingConsentStore()
    consentStore.grant(for: config)
    defer { consentStore.revoke(for: config) }
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchGeneralImageBudget-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: KeychainTokenStore(
        service: "PersonalSitePublisherMac.Tests.GeneralImageBudget.\(UUID().uuidString)",
        accountPrefix: "general-image-budget-tests",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consentStore
    )
    configureActiveAIConnection(in: store, config: config)
    let conversation = try XCTUnwrap(store.aiStore.startNewGeneralAIChatConversation())
    let attachments = [
      AIChatImageAttachment(
        filename: "first.png",
        mimeType: "image/png",
        data: Data(repeating: 1, count: 4_100_000)
      ),
      AIChatImageAttachment(
        filename: "second.png",
        mimeType: "image/png",
        data: Data(repeating: 2, count: 4_100_000)
      ),
    ]

    let reply = await store.aiStore.sendGeneralAIChatMessage(
      "图片合计超限",
      conversationID: conversation.id,
      imageAttachments: attachments
    )

    XCTAssertNil(reply)
    XCTAssertEqual(
      store.aiStore.generalAIChatConversation(withID: conversation.id)?.messages,
      []
    )
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
    XCTAssertTrue(store.aiChatMessage?.contains("8 MB") == true)
  }

  func testCancelledRemoteGeneralAuthorizationGatePerformsZeroTransport() async throws {
    let approvalBroker = AIOutboundPayloadApprovalBroker.shared
    approvalBroker.testingDecisionProvider = { _ in .cancel }
    defer { approvalBroker.testingDecisionProvider = nil }
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "general-cancel-model",
      requiresAPIKey: false
    )
    let consentStore = AIDataSharingConsentStore()
    consentStore.grant(for: config)
    defer { consentStore.revoke(for: config) }
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchGeneralPayloadCancel-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: KeychainTokenStore(
        service: "PSPMGeneralPayloadCancelTests.\(UUID().uuidString.prefix(8))",
        accountPrefix: "ai-test",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consentStore
    )
    configureActiveAIConnection(in: store, config: config)
    let conversation = try XCTUnwrap(store.aiStore.startNewGeneralAIChatConversation())

    let reply = await store.aiStore.sendGeneralAIChatMessage(
      "这一轮不发送",
      conversationID: conversation.id
    )

    XCTAssertNil(reply)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testExpiredRemoteGeneralAuthorizationPerformsZeroTransport() async throws {
    let approvalBroker = AIOutboundPayloadApprovalBroker.shared
    approvalBroker.testingDecisionProvider = { _ in .confirm }
    approvalBroker.testingConfirmationDateProvider = { $0.expiresAt.addingTimeInterval(1) }
    defer { approvalBroker.testingConfirmationDateProvider = nil }
    let (store, transport, config, consentStore, persistenceURL) = makeRemoteGeneralPayloadStore(
      suffix: "Expired"
    )
    defer {
      consentStore.revoke(for: config)
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let conversation = try XCTUnwrap(store.aiStore.startNewGeneralAIChatConversation())

    let reply = await store.aiStore.sendGeneralAIChatMessage(
      "过期不发送",
      conversationID: conversation.id
    )

    XCTAssertNil(reply)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testDriftedRemoteGeneralAuthorizationPerformsZeroTransport() async throws {
    let approvalBroker = AIOutboundPayloadApprovalBroker.shared
    let (store, transport, config, consentStore, persistenceURL) = makeRemoteGeneralPayloadStore(
      suffix: "Drifted"
    )
    defer {
      consentStore.revoke(for: config)
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let conversation = try XCTUnwrap(store.aiStore.startNewGeneralAIChatConversation())
    approvalBroker.testingDecisionProvider = { _ in
      store.aiStore.aiConversations = store.aiStore.aiConversations.map { candidate in
        guard candidate.id == conversation.id else { return candidate }
        var changed = candidate
        changed.reasoningLevel = candidate.reasoningLevel == .quick ? .deep : .quick
        return changed
      }
      return .confirm
    }
    defer { approvalBroker.testingDecisionProvider = nil }

    let reply = await store.aiStore.sendGeneralAIChatMessage(
      "漂移不发送",
      conversationID: conversation.id
    )

    XCTAssertNil(reply)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testExplicitArticleContextStillDetectsDriftWhileKnowledgeIsFrozen() async throws {
    let approvalBroker = AIOutboundPayloadApprovalBroker.shared
    let (store, transport, config, consentStore, persistenceURL) = makeRemoteGeneralPayloadStore(
      suffix: "ExplicitArticleDrift"
    )
    defer {
      consentStore.revoke(for: config)
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = "授权前文章"
    draft.bodyMarkdown = "授权前正文"
    store.updateDraft(draft)
    let reference = AIContextReference.currentArticle(
      draftID: draft.id,
      title: draft.title,
      characterCount: draft.bodyMarkdown.count
    )
    let conversation = try XCTUnwrap(store.aiStore.startNewGeneralAIChatConversation())
    approvalBroker.testingDecisionProvider = { _ in
      guard var changedDraft = store.drafts.first(where: { $0.id == draft.id }) else {
        return .cancel
      }
      changedDraft.bodyMarkdown = "授权期间已修改的正文"
      store.updateDraft(changedDraft)
      return .confirm
    }
    defer { approvalBroker.testingDecisionProvider = nil }

    let reply = await store.aiStore.sendGeneralAIChatMessage(
      "检查显式文章上下文",
      conversationID: conversation.id,
      contextReferences: [reference]
    )

    XCTAssertNil(reply)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func
    testGeneralConversationSendsWithoutDraftAndStreamsIntoScopedHistoryWithoutPerRequestPayloadPrompt()
    async throws
  {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"通用"}}]}"#,
        "",
        #"data: {"choices":[{"delta":{"content":"回复"},"finish_reason":"stop"}]}"#,
        "",
      ]
    )
    let config = capabilitySupportedConfig(
      AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.example/v1",
        model: "general-test-model",
        requiresAPIKey: false
      ),
      capabilities: [.streamingResponse]
    )
    let consentStore = AIDataSharingConsentStore()
    consentStore.grant(for: config)
    defer { consentStore.revoke(for: config) }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")
      ),
      keychainTokenStore: KeychainTokenStore(
        service: "PSPMGeneralChatTests.\(UUID().uuidString.prefix(8))",
        accountPrefix: "ai-test",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consentStore
    )
    configureActiveAIConnection(in: store, config: config)
    let initialDraftCount = store.drafts.count

    let reply = await store.aiStore.sendGeneralAIChatMessage(
      "不依赖文章回答我。"
    )

    XCTAssertEqual(reply?.content, "通用回复")
    XCTAssertEqual(store.drafts.count, initialDraftCount)
    let conversation: AIConversation = try XCTUnwrap(
      store.aiStore.activeGeneralAIChatConversation
    )
    XCTAssertEqual(conversation.scope, .general)
    XCTAssertEqual(conversation.connectionProfileID, store.activeAIConnectionProfile.id)
    XCTAssertEqual(conversation.messages.map(\.content), ["不依赖文章回答我。", "通用回复"])
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(AIOutboundPayloadApprovalBroker.shared.pendingRequestCountForTesting, 0)

    let requestValue = await transport.capturedRequest()
    let request = try XCTUnwrap(requestValue)
    let body = try XCTUnwrap(request.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let serializedMessages = messages.compactMap { $0["content"] as? String }.joined(
      separator: "\n")
    XCTAssertTrue(serializedMessages.contains("不依赖文章回答我。"))
    XCTAssertFalse(serializedMessages.contains("当前 Mac 工作台上下文"))
  }

  func testGeneralToolCallingOnlyCreatesDraftThenReturnsReplyInGeneralConversation() async throws {
    let transport = SequencedGeneralAIChatTransport(responses: [
      functionResponse(
        name: "createDraft",
        arguments: ["value": "通用新建文章"]
      ),
      textResponse("已在本地新建空白文章。"),
    ])
    let baseConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "general-agent-model",
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(allowsApplicationTools: true)
    )
    let config = capabilitySupportedConfig(baseConfig, capabilities: [.toolCalling])
    let consentStore = AIDataSharingConsentStore()
    consentStore.grant(for: config)
    defer { consentStore.revoke(for: config) }
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchGeneralAgent-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: KeychainTokenStore(
        service: "WorkbenchGeneralAgent.\(UUID().uuidString.prefix(8))",
        accountPrefix: "general-agent",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consentStore
    )
    configureActiveAIConnection(in: store, config: config)
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in .confirm }
    defer { AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = nil }
    let originalDraftCount = store.drafts.count
    let conversation = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation()
    )
    XCTAssertTrue(
      store.aiStore.setGeneralAIChatKnowledgePolicy(
        .off,
        conversationID: conversation.id
      )
    )

    let reply = await store.aiStore.sendGeneralAIChatMessage(
      "请直接新建一篇通用新建文章",
      conversationID: conversation.id
    )

    XCTAssertEqual(reply?.content, "已在本地新建空白文章。")
    XCTAssertEqual(reply?.toolRuns.map(\.command), [.createDraft])
    XCTAssertEqual(reply?.toolRuns.map(\.status), [.succeeded])
    XCTAssertEqual(store.drafts.count, originalDraftCount + 1)
    let createdDraft = try XCTUnwrap(store.selectedDraft)
    XCTAssertEqual(createdDraft.title, "通用新建文章")
    XCTAssertEqual(
      store.aiStore.activeGeneralAIChatConversation?.messages.map(\.content),
      ["请直接新建一篇通用新建文章", "已在本地新建空白文章。"]
    )
    let record = try XCTUnwrap(store.automationRunRecords.first)
    XCTAssertEqual(record.steps.first?.command, .createDraft)
    XCTAssertEqual(record.steps.first?.targetDraftID, createdDraft.id)
    let bodies = await transport.capturedBodies()
    XCTAssertEqual(bodies.count, 2)
    let first = try jsonBody(bodies[0])
    let tools = try XCTUnwrap(first["tools"] as? [[String: Any]])
    XCTAssertEqual(
      tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String },
      ["createDraft"]
    )
    let second = try jsonBody(bodies[1])
    let messages = try XCTUnwrap(second["messages"] as? [[String: Any]])
    XCTAssertTrue(messages.contains { message in
      (message["role"] as? String) == "tool"
        && (message["content"] as? String)?.contains(createdDraft.id.uuidString) == true
    })
  }

  func testGeneralToolCallingSearchesOnlyRemoteAllowedKnowledgeThenReturnsReply() async throws {
    let transport = SequencedGeneralAIChatTransport(responses: [
      functionResponse(
        name: "knowledgeSearch",
        arguments: ["query": "Agent 资料边界"]
      ),
      textResponse("已根据允许使用的资料回答。"),
    ])
    let baseConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "general-knowledge-agent-model",
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(allowsApplicationTools: true)
    )
    let config = capabilitySupportedConfig(baseConfig, capabilities: [.toolCalling])
    let consentStore = AIDataSharingConsentStore()
    consentStore.grant(for: config)
    defer { consentStore.revoke(for: config) }
    let directory = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "WorkbenchGeneralKnowledgeAgent"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let knowledgeLibrary = KnowledgeLibraryService(
      rootURL: directory.appendingPathComponent("knowledge", isDirectory: true)
    )
    let allowedID = try await commitKnowledgeTestDocument(
      title: "允许的 Agent 资料",
      text: "Agent 资料边界：这段内容允许远程 AI 使用。",
      allowsRemoteAIUse: true,
      library: knowledgeLibrary
    )
    let deniedID = try await commitKnowledgeTestDocument(
      title: "私有 Agent 资料",
      text: "Agent 资料边界：这段私有内容不能发送。",
      allowsRemoteAIUse: false,
      library: knowledgeLibrary
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")
      ),
      knowledgeLibraryService: knowledgeLibrary,
      keychainTokenStore: KeychainTokenStore(
        service: "WorkbenchGeneralKnowledgeAgent.\(UUID().uuidString.prefix(8))",
        accountPrefix: "general-knowledge-agent",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consentStore
    )
    configureActiveAIConnection(in: store, config: config)
    await store.knowledge.reload()
    let conversation = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation()
    )

    let reply = await store.aiStore.sendGeneralAIChatMessage(
      "请搜索 Agent 资料边界后回答。",
      conversationID: conversation.id
    )

    XCTAssertEqual(reply?.content, "已根据允许使用的资料回答。")
    XCTAssertEqual(reply?.toolRuns.map(\.command), [.knowledgeSearch])
    XCTAssertEqual(reply?.toolRuns.map(\.status), [.succeeded])
    XCTAssertTrue(store.automationRunRecords.isEmpty)
    let bodies = await transport.capturedBodies()
    XCTAssertEqual(bodies.count, 2)
    let second = try jsonBody(bodies[1])
    let messages = try XCTUnwrap(second["messages"] as? [[String: Any]])
    let toolContent = try XCTUnwrap(
      messages.first(where: { ($0["role"] as? String) == "tool" })?["content"] as? String
    )
    XCTAssertTrue(toolContent.contains(allowedID.uuidString))
    XCTAssertFalse(toolContent.contains(deniedID.uuidString))
  }

  func testGeneralExplicitKnowledgeRevocationDuringAuthorizationPerformsZeroTransport()
    async throws
  {
    let directory = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "WorkbenchGeneralExplicitKnowledgeRevocation"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let knowledgeLibrary = KnowledgeLibraryService(
      rootURL: directory.appendingPathComponent("knowledge", isDirectory: true)
    )
    let documentID = try await commitKnowledgeTestDocument(
      title: "通用显式资料",
      text: "通用对话显式资料撤权后不应再发送任何请求。",
      allowsRemoteAIUse: true,
      library: knowledgeLibrary
    )
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let config = capabilitySupportedConfig(
      AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.example/v1",
        model: "general-explicit-revocation",
        requiresAPIKey: false
      ),
      capabilities: [.streamingResponse]
    )
    let consentStore = AIDataSharingConsentStore(
      storageKey: "GeneralExplicitKnowledgeRevocation.\(UUID().uuidString)"
    )
    consentStore.grant(for: config)
    defer { consentStore.revoke(for: config) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")
      ),
      knowledgeLibraryService: knowledgeLibrary,
      keychainTokenStore: KeychainTokenStore(
        service: "GeneralExplicitKnowledgeRevocation.\(UUID().uuidString)",
        accountPrefix: "general-explicit-revocation",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consentStore
    )
    configureActiveAIConnection(in: store, config: config)
    await store.knowledge.reload()
    let conversation = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation()
    )
    XCTAssertTrue(
      store.aiStore.setGeneralAIChatKnowledgePolicy(
        .off,
        conversationID: conversation.id
      )
    )
    let reference = AIContextReference.knowledgeEntry(
      documentID: documentID,
      title: "通用显式资料",
      characterCount: 100
    )
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in
      try? knowledgeLibrary.setAllowsRemoteAIUse(false, documentID: documentID)
      return .confirm
    }
    defer { AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = nil }

    let reply = await store.aiStore.sendGeneralAIChatMessage(
      "请只使用这份显式资料。",
      conversationID: conversation.id,
      contextReferences: [reference]
    )

    XCTAssertNil(reply)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
    XCTAssertEqual(
      store.aiChatMessage,
      "资料权限或版本已变化，本次未发送，请重新生成。"
    )
  }

  func testGeneralConversationTextOnlyModeDoesNotDeclareAgentTools() async throws {
    let transport = SequencedGeneralAIChatTransport(responses: [
      textResponse("仅用文字回答。")
    ])
    let baseConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "general-text-only-model",
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(allowsApplicationTools: true)
    )
    let config = capabilitySupportedConfig(baseConfig, capabilities: [.toolCalling])
    let consentStore = AIDataSharingConsentStore()
    consentStore.grant(for: config)
    defer { consentStore.revoke(for: config) }
    let directory = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "WorkbenchGeneralTextOnly"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")
      ),
      keychainTokenStore: KeychainTokenStore(
        service: "WorkbenchGeneralTextOnly.\(UUID().uuidString.prefix(8))",
        accountPrefix: "general-text-only",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consentStore
    )
    configureActiveAIConnection(in: store, config: config)
    let conversation = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation()
    )
    XCTAssertTrue(
      store.aiStore.setAIConversationAgentMode(.textOnly, for: conversation.id)
    )

    let reply = await store.aiStore.sendGeneralAIChatMessage(
      "不要使用工具。",
      conversationID: conversation.id
    )

    XCTAssertEqual(reply?.content, "仅用文字回答。")
    let bodies = await transport.capturedBodies()
    XCTAssertEqual(bodies.count, 1)
    XCTAssertNil(try jsonBody(try XCTUnwrap(bodies.first))["tools"])
  }

  func testGeneralConversationCancellationKeepsUserMessageAndAllowsRetry() async throws {
    let responseData = Data(
      #"{"model":"general-test-model","choices":[{"message":{"role":"assistant","content":"迟到的通用回复"}}]}"#
        .utf8
    )
    let transport = DelayedAIChatTransport(
      data: responseData,
      statusCode: 200,
      delayNanoseconds: 80_000_000
    )
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "general-test-model",
      requiresAPIKey: false
    )
    let consentStore = AIDataSharingConsentStore()
    consentStore.grant(for: config)
    defer { consentStore.revoke(for: config) }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")
      ),
      keychainTokenStore: KeychainTokenStore(
        service: "PSPMGeneralCancelTests.\(UUID().uuidString.prefix(8))",
        accountPrefix: "ai-test",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consentStore
    )
    configureActiveAIConnection(in: store, config: config)

    let canceledSubmission = Task {
      await store.aiStore.sendGeneralAIChatMessage("请取消这次通用请求")
    }
    for _ in 0..<100 {
      if await transport.capturedRequestCount() > 0 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    store.cancelAIChatReply()
    let canceledReply = await canceledSubmission.value

    XCTAssertNil(canceledReply)
    XCTAssertEqual(
      store.aiStore.activeGeneralAIChatConversation?.messages.map(\.content),
      ["请取消这次通用请求"]
    )
    XCTAssertEqual(store.aiChatMessage, "AI 回复已停止。")
    XCTAssertFalse(store.isAIChatRunning)

    let nextReply = await store.aiStore.sendGeneralAIChatMessage("请再次回答")

    XCTAssertEqual(nextReply?.content, "迟到的通用回复")
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 2)
  }

  func testGeneralConversationManualRetryReusesConversationAfterTransientFailure() async throws {
    var authorizationDecisionCount = 0
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in
      authorizationDecisionCount += 1
      return .confirm
    }
    let transport = ScriptedAIChatStreamingTransport(
      attempts: [
        ScriptedAIChatStreamAttempt(statusCode: 503),
        ScriptedAIChatStreamAttempt(
          lines: [
            #"data: {"choices":[{"delta":{"content":"重试成功"},"finish_reason":"stop"}]}"#,
            "",
          ]
        ),
      ]
    )
    let config = capabilitySupportedConfig(
      AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.example/v1",
        model: "general-test-model",
        requiresAPIKey: false
      ),
      capabilities: [.streamingResponse]
    )
    let consentStore = AIDataSharingConsentStore()
    consentStore.grant(for: config)
    defer { consentStore.revoke(for: config) }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")
      ),
      keychainTokenStore: KeychainTokenStore(
        service: "PSPMGeneralRetryTests.\(UUID().uuidString.prefix(8))",
        accountPrefix: "ai-test",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(
          transport: transport,
          networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
            maximumAutomaticRetryCount: 0
          )
        )
      ),
      aiDataSharingConsentStore: consentStore
    )
    configureActiveAIConnection(in: store, config: config)

    let firstReply = await store.aiStore.sendGeneralAIChatMessage("第一次请求")

    XCTAssertNil(firstReply)
    XCTAssertEqual(
      store.aiStore.activeGeneralAIChatConversation?.messages.map(\.content), ["第一次请求"])
    XCTAssertNotNil(store.aiStore.aiGeneralChatManualRetryState)
    XCTAssertEqual(authorizationDecisionCount, 1)

    let retriedReply = await store.aiStore.retryLastFailedGeneralAIChatReply()

    XCTAssertEqual(retriedReply?.content, "重试成功")
    XCTAssertNil(store.aiStore.aiGeneralChatManualRetryState)
    XCTAssertEqual(authorizationDecisionCount, 2)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 2)
  }

  func testGeneralConversationModelSelectionIsPersistedPerConversation() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchGeneralModelSelection-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let conversation = try XCTUnwrap(store.aiStore.startNewGeneralAIChatConversation())

    XCTAssertTrue(
      store.aiStore.setGeneralAIChatModelGrade(
        .highQuality,
        conversationID: conversation.id
      )
    )
    let updated = try XCTUnwrap(
      store.aiStore.generalAIChatConversations(includingArchived: true)
        .first(where: { $0.id == conversation.id })
    )
    XCTAssertEqual(updated.modelGrade, .highQuality)
    XCTAssertEqual(updated.scope, .general)
  }

  func testGeneralConversationReasoningLevelGetterAndSetterUseConversation() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchGeneralReasoning-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let conversation = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation()
    )

    XCTAssertEqual(store.aiStore.activeGeneralAIChatReasoningLevel, .deep)
    XCTAssertTrue(
      store.aiStore.setGeneralAIChatReasoningLevel(
        .standard,
        conversationID: conversation.id
      )
    )
    XCTAssertEqual(store.aiStore.activeGeneralAIChatReasoningLevel, .standard)
    XCTAssertEqual(
      store.aiStore.generalAIChatConversation(withID: conversation.id)?.reasoningLevel,
      .standard
    )
  }

  func testGeneralConversationSettingsTargetExplicitConversationWhenAnotherIsActive() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchGeneralExplicitSettings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let displayed = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation()
    )
    let active = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation()
    )
    XCTAssertEqual(store.aiStore.activeGeneralAIChatConversationID, active.id)

    XCTAssertTrue(
      store.aiStore.setGeneralAIChatReasoningLevel(
        .quick,
        conversationID: displayed.id
      )
    )
    XCTAssertTrue(
      store.aiStore.setGeneralAIChatKnowledgePolicy(
        .off,
        conversationID: displayed.id
      )
    )

    let updatedDisplayed = try XCTUnwrap(
      store.aiStore.generalAIChatConversation(withID: displayed.id)
    )
    let unchangedActive = try XCTUnwrap(
      store.aiStore.generalAIChatConversation(withID: active.id)
    )
    XCTAssertEqual(updatedDisplayed.reasoningLevel, .quick)
    XCTAssertEqual(updatedDisplayed.knowledgePolicy, .off)
    XCTAssertEqual(unchangedActive.reasoningLevel, .deep)
    XCTAssertEqual(unchangedActive.knowledgePolicy, .automatic)
  }

  func testGeneralConversationSettingsStayUnchangedWhileRequestIsRunning() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchGeneralRunningSettings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let conversation = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation()
    )
    let original = try XCTUnwrap(
      store.aiStore.generalAIChatConversation(withID: conversation.id)
    )
    let replacementProfile = store.createAIConnectionProfile(
      named: "运行中不应切换的档案",
      preset: .custom
    )
    let operationID = try XCTUnwrap(
      store.aiStore.beginAIChatOperation(
        statusMessage: "测试运行中",
        clearsManualRetryState: false
      )
    )
    defer { store.aiStore.finishAIChatOperation(operationID) }

    XCTAssertFalse(
      store.aiStore.setGeneralAIChatConnectionProfile(
        replacementProfile.id,
        conversationID: conversation.id
      )
    )
    XCTAssertFalse(
      store.aiStore.setGeneralAIChatKnowledgePolicy(
        .off,
        conversationID: conversation.id
      )
    )
    XCTAssertFalse(
      store.aiStore.setGeneralAIChatReasoningLevel(
        .quick,
        conversationID: conversation.id
      )
    )

    let unchanged = try XCTUnwrap(
      store.aiStore.generalAIChatConversation(withID: conversation.id)
    )
    XCTAssertEqual(unchanged.connectionProfileID, original.connectionProfileID)
    XCTAssertEqual(unchanged.knowledgePolicy, original.knowledgePolicy)
    XCTAssertEqual(unchanged.reasoningLevel, original.reasoningLevel)
    XCTAssertEqual(
      store.aiStore.activeGeneralAIChatReasoningLevel,
      original.reasoningLevel
    )
  }

  func testGeneralPartialRetrySecondFailureRestoresOriginalPartialAndRetryState() async throws {
    let transport = ScriptedAIChatStreamingTransport(
      attempts: [
        ScriptedAIChatStreamAttempt(
          lines: [#"data: {"choices":[{"delta":{"content":"第一次部分"}}]}"#, ""],
          terminalError: .connectionLost
        ),
        ScriptedAIChatStreamAttempt(
          lines: [#"data: {"choices":[{"delta":{"content":"第二次部分"}}]}"#, ""],
          terminalError: .connectionLost
        ),
      ]
    )
    let client = AIChatCompletionClient(
      transport: transport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        maximumAutomaticRetryCount: 0
      )
    )
    let config = capabilitySupportedConfig(
      AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.example/v1",
        model: "general-partial-retry-model",
        requiresAPIKey: false
      ),
      capabilities: [.streamingResponse]
    )
    let consentStore = AIDataSharingConsentStore()
    consentStore.grant(for: config)
    defer { consentStore.revoke(for: config) }
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchGeneralPartialRetry-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let keychainTokenStore = KeychainTokenStore(
      service: "PSPMGeneralPartialRetryTests.\(UUID().uuidString.prefix(8))",
      accountPrefix: "ai-general-partial-\(UUID().uuidString.prefix(8))",
      inMemory: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: keychainTokenStore,
      aiPublishingAssistantService: AIPublishingAssistantService(client: client),
      aiDataSharingConsentStore: consentStore
    )
    configureActiveAIConnection(in: store, config: config)

    let firstReply = await store.aiStore.sendGeneralAIChatMessage("请保留部分回复")

    XCTAssertEqual(firstReply?.content, "第一次部分")
    let originalConversation = try XCTUnwrap(
      store.aiStore.activeGeneralAIChatConversation
    )
    let originalRetryState = try XCTUnwrap(
      store.aiStore.aiGeneralChatManualRetryState
    )

    let secondReply = await store.aiStore.retryLastFailedGeneralAIChatReply(
      confirmingPossibleDuplicateCharge: true
    )

    XCTAssertEqual(secondReply?.content, "第二次部分")
    XCTAssertEqual(
      store.aiStore.activeGeneralAIChatConversation?.messages,
      originalConversation.messages
    )
    XCTAssertEqual(store.aiStore.aiGeneralChatManualRetryState, originalRetryState)
    XCTAssertTrue(store.aiChatMessage?.contains("失败") == true)
  }

  private func functionResponse(
    name: String,
    arguments: [String: Any]
  ) -> Data {
    let argumentsData = try! JSONSerialization.data(
      withJSONObject: arguments,
      options: [.sortedKeys]
    )
    let argumentsString = String(data: argumentsData, encoding: .utf8)!
    return try! JSONSerialization.data(withJSONObject: [
      "model": "general-agent-model",
      "choices": [[
        "message": [
          "role": "assistant",
          "content": "",
          "tool_calls": [[
            "id": "call-\(name)",
            "type": "function",
            "function": ["name": name, "arguments": argumentsString],
          ]],
        ],
        "finish_reason": "tool_calls",
      ]],
    ])
  }

  private func textResponse(_ content: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
      "model": "general-agent-model",
      "choices": [[
        "message": ["role": "assistant", "content": content],
        "finish_reason": "stop",
      ]],
    ])
  }

  private func commitKnowledgeTestDocument(
    title: String,
    text: String,
    allowsRemoteAIUse: Bool,
    library: KnowledgeLibraryService
  ) async throws -> UUID {
    let hash = KnowledgeChunkingService.contentHash(for: text)
    let candidate = KnowledgeImportCandidate(
      kind: .markdown,
      title: title,
      sourceName: "\(title).md",
      allowsRemoteAIUse: allowsRemoteAIUse,
      originalContentHash: hash,
      normalizedText: text,
      normalizedContentHash: hash,
      sections: [KnowledgeExtractedSection(headingPath: title, text: text)]
    )
    let result = try await library.commit(
      KnowledgeImportPreview(sourceName: "fixture", candidates: [candidate])
    )
    return try XCTUnwrap(result.documentIDs.first)
  }

  private func jsonBody(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func makeRemoteGeneralPayloadStore(
    suffix: String
  ) -> (
    store: WorkbenchStore,
    transport: RecordingAIChatTransport,
    config: AIProviderConfig,
    consentStore: AIDataSharingConsentStore,
    persistenceURL: URL
  ) {
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "general-payload-\(suffix.lowercased())",
      requiresAPIKey: false
    )
    let consentStore = AIDataSharingConsentStore()
    consentStore.grant(for: config)
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchGeneralPayload\(suffix)-\(UUID().uuidString).json")
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: KeychainTokenStore(
        service: "PSPMGeneralPayload\(suffix)Tests.\(UUID().uuidString.prefix(8))",
        accountPrefix: "ai-test",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consentStore
    )
    configureActiveAIConnection(in: store, config: config)
    return (store, transport, config, consentStore, persistenceURL)
  }

  private func configureActiveAIConnection(
    in store: WorkbenchStore,
    config: AIProviderConfig
  ) {
    var identityConfig = config
    identityConfig.capabilityProbeEvidence = nil
    var connection = store.activeAIConnectionProfile
    connection.config = identityConfig
    XCTAssertTrue(store.updateAIConnectionProfile(connection))
    connection = store.activeAIConnectionProfile
    connection.config = config
    XCTAssertTrue(store.updateAIConnectionProfile(connection))
  }

  private func capabilitySupportedConfig(
    _ base: AIProviderConfig,
    capabilities: Set<AIProviderCapabilityProbeKind>
  ) -> AIProviderConfig {
    var config = base
    let now = Date()
    let key = AIProviderCapabilityCacheKey(config: config)
    var evidence = config.capabilityProbeEvidence ?? [:]
    for capability in capabilities {
      evidence[capability] = AIProviderCapabilityProbeEvidence(
        key: key,
        capability: capability,
        outcome: .supported,
        observedAt: now,
        expiresAt: now.addingTimeInterval(60)
      )
    }
    config.capabilityProbeEvidence = evidence
    return config
  }
}

private actor SequencedGeneralAIChatTransport: AIChatTransport {
  private let responses: [Data]
  private var requests: [URLRequest] = []

  init(responses: [Data]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let index = requests.count
    requests.append(request)
    let responseData = responses[min(index, max(0, responses.count - 1))]
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )!
    return (responseData, response)
  }

  func capturedBodies() -> [Data] {
    requests.compactMap(\.httpBody)
  }
}
