import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchAIStoreAgentLoopIntegrationTests: XCTestCase {
  override func setUp() {
    super.setUp()
    // Production defaults to automatic remote authorization. Tests that need
    // fail-closed fault injection install an explicit provider below.
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = nil
    AIOutboundPayloadApprovalBroker.shared.testingConfirmationDateProvider = nil
  }

  override func tearDown() {
    AIOutboundPayloadApprovalBroker.shared.cancelPendingRequest()
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = nil
    AIOutboundPayloadApprovalBroker.shared.testingConfirmationDateProvider = nil
    super.tearDown()
  }

  func
    testSupportedToolCallingExecutesReadOnlyToolThenCompletesWithTwoTransportsWithoutPerRequestPayloadPrompt()
    async throws
  {
    let fixture = makeStore(
      responses: [
        toolCallResponse(name: "showInspector", arguments: [:]),
        textResponse("只读检查完成。"),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    fixture.store.setInspectorPresented(false)
    let draft = try XCTUnwrap(fixture.store.selectedDraft)

    let reply = await fixture.store.sendAIChatMessage("打开检查器后告诉我结果。", draft: draft)

    XCTAssertEqual(reply?.content, "只读检查完成。")
    XCTAssertTrue(fixture.store.isInspectorPresented)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 2)
    XCTAssertEqual(AIOutboundPayloadApprovalBroker.shared.pendingRequestCountForTesting, 0)
    let bodies = await fixture.transport.capturedBodies()
    XCTAssertEqual(bodies.count, 2)
    let first = try jsonBody(bodies[0])
    XCTAssertFalse((first["tools"] as? [[String: Any]] ?? []).isEmpty)
    let second = try jsonBody(bodies[1])
    let messages = try XCTUnwrap(second["messages"] as? [[String: Any]])
    XCTAssertTrue(messages.contains { ($0["role"] as? String) == "tool" })
  }

  func testSupportedToolCallingReturnsNonReadOnlyStepForReviewWithoutExecution() async throws {
    let fixture = makeStore(
      responses: [
        toolCallResponse(name: "createDraft", arguments: ["value": "AI 待确认草稿"])
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    let originalDraftCount = fixture.store.drafts.count
    let draft = try XCTUnwrap(fixture.store.selectedDraft)

    let reply = await fixture.store.sendAIChatMessage("请新建一篇草稿。", draft: draft)

    let plan = try XCTUnwrap(reply?.automationPlan)
    XCTAssertEqual(plan.source, .agentLoop)
    XCTAssertEqual(plan.steps.map(\.command), [.createDraft])
    XCTAssertEqual(plan.steps.first?.status, .awaitingConfirmation)
    XCTAssertEqual(fixture.store.drafts.count, originalDraftCount)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 1)
    XCTAssertEqual(AIOutboundPayloadApprovalBroker.shared.pendingRequestCountForTesting, 0)
  }

  func testUnknownToolCallingCapabilityUsesOrdinaryTextPathWithoutToolDeclaration() async throws {
    let fixture = makeStore(
      responses: [textResponse("普通文本回答。")],
      toolCallingSupported: false
    )
    defer { fixture.cleanup() }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)

    let reply = await fixture.store.sendAIChatMessage("不要调用工具。", draft: draft)

    XCTAssertEqual(reply?.content, "普通文本回答。")
    XCTAssertNil(reply?.automationPlan)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 1)
    XCTAssertEqual(AIOutboundPayloadApprovalBroker.shared.pendingRequestCountForTesting, 0)
    let capturedBodies = await fixture.transport.capturedBodies()
    let body = try jsonBody(try XCTUnwrap(capturedBodies.first))
    XCTAssertNil(body["tools"])
  }

  func testSecondAgentRoundCancellationDoesNotReuseFirstInjectedDecisionOrSendAgain() async throws {
    let fixture = makeStore(
      responses: [
        toolCallResponse(name: "showInspector", arguments: [:]),
        textResponse("不应发送。"),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    var decisionCount = 0
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in
      decisionCount += 1
      return decisionCount == 1 ? .confirm : .cancel
    }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)

    let reply = await fixture.store.sendAIChatMessage("检查后再回答。", draft: draft)

    XCTAssertNil(reply)
    XCTAssertEqual(decisionCount, 2)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 1)
    XCTAssertEqual(fixture.store.aiChatMessages.map(\.role), [.user])
  }

  func testSecondAgentRoundExpiredAuthorizationPerformsNoAdditionalTransport() async throws {
    let fixture = makeStore(
      responses: [
        toolCallResponse(name: "showInspector", arguments: [:]),
        textResponse("不应发送。"),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    var decisionCount = 0
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in
      decisionCount += 1
      return .confirm
    }
    AIOutboundPayloadApprovalBroker.shared.testingConfirmationDateProvider = { preview in
      decisionCount == 2 ? preview.expiresAt.addingTimeInterval(1) : Date()
    }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)

    let reply = await fixture.store.sendAIChatMessage("检查后再回答。", draft: draft)

    XCTAssertNil(reply)
    XCTAssertEqual(decisionCount, 2)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 1)
    XCTAssertEqual(fixture.store.aiChatMessages.map(\.role), [.user])
  }

  func testSecondAgentRoundDraftDriftPerformsNoAdditionalTransport() async throws {
    let fixture = makeStore(
      responses: [
        toolCallResponse(name: "showInspector", arguments: [:]),
        textResponse("不应发送。"),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    var decisionCount = 0
    AIOutboundPayloadApprovalBroker.shared.testingDecisionProvider = { _ in
      decisionCount += 1
      if decisionCount == 2, var changedDraft = fixture.store.selectedDraft {
        changedDraft.bodyMarkdown += "\n确认期间发生变化"
        fixture.store.updateDraft(changedDraft)
      }
      return .confirm
    }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)

    let reply = await fixture.store.sendAIChatMessage("检查后再回答。", draft: draft)

    XCTAssertNil(reply)
    XCTAssertEqual(decisionCount, 2)
    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 1)
    XCTAssertEqual(fixture.store.aiChatMessages.map(\.role), [.user])
  }

  func testCancellingOperationWhileSecondAgentTransportIsInFlightDoesNotWriteLateReply()
    async throws
  {
    let fixture = makeStore(
      responses: [
        AgentTransportAttempt(data: toolCallResponse(name: "showInspector", arguments: [:])),
        AgentTransportAttempt(data: textResponse("迟到回答。"), delayNanoseconds: 120_000_000),
      ],
      toolCallingSupported: true
    )
    defer { fixture.cleanup() }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    let task = Task {
      await fixture.store.sendAIChatMessage("运行后取消。", draft: draft)
    }
    for _ in 0..<500 {
      if await fixture.transport.capturedRequestCount() == 2 { break }
      try await Task.sleep(for: .milliseconds(2))
    }

    let capturedRequestCount = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(capturedRequestCount, 2)
    fixture.store.cancelAIChatReply()
    let reply = await task.value

    XCTAssertNil(reply)
    XCTAssertEqual(fixture.store.aiChatMessages.map(\.role), [.user])
    XCTAssertFalse(fixture.store.isAIChatRunning)
  }

  private func makeStore(
    responses: [Data],
    toolCallingSupported: Bool
  ) -> AgentStoreFixture {
    makeStore(
      responses: responses.map { AgentTransportAttempt(data: $0) },
      toolCallingSupported: toolCallingSupported
    )
  }

  private func makeStore(
    responses: [AgentTransportAttempt],
    toolCallingSupported: Bool
  ) -> AgentStoreFixture {
    let transport = SequencedAgentAIChatTransport(attempts: responses)
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchAgentRuntime-\(UUID().uuidString).json")
    let consentStore = AIDataSharingConsentStore(
      storageKey: "WorkbenchAgentRuntimeConsent.\(UUID().uuidString)"
    )
    var config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://agent.example/v1",
      model: "agent-test-model",
      requiresAPIKey: false
    )
    if toolCallingSupported {
      let now = Date()
      let key = AIProviderCapabilityCacheKey(config: config)
      config.capabilityProbeEvidence = [
        .toolCalling: AIProviderCapabilityProbeEvidence(
          key: key,
          capability: .toolCalling,
          outcome: .supported,
          observedAt: now,
          expiresAt: now.addingTimeInterval(60)
        )
      ]
    }
    XCTAssertTrue(consentStore.grant(for: config))
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: KeychainTokenStore(
        service: "WorkbenchAgentRuntime.\(UUID().uuidString.prefix(8))",
        accountPrefix: "agent-test",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consentStore
    )
    configureActiveAIConnection(in: store, config: config)
    return AgentStoreFixture(
      store: store,
      transport: transport,
      config: config,
      consentStore: consentStore,
      persistenceURL: persistenceURL
    )
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

  private func toolCallResponse(
    name: String,
    arguments: [String: Any]
  ) -> Data {
    let argumentsData = try! JSONSerialization.data(
      withJSONObject: arguments, options: [.sortedKeys])
    let argumentsString = String(data: argumentsData, encoding: .utf8)!
    return try! JSONSerialization.data(withJSONObject: [
      "model": "agent-test-model",
      "choices": [
        [
          "message": [
            "role": "assistant",
            "content": "",
            "tool_calls": [
              [
                "id": "call-\(name)",
                "type": "function",
                "function": ["name": name, "arguments": argumentsString],
              ]
            ],
          ],
          "finish_reason": "tool_calls",
        ]
      ],
    ])
  }

  private func textResponse(_ content: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
      "model": "agent-test-model",
      "choices": [
        [
          "message": ["role": "assistant", "content": content],
          "finish_reason": "stop",
        ]
      ],
    ])
  }

  private func jsonBody(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}

