import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchAIStoreAgentLoopIntegrationTests: XCTestCase {
  func testLegacyEnabledAgentConnectionUsesTextOnlyWritingTransport() async throws {
    let fixture = try makeStore(content: "写作建议")
    defer { fixture.cleanup() }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    let initialDrafts = fixture.store.drafts.map(\.repositoryContentFingerprint)
    let initialIDs = fixture.store.drafts.map(\.id)

    let reply = await fixture.store.sendAIChatMessage("请评价文章的表达。", draft: draft)

    XCTAssertEqual(reply?.content, "写作建议")
    XCTAssertTrue(reply?.toolRuns.isEmpty == true)
    XCTAssertNil(reply?.agentContinuation)
    XCTAssertEqual(fixture.store.drafts.map(\.repositoryContentFingerprint), initialDrafts)
    XCTAssertEqual(fixture.store.drafts.map(\.id), initialIDs)
    let count = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(count, 1)
    let request = await fixture.transport.capturedRequest()
    let data = try XCTUnwrap(request?.httpBody)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNil(body["tools"])
    XCTAssertNil(body["tool_choice"])
  }

  func testUnsolicitedToolCallCannotCreateDraftOrStartAnotherRound() async throws {
    let fixture = try makeStore(content: "", toolCall: true)
    defer { fixture.cleanup() }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    let initialDrafts = fixture.store.drafts.map(\.repositoryContentFingerprint)
    let initialIDs = fixture.store.drafts.map(\.id)

    let reply = await fixture.store.sendAIChatMessage("写作建议", draft: draft)

    XCTAssertEqual(fixture.store.drafts.map(\.repositoryContentFingerprint), initialDrafts)
    XCTAssertEqual(fixture.store.drafts.map(\.id), initialIDs)
    XCTAssertTrue(fixture.store.automationRunRecords.isEmpty)
    XCTAssertNil(reply?.agentContinuation)
    XCTAssertTrue(reply?.toolRuns.isEmpty ?? true)
    let count = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(count, 1)
  }

  func testExecutorRejectsRetiredPlanEvenWithExplicitStepConfirmation() async throws {
    let fixture = try makeStore(content: "未使用")
    defer { fixture.cleanup() }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    let plan = WorkbenchAutomationPlan(
      goal: "旧计划",
      steps: [WorkbenchAutomationStep(command: .createDraft)],
      source: .agentLoop
    )
    let originalDrafts = fixture.store.drafts

    let result = await WorkbenchAutomationExecutor.execute(
      plan: plan, in: fixture.store, confirmedStepIDs: Set(plan.steps.map(\.id))
    )

    XCTAssertEqual(fixture.store.drafts, originalDrafts)
    XCTAssertEqual(fixture.store.selectedDraft?.id, draft.id)
    XCTAssertEqual(result.record.steps.map(\.status), [.cancelled])
    XCTAssertTrue(result.record.steps.allSatisfy { $0.message == AIAgentRetirement.message })
    let count = await fixture.transport.capturedRequestCount()
    XCTAssertEqual(count, 0)
  }

  private func makeStore(content: String, toolCall: Bool = false) throws -> RetirementFixture {
    var message: [String: Any] = ["role": "assistant", "content": content]
    if toolCall {
      message["tool_calls"] = [
        [
          "id": "retired-call", "type": "function",
          "function": ["name": "createDraft", "arguments": "{}"],
        ]
      ]
    }
    let data = try JSONSerialization.data(withJSONObject: [
      "model": "fixture-model", "choices": [["message": message]],
    ])
    let transport = RecordingAIChatTransport(data: data, statusCode: 200)
    let directory = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "AgentRetirement")
    let suite = "AgentRetirement.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let consent = AIDataSharingConsentStore(defaults: defaults)
    var config = AIProviderConfig(
      preset: .custom, baseURL: "https://retirement.example/v1", model: "fixture-model",
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(
        allowsApplicationTools: true, agentPermissionPolicy: .all
      )
    )
    consent.grant(for: config)
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")),
      keychainTokenStore: KeychainTokenStore(
        service: suite, accountPrefix: "retirement", inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consent
    )
    var connection = store.activeAIConnectionProfile
    connection.config = config
    XCTAssertTrue(store.updateAIConnectionProfile(connection))
    let now = Date()
    config.capabilityProbeEvidence = [
      .toolCalling: AIProviderCapabilityProbeEvidence(
        key: AIProviderCapabilityCacheKey(config: config), capability: .toolCalling,
        outcome: .supported, observedAt: now, expiresAt: now.addingTimeInterval(600)
      )
    ]
    connection.config = config
    XCTAssertTrue(store.updateAIConnectionProfile(connection))
    return RetirementFixture(
      store: store, transport: transport, directory: directory, defaults: defaults, suite: suite
    )
  }
}

private struct RetirementFixture {
  let store: WorkbenchStore
  let transport: RecordingAIChatTransport
  let directory: URL
  let defaults: UserDefaults
  let suite: String

  func cleanup() {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }
}
