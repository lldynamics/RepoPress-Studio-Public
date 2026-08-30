import Combine
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreAIChatStreamingTests: XCTestCase {
  override func setUp() async throws {
    // Production defaults to automatic remote authorization. Tests that need
    // fail-closed fault injection install an explicit provider below.
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = nil
    AIDataSharingConsentStore().grant(for: remoteAIConfig)
  }

  override func tearDown() async throws {
    AIOutboundPayloadApprovalBroker.shared.cancelPendingRequest()
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = nil
    AIOutboundPayloadApprovalBroker.shared.testingConfirmationDateProvider = nil
    AIDataSharingConsentStore().revoke(for: remoteAIConfig)
  }

  private var remoteAIConfig: AIProviderConfig {
    AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )
  }

  func testStoreStreamsAIChatReplyIntoCurrentConversationWithoutPerRequestPayloadPrompt()
    async throws
  {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"你"}}]}"#,
        "",
        #"data: {"choices":[{"delta":{"content":"好。"},"finish_reason":"stop"}],"#
          + #""usage":{"prompt_tokens":8,"completion_tokens":2,"total_tokens":10}}"#,
        "",
      ]
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )
    profile.aiProviderConfig = streamingSupportedConfig(profile.aiProviderConfig)
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)
    let expectedDraftConversation = AIChatDraftConversationExpectation(
      draftID: draft.id,
      conversation: nil
    )

    let reply = await store.ai.sendChatMessage(
      "打个招呼。",
      draft: draft,
      expectedContextMode: .site,
      expectedDraftConversation: expectedDraftConversation
    )

    XCTAssertEqual(reply?.content, "你好。")
    XCTAssertEqual(reply?.tokenUsage?.totalTokens, 10)
    XCTAssertEqual(store.aiChatMessages.count, 2)
    XCTAssertEqual(store.aiChatMessages[0].role, .user)
    XCTAssertEqual(store.aiChatMessages[1].role, .assistant)
    XCTAssertEqual(store.aiChatMessages[1].content, "你好。")
    XCTAssertEqual(store.aiChatMessage, "AI 已回复。")
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(AIOutboundPayloadApprovalBroker.shared.pendingRequestCountForTesting, 0)
    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(payload["stream"] as? Bool, true)
  }

  func testStreamingMessageReplacementsBypassRetentionUntilDurableBoundary() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest()
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    store.aiStore.prepareAIChat(for: draft)
    store.aiStore.updateAIChatSession(for: draft.id) { messages in
      messages.append(AIPublishingChatMessage(role: .assistant, content: "0"))
    }
    let identity = try XCTUnwrap(store.aiStore.aiChatConversationIdentity(for: draft.id))
    store.aiStore.aiConversationRetentionPassCount = 0
    let lifecycleRevision = store.aiStore.aiChatSessionLifecycleRevision

    for value in 1...100 {
      store.aiStore.updateAIChatSession(for: identity, streaming: true) { messages in
        messages[messages.count - 1].content = "\(value)"
      }
    }

    XCTAssertEqual(store.aiStore.aiConversationRetentionPassCount, 0)
    XCTAssertEqual(store.aiStore.aiChatSessionLifecycleRevision, lifecycleRevision)
    XCTAssertEqual(store.aiStore.aiChatSessionState(for: identity)?.messages.last?.content, "100")

    store.aiStore.updateAIChatSession(for: identity) { _ in }
    XCTAssertEqual(store.aiStore.aiConversationRetentionPassCount, 1)
    XCTAssertEqual(store.aiStore.aiChatSessionLifecycleRevision, lifecycleRevision + 1)
  }

  func testExpectedArticleContextChangeFailsClosedBeforeTransport() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    store.prepareAIChat(for: draft)
    store.setAIChatContextMode(.general)

    let reply = await store.ai.sendChatMessage(
      "仍按原文章上下文发送",
      draft: draft,
      expectedContextMode: .site
    )

    XCTAssertNil(reply)
    XCTAssertEqual(
      store.aiChatMessage,
      "AI 对话上下文已变化，本次未发送，请重试。"
    )
    let capturedRequestCount = await transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 0)
    XCTAssertTrue(store.aiChatMessages.isEmpty)
  }

  func testExpectedArticleRetryContextChangeFailsClosedBeforeTransport() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    let conversationID = try XCTUnwrap(store.startNewAIChatConversation(draft: draft)).id
    store.aiStore.aiChatManualRetryState = AIChatManualRetryState(
      draftID: draft.id,
      conversationID: conversationID,
      requiresDuplicateChargeConfirmation: false
    )
    store.setAIChatContextMode(.general)

    let reply = await store.ai.retryLastFailedChatReply(
      confirmingPossibleDuplicateCharge: false,
      draft: draft,
      expectedContextMode: .site
    )

    XCTAssertNil(reply)
    XCTAssertEqual(
      store.aiChatMessage,
      "AI 对话上下文已变化，本次未发送，请重试。"
    )
    let capturedRequestCount = await transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 0)
    XCTAssertNotNil(store.aiChatManualRetryState)
  }

  func testExpectedMissingArticleConversationChangeFailsClosedBeforeTransport() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    let expectedDraftConversation = AIChatDraftConversationExpectation(
      draftID: draft.id,
      conversation: nil
    )
    _ = try XCTUnwrap(
      store.startNewAIChatConversation(draft: draft)
    )

    let reply = await store.ai.sendChatMessage(
      "仍发往原对话",
      draft: draft,
      expectedContextMode: .site,
      expectedDraftConversation: expectedDraftConversation
    )

    XCTAssertNil(reply)
    XCTAssertEqual(
      store.aiChatMessage,
      "AI 对话上下文已变化，本次未发送，请重试。"
    )
    let capturedRequestCount = await transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 0)
    XCTAssertTrue(store.aiChatMessages.isEmpty)
    XCTAssertTrue(
      store.aiChatConversations(for: draft.id).allSatisfy(\.messages.isEmpty)
    )
  }

  func testExpectedArticleConversationClearFailsClosedBeforeTransport() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    _ = try XCTUnwrap(store.startNewAIChatConversation(draft: draft))
    store.aiStore.aiChatMessages = [
      AIPublishingChatMessage(role: .user, content: "清空前的历史")
    ]
    store.aiStore.cacheCurrentAIChatSessionForAIStore()
    let frozenConversation = try XCTUnwrap(
      store.aiStore.activeAIChatConversation(for: draft.id)
    )
    let expectedDraftConversation = AIChatDraftConversationExpectation(
      draftID: draft.id,
      conversation: frozenConversation
    )

    store.clearAIChat()
    XCTAssertTrue(store.aiChatMessages.isEmpty)

    let reply = await store.ai.sendChatMessage(
      "不应重新写入已清空的对话",
      draft: draft,
      expectedContextMode: .site,
      expectedDraftConversation: expectedDraftConversation
    )

    XCTAssertNil(reply)
    XCTAssertEqual(
      store.aiChatMessage,
      "AI 对话上下文已变化，本次未发送，请重试。"
    )
    let capturedRequestCount = await transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 0)
    XCTAssertTrue(store.aiChatMessages.isEmpty)
    XCTAssertTrue(
      try XCTUnwrap(store.aiStore.activeAIChatConversation(for: draft.id)).messages.isEmpty
    )
  }

  func testRemoteArticleRequestSerializationUsesMinimizedSanitizedPayload() async throws {
    let approvalBroker = AIOutboundPayloadApprovalBroker.shared
    var capturedPreview: AIOutboundPayloadPreview?
    approvalBroker.testingDecisionProvider = { preview in
      capturedPreview = preview
      return .confirm
    }
    defer { approvalBroker.testingDecisionProvider = nil }
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"完成"},"finish_reason":"stop"}]}"#,
        "",
      ]
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIOutboundSanitized-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    var outboundConfig = remoteAIConfig
    outboundConfig.advancedSettings = AIProviderAdvancedSettings(
      systemPrompt: """
        只保留必要说明。
        /Users/advanced-user/Private/instructions.md
        OPENAI_API_KEY=advanced-secret
        预览命令：zola serve --root /Users/advanced-user/Private
        """
    )
    profile.aiProviderConfig = outboundConfig
    store.updateActiveProfile(profile)
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.bodyMarkdown = """
      保留仓库相对路径 content/posts/example.md
      本机路径 /Users/bob/Projects/RepoPress/content/posts/example.md
      预览命令：zola serve --root /Users/bob/Projects/RepoPress
      """
    store.updateDraft(draft)
    let currentDraft = try XCTUnwrap(store.selectedDraft)

    _ = await store.sendAIChatMessage(
      "swift build --package-path /Users/bob/Projects/RepoPress API_KEY=private-value",
      draft: currentDraft
    )

    let recordedRequest = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(recordedRequest)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let requestText = try XCTUnwrap(String(data: body, encoding: .utf8))
      .replacingOccurrences(of: "\\/", with: "/")
    XCTAssertFalse(requestText.contains("/Users/"))
    XCTAssertFalse(requestText.contains("bob"))
    XCTAssertFalse(requestText.contains("zola serve"))
    XCTAssertFalse(requestText.contains("swift build"))
    XCTAssertFalse(requestText.contains("private-value"))
    XCTAssertFalse(requestText.contains("advanced-user"))
    XCTAssertFalse(requestText.contains("advanced-secret"))
    XCTAssertTrue(requestText.contains("content/posts/example.md"))
    let preview = try XCTUnwrap(capturedPreview)
    XCTAssertTrue(preview.sensitiveCategories.contains(.absoluteLocalPath))
    XCTAssertTrue(preview.sensitiveCategories.contains(.homeUsername))
    XCTAssertTrue(preview.sensitiveCategories.contains(.previewCommand))
    XCTAssertTrue(preview.sensitiveCategories.contains(.buildCommand))
    XCTAssertTrue(preview.sensitiveCategories.contains(.credentialLikeSecret))
  }

  func testCancelledRemoteArticleAuthorizationGatePerformsZeroTransport() async throws {
    let approvalBroker = AIOutboundPayloadApprovalBroker.shared
    approvalBroker.testingDecisionProvider = { _ in .cancel }
    defer { approvalBroker.testingDecisionProvider = nil }
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIOutboundCancelled-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = remoteAIConfig
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)

    let reply = await store.sendAIChatMessage("不发送", draft: draft)

    XCTAssertNil(reply)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testExpiredRemoteArticleAuthorizationPerformsZeroTransport() async throws {
    let approvalBroker = AIOutboundPayloadApprovalBroker.shared
    approvalBroker.testingDecisionProvider = { _ in .confirm }
    approvalBroker.testingConfirmationDateProvider = { $0.expiresAt.addingTimeInterval(1) }
    defer { approvalBroker.testingConfirmationDateProvider = nil }
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIOutboundExpired-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = remoteAIConfig
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)

    let reply = await store.sendAIChatMessage("过期不发送", draft: draft)

    XCTAssertNil(reply)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testDriftedRemoteArticleAuthorizationPerformsZeroTransport() async throws {
    let approvalBroker = AIOutboundPayloadApprovalBroker.shared
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIOutboundDrifted-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = remoteAIConfig
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)
    approvalBroker.testingDecisionProvider = { _ in
      guard var changedDraft = store.selectedDraft else { return .cancel }
      changedDraft.bodyMarkdown += "\n确认后发生了变化"
      store.updateDraft(changedDraft)
      return .confirm
    }
    defer { approvalBroker.testingDecisionProvider = nil }

    let reply = await store.sendAIChatMessage("漂移不发送", draft: draft)

    XCTAssertNil(reply)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testAdvancedPromptOrModelDriftPerformsZeroTransport() async throws {
    let approvalBroker = AIOutboundPayloadApprovalBroker.shared
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIOutboundAdvancedDrift-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "model-before-authorization",
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(systemPrompt: "prompt-before")
    )
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)
    approvalBroker.testingDecisionProvider = { _ in
      var changedProfile = store.activeProfile
      changedProfile.aiProviderConfig.model = "model-after-authorization"
      changedProfile.aiProviderConfig.advancedSettings?.systemPrompt = "prompt-after"
      store.updateActiveProfile(changedProfile)
      return .confirm
    }
    defer { approvalBroker.testingDecisionProvider = nil }

    let reply = await store.sendAIChatMessage("高级设置漂移", draft: draft)

    XCTAssertNil(reply)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testAdvancedSystemPromptOnlyDriftPerformsZeroTransport() async throws {
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIOutboundPromptOnlyDrift-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "unchanged-model",
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(systemPrompt: "prompt-before")
    )
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in
      var changedProfile = store.activeProfile
      changedProfile.aiProviderConfig.advancedSettings?.systemPrompt = "prompt-after"
      store.updateActiveProfile(changedProfile)
      return .confirm
    }

    let reply = await store.sendAIChatMessage("prompt-only drift", draft: draft)

    XCTAssertNil(reply)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testRevokingConsentWhileAuthorizationGateIsOpenPerformsZeroTransport() async throws {
    let (store, transport, config, consentStore, persistenceURL) =
      makeCredentialTOCTOUArticleStore(suffix: "ConsentRevoked")
    defer {
      consentStore.revoke(for: config)
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    var profile = store.activeProfile
    profile.aiProviderConfig = config
    store.updateActiveProfile(profile)
    XCTAssertTrue(consentStore.grant(for: config))
    XCTAssertTrue(store.saveAIAPIKey("initial-test-credential"))
    let draft = try XCTUnwrap(store.selectedDraft)
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in
      consentStore.revoke(for: config)
      return .confirm
    }

    let reply = await store.sendAIChatMessage("consent revoked", draft: draft)

    XCTAssertNil(reply)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testRemoteAIMasterSwitchOffPerformsZeroTransportWithGrantAndCredential() async throws {
    let (store, transport, config, consentStore, persistenceURL) =
      makeCredentialTOCTOUArticleStore(suffix: "RemoteMasterOff")
    defer {
      consentStore.revoke(for: config)
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    var profile = store.activeProfile
    profile.aiProviderConfig = config
    store.updateActiveProfile(profile)
    XCTAssertTrue(consentStore.grant(for: config))
    XCTAssertTrue(store.saveAIAPIKey("saved-but-blocked-credential"))
    consentStore.setRemoteAIEnabled(false)
    let draft = try XCTUnwrap(store.selectedDraft)

    let reply = await store.sendAIChatMessage("remote master off", draft: draft)

    XCTAssertNil(reply)
    XCTAssertFalse(consentStore.presentation(for: config).isGranted)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testDeletingCredentialWhileAuthorizationGateIsOpenPerformsZeroTransport() async throws {
    let (store, transport, config, consentStore, persistenceURL) =
      makeCredentialTOCTOUArticleStore(suffix: "CredentialDeleted")
    defer {
      consentStore.revoke(for: config)
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    var profile = store.activeProfile
    profile.aiProviderConfig = config
    store.updateActiveProfile(profile)
    XCTAssertTrue(consentStore.grant(for: config))
    XCTAssertTrue(store.saveAIAPIKey("initial-test-credential"))
    let draft = try XCTUnwrap(store.selectedDraft)
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in
      store.deleteAIAPIKey()
      return .confirm
    }

    let reply = await store.sendAIChatMessage("credential deleted", draft: draft)

    XCTAssertNil(reply)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testCredentialRotationDuringApprovalUsesOnlyCurrentCredential() async throws {
    let (store, transport, config, consentStore, persistenceURL) =
      makeCredentialTOCTOUArticleStore(suffix: "CredentialRotated")
    defer {
      consentStore.revoke(for: config)
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    var profile = store.activeProfile
    profile.aiProviderConfig = config
    store.updateActiveProfile(profile)
    XCTAssertTrue(consentStore.grant(for: config))
    let initialCredential = "initial-test-credential"
    let rotatedCredential = "rotated-test-credential"
    XCTAssertTrue(store.saveAIAPIKey(initialCredential))
    let draft = try XCTUnwrap(store.selectedDraft)
    var capturedPreview: AIOutboundPayloadPreview?
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { preview in
      capturedPreview = preview
      XCTAssertTrue(store.saveAIAPIKey(rotatedCredential))
      return .confirm
    }

    let reply = await store.sendAIChatMessage("credential rotated", draft: draft)

    XCTAssertEqual(reply?.content, "ok")
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
    let recordedRequest = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(recordedRequest)
    XCTAssertEqual(
      capturedRequest.value(forHTTPHeaderField: "Authorization"),
      "Bearer \(rotatedCredential)"
    )
    XCTAssertFalse(
      capturedRequest.value(forHTTPHeaderField: "Authorization")?.contains(initialCredential)
        == true
    )
    let previewData = try JSONEncoder().encode(try XCTUnwrap(capturedPreview))
    let previewJSON = try XCTUnwrap(String(data: previewData, encoding: .utf8))
    XCTAssertFalse(previewJSON.contains(initialCredential))
    XCTAssertFalse(previewJSON.contains(rotatedCredential))
  }

  func testStoreBatchesRapidStreamingMessagePublications() async throws {
    let streamLines =
      (0..<80).flatMap { _ in
        [#"data: {"choices":[{"delta":{"content":"a"}}]}"#, ""]
      } + [
        #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
        "",
      ]
    let transport = RecordingAIChatTransport(
      data: Data(), statusCode: 200, streamLines: streamLines)
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )
    profile.aiProviderConfig = streamingSupportedConfig(profile.aiProviderConfig)
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)
    var messagePublications = 0
    let observation = store.aiWorkspaceStore.$aiChatMessages
      .dropFirst()
      .sink { _ in messagePublications += 1 }
    defer { observation.cancel() }

    let reply = await store.sendAIChatMessage("快速流式回复。", draft: draft)

    XCTAssertEqual(reply?.content, String(repeating: "a", count: 80))
    XCTAssertEqual(store.aiChatMessages.last?.content, String(repeating: "a", count: 80))
    XCTAssertLessThan(messagePublications, 12, "分片应合并后再发布聊天消息状态")
  }

  func testStoreRejectsDuplicateAIChatSubmissionWhileReplyIsRunning() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"第一条回复"},"finish_reason":"stop"}]}"#,
        "",
      ],
      streamLineDelayNanoseconds: 50_000_000
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )
    profile.aiProviderConfig = streamingSupportedConfig(profile.aiProviderConfig)
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)

    let firstSubmission = Task {
      await store.sendAIChatMessage("第一条问题", draft: draft)
    }
    for _ in 0..<100 where !store.isAIChatRunning {
      await Task.yield()
    }
    XCTAssertTrue(store.isAIChatRunning)

    let duplicateReply = await store.sendAIChatMessage("重复提交", draft: draft)
    let firstReply = await firstSubmission.value
    let firstRequestCount = await transport.capturedRequestCount()

    XCTAssertNil(duplicateReply)
    XCTAssertEqual(firstReply?.content, "第一条回复")
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["第一条问题", "第一条回复"])
    XCTAssertEqual(firstRequestCount, 1)
    XCTAssertFalse(store.isAIChatRunning)
  }

  func testStoreRejectsUnsupportedDirectAIChatImageAttachment() async throws {
    let store = WorkbenchStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let attachment = AIChatImageAttachment(
      filename: "unsupported.heic",
      mimeType: "image/heic",
      data: Data([1, 2, 3])
    )

    let reply = await store.sendAIChatMessage(
      "请检查图片",
      draft: draft,
      imageAttachments: [attachment]
    )

    XCTAssertNil(reply)
    XCTAssertTrue(store.aiChatMessages.isEmpty)
    XCTAssertTrue(store.aiChatMessage?.contains("仅支持 PNG、JPEG、GIF 或 WebP") == true)
  }

  func testCanceledNonStreamingReplyCannotWriteBackAndNextRequestCanRun() async throws {
    let responseData = Data(
      #"{"model":"fallback-model","choices":[{"message":{"role":"assistant","content":"迟到回复"}}]}"#
        .utf8
    )
    let transport = DelayedAIChatTransport(
      data: responseData,
      statusCode: 200,
      delayNanoseconds: 50_000_000
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)
    store.prepareAIChat(for: draft)
    store.setAIChatKnowledgePolicy(.off)

    let canceledSubmission = Task {
      await store.sendAIChatMessage("请取消", draft: draft)
    }
    for _ in 0..<1_000 {
      if await transport.capturedRequestCount() == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let requestCountBeforeCancellation = await transport.capturedRequestCount()
    XCTAssertEqual(requestCountBeforeCancellation, 1)
    store.cancelAIChatReply()

    let canceledReply = await canceledSubmission.value

    XCTAssertNil(canceledReply)
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["请取消"])
    XCTAssertEqual(store.aiChatMessage, "AI 回复已停止。")
    XCTAssertFalse(store.isAIChatRunning)

    let nextReply = await store.sendAIChatMessage("再试一次", draft: draft)
    let finalRequestCount = await transport.capturedRequestCount()

    XCTAssertEqual(nextReply?.content, "迟到回复")
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["请取消", "再试一次", "迟到回复"])
    XCTAssertEqual(finalRequestCount, 2)
  }

  func testUnknownStreamingCapabilityCancellationPerformsZeroTransport() async throws {
    var decisionCount = 0
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in
      decisionCount += 1
      return .cancel
    }
    let responseData = Data(
      #"{"model":"fallback-model","choices":[{"message":{"role":"assistant","content":"unused"}}]}"#
        .utf8
    )
    let transport = DelayedAIChatTransport(
      data: responseData,
      statusCode: 200,
      delayNanoseconds: 0
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIOutboundFallbackCancel-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = remoteAIConfig
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)

    let reply = await store.sendAIChatMessage("cancel fallback", draft: draft)

    XCTAssertNil(reply)
    XCTAssertEqual(decisionCount, 1)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testUnknownStreamingCapabilityUsesOneInjectedAuthorizationDecisionAndOneCompleteTransport()
    async throws
  {
    var reviewedFingerprints: [String] = []
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { preview in
      reviewedFingerprints.append(preview.fingerprint)
      return .confirm
    }
    let responseData = Data(
      #"{"model":"fallback-model","choices":[{"message":{"role":"assistant","content":"fallback ok"}}]}"#
        .utf8
    )
    let transport = DelayedAIChatTransport(
      data: responseData,
      statusCode: 200,
      delayNanoseconds: 0
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIOutboundFallbackConfirm-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = remoteAIConfig
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)

    let reply = await store.sendAIChatMessage("confirm fallback", draft: draft)

    XCTAssertEqual(reply?.content, "fallback ok")
    XCTAssertEqual(reviewedFingerprints.count, 1)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testStoreSendsMaintenanceActionIntoAIChatWorkspace() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"维护建议"}}]}"#,
        "",
        #"data: {"choices":[{"delta":{"content":"已生成。"},"finish_reason":"stop"}]}"#,
        "",
      ]
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )
    profile.aiProviderConfig = streamingSupportedConfig(profile.aiProviderConfig)
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)
    store.prepareAIChat(for: draft)
    store.setAIChatKnowledgePolicy(.off)
    let item = MaintenanceActionItem(
      id: "link-\(draft.id.uuidString)",
      kind: .linkAudit,
      priority: .high,
      title: "修复链接：\(draft.title)",
      summary: "发现空链接或不存在的内链。",
      detail: "目标 /missing-page/ 无法在当前站点中找到。",
      draftID: draft.id,
      targetPath: "/missing-page/",
      systemImage: "link.badge.plus"
    )

    let reply = await store.sendMaintenanceActionToAI(item)

    XCTAssertEqual(reply?.content, "维护建议已生成。")
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertTrue(store.isAIPublishingAssistantPresented)
    XCTAssertEqual(store.aiChatDraftID, draft.id)
    XCTAssertEqual(store.aiChatMessages.count, 2)
    XCTAssertTrue(store.aiChatMessages.first?.content.contains("[维护行动项]") == true)
    XCTAssertTrue(store.aiChatMessages.first?.content.contains("修复链接") == true)
    XCTAssertTrue(store.aiChatMessages.first?.content.contains("/missing-page/") == true)
    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(payload["stream"] as? Bool, true)
  }

  func testStoreSendsReleaseRecoveryPackageIntoAIChatWorkspace() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"恢复判断"}}]}"#,
        "",
        #"data: {"choices":[{"delta":{"content":"已生成。"},"finish_reason":"stop"}]}"#,
        "",
      ]
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )
    profile.aiProviderConfig = streamingSupportedConfig(profile.aiProviderConfig)
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)
    store.prepareAIChat(for: draft)
    store.setAIChatKnowledgePolicy(.off)
    let record = ReleaseRecord(
      kind: .remotePublishFailure,
      title: "线上提交失败：\(draft.title)",
      summary: "远端 commit 已写入，但部署状态暂时未知。",
      siteProfileID: store.activeProfileID,
      siteName: profile.name,
      draftID: draft.id,
      draftTitle: draft.title,
      markdownPath: profile.markdownPath(for: draft),
      changedPaths: [profile.markdownPath(for: draft)],
      repositoryProvider: .github,
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      targetBranch: "main",
      commitSHA: "abcdef1234567890"
    )
    store.setReleaseRecords([record])
    let entry = try XCTUnwrap(store.activeProfileReleaseLedger.entries.first)

    let reply = await store.sendReleaseRecoveryPackageToAI(for: entry)

    XCTAssertEqual(reply?.content, "恢复判断已生成。")
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertTrue(store.isAIPublishingAssistantPresented)
    XCTAssertEqual(store.aiChatDraftID, draft.id)
    XCTAssertEqual(store.aiChatMessages.count, 2)
    XCTAssertTrue(store.aiChatMessages.first?.content.contains("[恢复包]") == true)
    XCTAssertTrue(store.aiChatMessages.first?.content.contains("线上提交失败") == true)
    XCTAssertTrue(store.aiChatMessages.first?.content.contains("abcdef12") == true)
    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(payload["stream"] as? Bool, true)
  }

  func testStoreSendsSEOSocialPreviewIntoAIChatWorkspace() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"SEO 建议"}}]}"#,
        "",
        #"data: {"choices":[{"delta":{"content":"已生成。"},"finish_reason":"stop"}]}"#,
        "",
      ]
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )
    profile.aiProviderConfig = streamingSupportedConfig(profile.aiProviderConfig)
    store.updateActiveProfile(profile)
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = "SEO 社交预览"
    draft.slug = "seo-social-preview"
    draft.summary = "这篇文章用于验证 SEO 社交预览可以发送到 AI 助手 Inspector。"
    draft.tags = ["SEO", "Mac"]
    store.updateDraft(draft)
    store.prepareAIChat(for: draft)
    store.setAIChatKnowledgePolicy(.off)

    store.prepareSEOSocialPreview(for: draft)
    let reply = await store.sendSEOSocialPreviewToAI(for: draft)

    XCTAssertEqual(reply?.content, "SEO 建议已生成。")
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertTrue(store.isAIPublishingAssistantPresented)
    XCTAssertEqual(store.aiChatDraftID, draft.id)
    XCTAssertEqual(store.aiChatMessages.count, 2)
    XCTAssertTrue(store.aiChatMessages.first?.content.contains("[平台就绪度]") == true)
    XCTAssertTrue(store.aiChatMessages.first?.content.contains("Open Graph") == true)
    XCTAssertTrue(store.aiChatMessages.first?.content.contains("Twitter/X") == true)
    XCTAssertTrue(store.aiChatMessages.first?.content.contains("SEO / Social 修改清单") == true)
    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(payload["stream"] as? Bool, true)
  }

  func testStorePromotesGranularMetadataActionResultToSuggestionPanel() async throws {
    let responsePayload: [String: Any] = [
      "model": "local-test",
      "choices": [
        [
          "message": [
            "role": "assistant",
            "content": "#Mac，AI, Publishing; AI",
          ]
        ]
      ],
    ]
    let transport = RecordingAIChatTransport(
      data: try JSONSerialization.data(withJSONObject: responsePayload),
      statusCode: 200
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "local-test",
      requiresAPIKey: false
    )
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)

    let result = await store.performAIAction(.suggestTags, draft: draft)

    XCTAssertEqual(result?.kind, .suggestTags)
    XCTAssertEqual(store.aiMetadataSuggestionDraftID, draft.id)
    XCTAssertEqual(store.aiMetadataSuggestion?.tags, ["Mac", "AI", "Publishing"])
    XCTAssertTrue(store.aiMetadataSuggestion?.titles.isEmpty == true)
    XCTAssertEqual(store.aiActionMessage, "Tags 建议完成。")
  }

  func testStoreKeepsPartialStreamingReplyWhenGenerationIsCanceled() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"部分回复"}}]}"#,
        "",
      ],
      streamFinishesWithCancellation: true
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )
    profile.aiProviderConfig = streamingSupportedConfig(profile.aiProviderConfig)
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)

    let reply = await store.sendAIChatMessage("打个招呼。", draft: draft)

    XCTAssertEqual(reply?.content, "部分回复")
    XCTAssertEqual(store.aiChatMessages.count, 2)
    XCTAssertEqual(store.aiChatMessages.last?.content, "部分回复")
    XCTAssertEqual(store.aiChatMessage, "AI 回复已停止。")
  }

  func testStoreRequiresExplicitManualConfirmationBeforeRetryingPartialReply() async throws {
    var authorizationDecisionCount = 0
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in
      authorizationDecisionCount += 1
      return .confirm
    }
    let transport = ScriptedAIChatStreamingTransport(
      attempts: [
        ScriptedAIChatStreamAttempt(
          lines: [#"data: {"choices":[{"delta":{"content":"部分回复"}}]}"#, ""],
          terminalError: .connectionLost
        ),
        ScriptedAIChatStreamAttempt(
          lines: [
            #"data: {"choices":[{"delta":{"content":"重新生成完成"},"finish_reason":"stop"}]}"#,
            "",
          ]
        ),
      ]
    )
    let client = AIChatCompletionClient(
      transport: transport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 1,
        resourceTimeout: 2,
        maximumAutomaticRetryCount: 3,
        automaticRetryBaseDelay: 0,
        partialTextRecovery: .disabled
      )
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(client: client)
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )
    profile.aiProviderConfig = streamingSupportedConfig(profile.aiProviderConfig)
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)
    store.prepareAIChat(for: draft)
    store.setAIChatKnowledgePolicy(.off)

    let partialReply = await store.sendAIChatMessage("请生成。", draft: draft)

    XCTAssertEqual(partialReply?.content, "部分回复")
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["请生成。", "部分回复"])
    var requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(authorizationDecisionCount, 1)
    XCTAssertEqual(
      store.aiChatManualRetryState?.requiresDuplicateChargeConfirmation,
      true
    )
    XCTAssertTrue(store.aiChatMessage?.contains("重复计费") == true)

    let unconfirmedReply = await store.retryLastFailedAIChatReply(draft: draft)
    XCTAssertNil(unconfirmedReply)
    requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(authorizationDecisionCount, 1)
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["请生成。", "部分回复"])

    let regeneratedReply = await store.ai.retryLastFailedChatReply(
      confirmingPossibleDuplicateCharge: true,
      draft: draft,
      expectedContextMode: .site
    )
    XCTAssertEqual(regeneratedReply?.content, "重新生成完成")
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["请生成。", "重新生成完成"])
    requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(authorizationDecisionCount, 2)
    XCTAssertNil(store.aiChatManualRetryState)
  }

  func testStoreRegeneratesSelectedAssistantReplyFromMatchingUserTurn() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"新的第一条回复"},"finish_reason":"stop"}]}"#,
        "",
      ]
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )
    profile.aiProviderConfig = streamingSupportedConfig(profile.aiProviderConfig)
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)
    store.prepareAIChat(for: draft)
    let firstUser = AIPublishingChatMessage(role: .user, content: "第一问题")
    let firstAssistant = AIPublishingChatMessage(role: .assistant, content: "旧的第一条回复")
    let secondUser = AIPublishingChatMessage(role: .user, content: "第二问题")
    let secondAssistant = AIPublishingChatMessage(role: .assistant, content: "第二条回复")
    store.setAIChatMessages([firstUser, firstAssistant, secondUser, secondAssistant])

    let reply = await store.regenerateAIChatReply(messageID: firstAssistant.id, draft: draft)

    XCTAssertEqual(reply?.content, "新的第一条回复")
    XCTAssertEqual(store.aiChatMessages.map(\.role), [.user, .assistant])
    XCTAssertEqual(store.aiChatMessages[0].content, "第一问题")
    XCTAssertEqual(store.aiChatMessages[1].content, "新的第一条回复")
    XCTAssertEqual(store.aiChatMessage, "AI 已回复。")

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let sentText = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
    XCTAssertTrue(sentText.contains("第一问题"))
    XCTAssertFalse(sentText.contains("第二问题"))
    XCTAssertFalse(sentText.contains("旧的第一条回复"))
  }

  func testStoreRestoresConversationWhenSelectedRegenerationFails() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(#"{"error":"server"}"#.utf8),
      statusCode: 500,
      streamLines: [
        #"data: {"error":"server"}"#,
        "",
      ]
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)
    store.prepareAIChat(for: draft)
    let firstUser = AIPublishingChatMessage(role: .user, content: "第一问题")
    let firstAssistant = AIPublishingChatMessage(role: .assistant, content: "旧的第一条回复")
    let secondUser = AIPublishingChatMessage(role: .user, content: "第二问题")
    let secondAssistant = AIPublishingChatMessage(role: .assistant, content: "第二条回复")
    let originalMessages = [firstUser, firstAssistant, secondUser, secondAssistant]
    store.setAIChatMessages(originalMessages)

    let reply = await store.regenerateAIChatReply(messageID: firstAssistant.id, draft: draft)

    XCTAssertNil(reply)
    XCTAssertEqual(store.aiChatMessages, originalMessages)
    XCTAssertTrue(store.aiChatMessage?.contains("AI 讨论失败") == true)
  }

  func testFailedSelectedRegenerationRestoresItsConversationAfterSwitchingDrafts() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(#"{"error":"server"}"#.utf8),
      statusCode: 500,
      streamLines: [
        #"data: {"error":"server"}"#,
        "",
      ],
      streamLineDelayNanoseconds: 100_000_000
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let client = AIChatCompletionClient(
      transport: transport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 1,
        resourceTimeout: 2,
        maximumAutomaticRetryCount: 0,
        automaticRetryBaseDelay: 0
      )
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(client: client)
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = streamingSupportedConfig(remoteAIConfig)
    store.updateActiveProfile(profile)
    let firstDraft = try XCTUnwrap(store.selectedDraft)
    let secondDraft = ArticleDraft(
      siteProfileID: firstDraft.siteProfileID,
      title: "异步期间切换的文章",
      slug: "regeneration-switch-target"
    )
    store.setDrafts([firstDraft, secondDraft])
    store.setSelectedDraftID(firstDraft.id)
    store.prepareAIChat(for: firstDraft)
    let firstUser = AIPublishingChatMessage(role: .user, content: "第一问题")
    let firstAssistant = AIPublishingChatMessage(role: .assistant, content: "旧的第一条回复")
    let secondUser = AIPublishingChatMessage(role: .user, content: "第二问题")
    let secondAssistant = AIPublishingChatMessage(role: .assistant, content: "第二条回复")
    let originalMessages = [firstUser, firstAssistant, secondUser, secondAssistant]
    store.setAIChatMessages(originalMessages)
    store.aiStore.cacheCurrentAIChatSessionForAIStore()
    let originalConversationID = try XCTUnwrap(
      store.activeAIChatConversationID(for: firstDraft.id)
    )

    let regeneration = Task {
      await store.regenerateAIChatReply(
        messageID: firstAssistant.id,
        draft: firstDraft
      )
    }
    for _ in 0..<200 {
      if await transport.capturedRequestCount() > 0 {
        break
      }
      try await Task.sleep(for: .milliseconds(1))
    }

    XCTAssertTrue(store.isAIChatRunning)
    XCTAssertFalse(
      store.selectAIChatConversation(originalConversationID),
      "运行期间同一入口会阻止切换对话"
    )
    store.ai.selectChatDraft(secondDraft.id)
    XCTAssertEqual(store.selectedDraftID, secondDraft.id)
    XCTAssertEqual(store.aiChatDraftID, secondDraft.id)
    let currentMessages = [
      AIPublishingChatMessage(role: .user, content: "当前文章不能被旧请求污染")
    ]
    store.setAIChatMessages(currentMessages)
    store.aiStore.cacheCurrentAIChatSessionForAIStore()

    let reply = await regeneration.value

    XCTAssertNil(reply)
    XCTAssertEqual(store.aiChatDraftID, secondDraft.id)
    XCTAssertEqual(store.aiChatMessages, currentMessages)
    let restoredConversation = try XCTUnwrap(
      store.aiChatConversations(for: firstDraft.id)
        .first { $0.id == originalConversationID }
    )
    XCTAssertEqual(restoredConversation.messages, originalMessages)
  }

  func testStoreRestoresTrailingAssistantsWhenLastRegenerationFails() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(#"{"error":"server"}"#.utf8),
      statusCode: 500,
      streamLines: [
        #"data: {"error":"server"}"#,
        "",
      ]
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)
    store.prepareAIChat(for: draft)
    let user = AIPublishingChatMessage(role: .user, content: "问题")
    let assistant = AIPublishingChatMessage(role: .assistant, content: "原回复")
    let originalMessages = [user, assistant]
    store.setAIChatMessages(originalMessages)

    let reply = await store.regenerateLastAIChatReply(draft: draft)

    XCTAssertNil(reply)
    XCTAssertEqual(store.aiChatMessages, originalMessages)
    XCTAssertTrue(store.aiChatMessage?.contains("AI 讨论失败") == true)
  }

  func testFailedLastRegenerationRestoresItsConversationAfterSwitchingDrafts() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(#"{"error":"server"}"#.utf8),
      statusCode: 500,
      streamLines: [
        #"data: {"error":"server"}"#,
        "",
      ],
      streamLineDelayNanoseconds: 100_000_000
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let client = AIChatCompletionClient(
      transport: transport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 1,
        resourceTimeout: 2,
        maximumAutomaticRetryCount: 0,
        automaticRetryBaseDelay: 0
      )
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(client: client)
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = streamingSupportedConfig(remoteAIConfig)
    store.updateActiveProfile(profile)
    let firstDraft = try XCTUnwrap(store.selectedDraft)
    let secondDraft = ArticleDraft(
      siteProfileID: firstDraft.siteProfileID,
      title: "最后回复生成期间切换",
      slug: "last-regeneration-switch-target"
    )
    store.setDrafts([firstDraft, secondDraft])
    store.setSelectedDraftID(firstDraft.id)
    store.prepareAIChat(for: firstDraft)
    let originalMessages = [
      AIPublishingChatMessage(role: .user, content: "原问题"),
      AIPublishingChatMessage(role: .assistant, content: "原回复"),
    ]
    store.setAIChatMessages(originalMessages)
    store.aiStore.cacheCurrentAIChatSessionForAIStore()
    let originalConversationID = try XCTUnwrap(
      store.activeAIChatConversationID(for: firstDraft.id)
    )

    let regeneration = Task {
      await store.regenerateLastAIChatReply(draft: firstDraft)
    }
    for _ in 0..<200 {
      if await transport.capturedRequestCount() > 0 {
        break
      }
      try await Task.sleep(for: .milliseconds(1))
    }

    XCTAssertTrue(store.isAIChatRunning)
    store.ai.selectChatDraft(secondDraft.id)
    let currentMessages = [
      AIPublishingChatMessage(role: .user, content: "切换后的对话仍保持原样")
    ]
    store.setAIChatMessages(currentMessages)
    store.aiStore.cacheCurrentAIChatSessionForAIStore()

    let reply = await regeneration.value

    XCTAssertNil(reply)
    XCTAssertEqual(store.aiChatDraftID, secondDraft.id)
    XCTAssertEqual(store.aiChatMessages, currentMessages)
    let restoredConversation = try XCTUnwrap(
      store.aiChatConversations(for: firstDraft.id)
        .first { $0.id == originalConversationID }
    )
    XCTAssertEqual(restoredConversation.messages, originalMessages)
  }

  func testStoreRestoresAIChatMessagesWhenSwitchingBackToDraft() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let firstDraft = try XCTUnwrap(store.selectedDraft)
    let secondDraft = ArticleDraft(
      siteProfileID: store.activeProfile.id,
      title: "第二篇",
      slug: "second"
    )
    let firstUser = AIPublishingChatMessage(role: .user, content: "第一篇的问题")
    let firstAssistant = AIPublishingChatMessage(role: .assistant, content: "第一篇的回复")
    let secondUser = AIPublishingChatMessage(role: .user, content: "第二篇的问题")

    store.prepareAIChat(for: firstDraft)
    store.setAIChatMessages([firstUser, firstAssistant])
    store.prepareAIChat(for: secondDraft)

    XCTAssertTrue(store.aiChatMessages.isEmpty)

    store.setAIChatMessages([secondUser])
    store.prepareAIChat(for: firstDraft)

    XCTAssertEqual(store.aiChatMessages.map(\.content), ["第一篇的问题", "第一篇的回复"])

    store.prepareAIChat(for: secondDraft)

    XCTAssertEqual(store.aiChatMessages.map(\.content), ["第二篇的问题"])
  }

  func testClearingAIChatClearsOnlyCurrentDraftSession() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let firstDraft = try XCTUnwrap(store.selectedDraft)
    let secondDraft = ArticleDraft(
      siteProfileID: store.activeProfile.id,
      title: "第二篇",
      slug: "second"
    )
    let firstMessage = AIPublishingChatMessage(role: .user, content: "保留第一篇")
    let secondMessage = AIPublishingChatMessage(role: .user, content: "清空第二篇")

    store.prepareAIChat(for: firstDraft)
    store.setAIChatMessages([firstMessage])
    store.prepareAIChat(for: secondDraft)
    store.setAIChatMessages([secondMessage])

    store.clearAIChat()
    XCTAssertTrue(store.aiChatMessages.isEmpty)
    XCTAssertEqual(store.aiChatMessage, "AI 讨论已清空。")

    store.prepareAIChat(for: firstDraft)
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["保留第一篇"])

    store.prepareAIChat(for: secondDraft)
    XCTAssertTrue(store.aiChatMessages.isEmpty)
  }

  func testDeletingAIChatMessageRemovesOnlySelectedRuntimeMessage() throws {
    let store = WorkbenchStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let firstUser = AIPublishingChatMessage(role: .user, content: "保留的问题")
    let assistant = AIPublishingChatMessage(role: .assistant, content: "要删除的回答")
    let secondUser = AIPublishingChatMessage(role: .user, content: "后续问题")

    store.prepareAIChat(for: draft)
    store.setAIChatMessages([firstUser, assistant, secondUser])

    store.deleteAIChatMessage(assistant.id, draft: draft)

    XCTAssertEqual(store.aiChatMessages.map(\.content), ["保留的问题", "后续问题"])
    XCTAssertEqual(store.aiChatMessage, "已删除 1 条 AI 消息。")

    store.deleteAIChatMessage(assistant.id, draft: draft)

    XCTAssertEqual(store.aiChatMessage, "找不到要删除的 AI 消息。")
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["保留的问题", "后续问题"])
  }

  func testStoreRestoresAIChatSettingsWhenSwitchingBackToDraft() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let firstDraft = try XCTUnwrap(store.selectedDraft)
    let secondDraft = ArticleDraft(
      siteProfileID: store.activeProfile.id,
      title: "第二篇",
      slug: "second"
    )

    store.prepareAIChat(for: firstDraft)
    store.setAIChatContextMode(.general)
    store.setAIChatKnowledgePolicy(.pinnedOnly)
    store.setAIChatModelGradeState(.custom)
    store.setAIChatSelectedModelState("first-custom-model")

    store.prepareAIChat(for: secondDraft)
    XCTAssertEqual(store.aiChatContextMode, .site)
    XCTAssertEqual(store.aiChatKnowledgePolicy, .automatic)
    XCTAssertEqual(store.aiChatModelGrade, .standard)
    XCTAssertEqual(store.aiChatSelectedModel, "")

    store.setAIChatContextMode(.site)
    store.setAIChatKnowledgePolicy(.off)
    store.setAIChatModelGradeState(.highQuality)
    store.setAIChatSelectedModelState("second-note")

    store.prepareAIChat(for: firstDraft)
    XCTAssertEqual(store.aiChatContextMode, .general)
    XCTAssertEqual(store.aiChatKnowledgePolicy, .pinnedOnly)
    XCTAssertEqual(store.aiChatModelGrade, .custom)
    XCTAssertEqual(store.aiChatSelectedModel, "first-custom-model")

    store.prepareAIChat(for: secondDraft)
    XCTAssertEqual(store.aiChatContextMode, .site)
    XCTAssertEqual(store.aiChatKnowledgePolicy, .off)
    XCTAssertEqual(store.aiChatModelGrade, .highQuality)
    XCTAssertEqual(store.aiChatSelectedModel, "second-note")
  }

  func testStoreRestoresFocusedAIChatParagraphWhenSwitchingDrafts() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    var firstDraft = try XCTUnwrap(store.selectedDraft)
    firstDraft.bodyMarkdown = """
      # 第一篇

      第一篇的普通段落。

      第一篇需要持续聚焦的段落，AI 应该围绕这里回答。
      """
    let secondDraft = ArticleDraft(
      siteProfileID: store.activeProfile.id,
      title: "第二篇",
      slug: "second",
      bodyMarkdown: """
        # 第二篇

        第二篇的上下文不应该继承第一篇的聚焦段落。
        """
    )
    let firstParagraph = try XCTUnwrap(
      AIPublishingChatDraftParagraphParser.extract(from: firstDraft.bodyMarkdown)
        .first { $0.text.contains("持续聚焦") }
    )

    store.updateDraft(firstDraft)
    store.prepareAIChat(for: firstDraft)
    store.setAIChatFocusedParagraph(firstParagraph.id, draft: firstDraft)

    store.prepareAIChat(for: secondDraft)

    XCTAssertNil(store.aiChatFocusedParagraphID)
    XCTAssertNil(store.focusedAIChatParagraph(for: secondDraft))

    store.prepareAIChat(for: firstDraft)

    XCTAssertEqual(store.aiChatFocusedParagraphID, firstParagraph.id)
    XCTAssertEqual(store.focusedAIChatParagraph(for: firstDraft)?.title, firstParagraph.title)
  }

  func testClearingAIChatPreservesCurrentDraftSettings() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let draft = try XCTUnwrap(store.selectedDraft)

    store.prepareAIChat(for: draft)
    store.setAIChatMessages([
      AIPublishingChatMessage(role: .user, content: "准备清空")
    ])
    store.setAIChatContextMode(.general)
    store.setAIChatKnowledgePolicy(.pinnedOnly)
    store.setAIChatModelGradeState(.custom)
    store.setAIChatSelectedModelState("kept-model")

    store.clearAIChat()

    XCTAssertTrue(store.aiChatMessages.isEmpty)
    XCTAssertEqual(store.aiChatContextMode, .general)
    XCTAssertEqual(store.aiChatKnowledgePolicy, .pinnedOnly)
    XCTAssertEqual(store.aiChatModelGrade, .custom)
    XCTAssertEqual(store.aiChatSelectedModel, "kept-model")
  }

  func testAIChatSessionStatePreparedTrimsCurrentConversation() {
    let activeMessages = (0..<5).map { index in
      AIPublishingChatMessage(role: .user, content: "active-\(index)")
    }
    let state = AIPublishingChatSessionState(messages: activeMessages)

    let prepared = state.prepared(maxMessagesPerConversation: 3)

    XCTAssertEqual(prepared.messages.map(\.content), ["active-2", "active-3", "active-4"])
  }

  func testPersistedAIChatStorageSupportsMoreThanLegacyTransientLimit() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
          .appendingPathExtension("json"))
    )
    var drafts = [try XCTUnwrap(store.selectedDraft)]
    for _ in 0..<13 {
      store.createDraft()
      drafts.append(try XCTUnwrap(store.selectedDraft))
    }

    for (index, draft) in drafts.enumerated() {
      store.prepareAIChat(for: draft)
      store.setAIChatMessages([
        AIPublishingChatMessage(role: .user, content: "session-\(index)")
      ])
    }

    store.aiStore.cacheCurrentAIChatSessionForAIStore()

    XCTAssertEqual(store.aiConversations.count, drafts.count)
    XCTAssertEqual(
      store.aiStore.aiChatSessionState(for: drafts[0].id)?.messages.first?.content,
      "session-0"
    )
    XCTAssertEqual(
      store.aiStore.aiChatSessionState(for: drafts[13].id)?.messages.first?.content,
      "session-13"
    )
  }

  func testStorePersistsCurrentDraftAIChatConversationAcrossReloads() async throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    let store = WorkbenchStore(persistence: persistence)
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.bodyMarkdown = """
      # 持久化 AI 对话

      普通正文段落。

      这个段落需要在重启后继续作为 AI 聚焦上下文。
      """
    store.updateDraft(draft)
    let focusedParagraph = try XCTUnwrap(
      AIPublishingChatDraftParagraphParser.extract(from: draft.bodyMarkdown)
        .first { $0.text.contains("重启后继续") }
    )
    let user = AIPublishingChatMessage(role: .user, content: "请检查这篇文章。")
    let assistant = AIPublishingChatMessage(
      role: .assistant,
      content: "可以先补摘要。",
      model: "deepseek-v4-pro",
      contextMode: .general
    )

    store.prepareAIChat(for: draft)
    store.setAIChatMessages([user, assistant])
    store.setAIChatConversationTitle("重启后继续的审稿会话", draft: draft)
    store.setAIChatContextMode(.general)
    store.setAIChatModelGradeState(.custom)
    store.setAIChatSelectedModelState("deepseek-v4-pro")
    store.setAIChatFocusedParagraph(focusedParagraph.id, draft: draft)
    store.save()
    await store.waitForPendingSave()

    let reloaded = WorkbenchStore(persistence: persistence)
    let reloadedDraft = try XCTUnwrap(reloaded.drafts.first { $0.id == draft.id })
    reloaded.prepareAIChat(for: reloadedDraft)

    let conversation = try XCTUnwrap(reloaded.activeAIChatConversation)
    XCTAssertEqual(conversation.draftID, draft.id)
    XCTAssertEqual(reloaded.aiChatConversationTitle, "重启后继续的审稿会话")
    XCTAssertEqual(reloaded.aiChatMessages.map(\.id), [user.id, assistant.id])
    XCTAssertEqual(
      reloaded.aiChatMessages.map(\.content),
      ["请检查这篇文章。", "可以先补摘要。"]
    )
    XCTAssertEqual(reloaded.aiChatMessages.last?.model, "deepseek-v4-pro")
    XCTAssertEqual(reloaded.aiChatMessages.last?.contextMode, .general)
    XCTAssertEqual(reloaded.aiChatContextMode, .general)
    XCTAssertEqual(reloaded.aiChatModelGrade, .custom)
    XCTAssertEqual(reloaded.aiChatSelectedModel, "deepseek-v4-pro")
    XCTAssertEqual(reloaded.aiChatFocusedParagraphID, focusedParagraph.id)
    XCTAssertEqual(
      reloaded.activeAIChatConversationID(for: draft.id),
      conversation.id
    )
  }

  func testStartingNewConversationPreservesPreviousConversation() throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    store.prepareAIChat(for: draft)
    store.setAIChatMessages([
      AIPublishingChatMessage(role: .user, content: "第一轮问题"),
      AIPublishingChatMessage(role: .assistant, content: "第一轮回答"),
    ])
    store.setAIChatConversationTitle("临时对话", draft: draft)

    let originalConversationID = try XCTUnwrap(
      store.activeAIChatConversationID(for: draft.id)
    )
    let newConversation = try XCTUnwrap(
      store.startNewAIChatConversation(draft: draft)
    )
    let conversations = store.aiChatConversations(for: draft.id)
    let original = try XCTUnwrap(
      conversations.first { $0.id == originalConversationID }
    )

    XCTAssertEqual(conversations.count, 2)
    XCTAssertEqual(
      original.messages.map(\.content),
      ["第一轮问题", "第一轮回答"]
    )
    XCTAssertEqual(original.title, "临时对话")
    XCTAssertTrue(newConversation.messages.isEmpty)
    XCTAssertEqual(
      store.activeAIChatConversationID(for: draft.id),
      newConversation.id
    )
    XCTAssertTrue(store.aiChatMessages.isEmpty)
    XCTAssertNil(store.aiChatConversationTitle)
    XCTAssertEqual(store.aiChatMessage, "已新建 AI 对话。")
  }

  func testStreamingReplyStaysWithOriginalDraftAfterSwitchingDrafts() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"原文章"}}]}"#,
        "",
        #"data: {"choices":[{"delta":{"content":"回复"},"finish_reason":"stop"}]}"#,
        "",
      ],
      streamLineDelayNanoseconds: 20_000_000
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: persistenceURL)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.example/v1",
      model: "gpt-4.1",
      requiresAPIKey: false
    )
    profile.aiProviderConfig = streamingSupportedConfig(profile.aiProviderConfig)
    store.updateActiveProfile(profile)
    let firstDraft = try XCTUnwrap(store.selectedDraft)
    let secondDraft = ArticleDraft(
      siteProfileID: store.activeProfile.id,
      title: "第二篇",
      slug: "second"
    )
    let secondMessage = AIPublishingChatMessage(role: .user, content: "第二篇还在编辑")

    let sendTask = Task {
      await store.sendAIChatMessage("检查第一篇。", draft: firstDraft)
    }
    try await Task.sleep(nanoseconds: 5_000_000)

    store.prepareAIChat(for: secondDraft)
    store.setAIChatMessages([secondMessage])

    let reply = await sendTask.value

    XCTAssertEqual(reply?.content, "原文章回复")
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["第二篇还在编辑"])

    store.prepareAIChat(for: firstDraft)
    XCTAssertEqual(store.aiChatMessages.map(\.role), [.user, .assistant])
    XCTAssertEqual(store.aiChatMessages[0].content, "检查第一篇。")
    XCTAssertEqual(store.aiChatMessages[1].content, "原文章回复")

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    let requestBody = try XCTUnwrap(capturedRequest.httpBody)
    let requestText = try XCTUnwrap(String(data: requestBody, encoding: .utf8))
    XCTAssertTrue(requestText.contains("检查第一篇。"))
    XCTAssertFalse(requestText.contains("第二篇还在编辑"))
  }

  func testArticleKnowledgeSnapshotIsFrozenWhenUnrelatedDataChangesDuringAuthorization()
    async throws
  {
    let directory = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "WorkbenchArticleKnowledgeFreeze"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = KnowledgeLibraryService(
      rootURL: directory.appendingPathComponent("knowledge", isDirectory: true)
    )
    _ = try await commitKnowledgeTestDocument(
      title: "蓝鲸航线资料",
      text: "BlueWhaleRoute 的首版研究结论应保持在本次授权后的请求中。",
      allowsRemoteAIUse: true,
      library: library
    )
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"已完成"},"finish_reason":"stop"}]}"#,
        "",
      ]
    )
    let consentStore = AIDataSharingConsentStore(
      storageKey: "AIDataSharingConsent.KnowledgeFreeze.\(UUID().uuidString)"
    )
    let config = streamingSupportedConfig(remoteAIConfig)
    consentStore.grant(for: config)
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")
      ),
      knowledgeLibraryService: library,
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consentStore
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = config
    store.updateActiveProfile(profile)
    await store.knowledge.reload()
    let draft = try XCTUnwrap(store.selectedDraft)
    var previewFingerprint: String?
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { preview in
      previewFingerprint = preview.fingerprint
      _ = try? await self.commitKnowledgeTestDocument(
        title: "无关资料",
        text: "这次授权窗口新增的无关资料不应进入已冻结上下文。",
        allowsRemoteAIUse: true,
        library: library
      )
      return .confirm
    }
    defer { AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = nil }

    let reply = await store.sendAIChatMessage("请解释 BlueWhaleRoute。", draft: draft)

    XCTAssertEqual(reply?.content, "已完成")
    XCTAssertNotNil(previewFingerprint)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
    let recordedRequest = await transport.capturedRequest()
    let request = try XCTUnwrap(recordedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let bodyText = try XCTUnwrap(String(data: body, encoding: .utf8))
    XCTAssertTrue(bodyText.contains("BlueWhaleRoute 的首版研究结论"))
    XCTAssertFalse(bodyText.contains("这次授权窗口新增的无关资料"))
  }

  func testArticleExplicitKnowledgeRevocationDuringAuthorizationPerformsZeroTransport()
    async throws
  {
    let directory = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "WorkbenchArticleExplicitKnowledgeRevocation"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = KnowledgeLibraryService(
      rootURL: directory.appendingPathComponent("knowledge", isDirectory: true)
    )
    let documentID = try await commitKnowledgeTestDocument(
      title: "显式文章资料",
      text: "这段资料只在用户明确 @ 引用时进入文章对话。",
      allowsRemoteAIUse: true,
      library: library
    )
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let consentStore = AIDataSharingConsentStore(
      storageKey: "AIDataSharingConsent.KnowledgeRevocation.\(UUID().uuidString)"
    )
    let config = streamingSupportedConfig(remoteAIConfig)
    consentStore.grant(for: config)
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")
      ),
      knowledgeLibraryService: library,
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consentStore
    )
    var profile = store.activeProfile
    profile.aiProviderConfig = config
    store.updateActiveProfile(profile)
    await store.knowledge.reload()
    let draft = try XCTUnwrap(store.selectedDraft)
    store.prepareAIChat(for: draft)
    store.setAIChatKnowledgePolicy(.off)
    let reference = AIContextReference.knowledgeEntry(
      documentID: documentID,
      title: "显式文章资料",
      characterCount: 100
    )
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in
      try? library.setAllowsRemoteAIUse(false, documentID: documentID)
      return .confirm
    }
    defer { AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = nil }

    let reply = await store.sendAIChatMessage(
      "请仅根据这份资料回答。",
      draft: draft,
      contextReferences: [reference]
    )

    XCTAssertNil(reply)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
    XCTAssertEqual(store.aiChatMessage, "资料权限或版本已变化，本次未发送，请重新生成。")
  }

  private func aiTokenStoreForTest() -> KeychainTokenStore {
    KeychainTokenStore(
      service: "PSPMAIChatTests.\(UUID().uuidString.prefix(8))",
      accountPrefix: "ai-test",
      inMemory: true
    )
  }

  private func makeCredentialTOCTOUArticleStore(
    suffix: String
  ) -> (
    store: WorkbenchStore,
    transport: RecordingAIChatTransport,
    config: AIProviderConfig,
    consentStore: AIDataSharingConsentStore,
    persistenceURL: URL
  ) {
    let transport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#,
        "",
      ]
    )
    let config = streamingSupportedConfig(
      AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.example/v1",
        model: "credential-toctou-model",
        requiresAPIKey: true
      )
    )
    let consentStore = AIDataSharingConsentStore(
      storageKey: "AIDataSharingConsent.CredentialTOCTOU.\(suffix).\(UUID().uuidString)"
    )
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIOutboundCredentialTOCTOU-\(suffix)-\(UUID().uuidString).json")
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: aiTokenStoreForTest(),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consentStore
    )
    return (store, transport, config, consentStore, persistenceURL)
  }

  private func streamingSupportedConfig(_ base: AIProviderConfig) -> AIProviderConfig {
    var config = base
    let now = Date()
    let key = AIProviderCapabilityCacheKey(config: config)
    var evidence = config.capabilityProbeEvidence ?? [:]
    evidence[.streamingResponse] = AIProviderCapabilityProbeEvidence(
      key: key,
      capability: .streamingResponse,
      outcome: .supported,
      observedAt: now,
      expiresAt: now.addingTimeInterval(60)
    )
    config.capabilityProbeEvidence = evidence
    return config
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
}