private struct AgentStoreFixture {
  let store: WorkbenchStore
  let transport: SequencedAgentAIChatTransport
  let config: AIProviderConfig
  let consentStore: AIDataSharingConsentStore
  let persistenceURL: URL

  @MainActor
  func cleanup() {
    consentStore.revoke(for: config)
    try? FileManager.default.removeItem(at: persistenceURL)
  }
}

private struct AgentTransportAttempt: Sendable {
  let data: Data
  let statusCode: Int
  let delayNanoseconds: UInt64

  init(data: Data, statusCode: Int = 200, delayNanoseconds: UInt64 = 0) {
    self.data = data
    self.statusCode = statusCode
    self.delayNanoseconds = delayNanoseconds
  }
}

private actor SequencedAgentAIChatTransport: AIChatTransport {
  private let attempts: [AgentTransportAttempt]
  private var requests: [URLRequest] = []

  init(attempts: [AgentTransportAttempt]) {
    self.attempts = attempts
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let index = requests.count
    requests.append(request)
    let attempt = attempts[min(index, max(0, attempts.count - 1))]
    if attempt.delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: attempt.delayNanoseconds)
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: attempt.statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
    return (attempt.data, response)
  }

  func capturedRequestCount() -> Int {
    requests.count
  }

  func capturedBodies() -> [Data] {
    requests.compactMap(\.httpBody)
  }
}
