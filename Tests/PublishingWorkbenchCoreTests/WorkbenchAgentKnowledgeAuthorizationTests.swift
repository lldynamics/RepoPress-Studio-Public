import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchAgentKnowledgeAuthorizationTests: XCTestCase {
  func testContinuationV3RoundTripsBindingsAndRejectsLegacyV2() throws {
    let documentID = UUID()
    let revisionID = UUID()
    let binding = KnowledgeAuthorizationBinding(
      documentID: documentID,
      revisionID: revisionID,
      contentHash: "sha256:knowledge-fixture"
    )
    let continuation = makeContinuation(
      bindings: [binding],
      schemaVersion: AIPublishingChatAgentContinuation.currentSchemaVersion
    )

    XCTAssertTrue(continuation.isValidForPersistence)
    let encoded = try JSONEncoder().encode(continuation)
    let decoded = try JSONDecoder().decode(
      AIPublishingChatAgentContinuation.self,
      from: encoded
    )
    XCTAssertEqual(decoded.schemaVersion, 3)
    XCTAssertEqual(decoded.knowledgeAuthorizationBindings, [binding])
    XCTAssertTrue(decoded.isValidForPersistence)

    var legacyObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    legacyObject["schemaVersion"] = 2
    legacyObject.removeValue(forKey: "knowledgeAuthorizationBindings")
    let legacyData = try JSONSerialization.data(
      withJSONObject: legacyObject,
      options: [.sortedKeys]
    )
    let legacy = try JSONDecoder().decode(
      AIPublishingChatAgentContinuation.self,
      from: legacyData
    )
    XCTAssertEqual(legacy.schemaVersion, 2)
    XCTAssertTrue(legacy.knowledgeAuthorizationBindings.isEmpty)
    XCTAssertFalse(legacy.isValidForPersistence)
  }

  func testEmptyBindingsRemainValidForKnowledgeFreeContinuation() throws {
    let continuation = makeContinuation(bindings: [])

    XCTAssertTrue(continuation.isValidForPersistence)
    XCTAssertTrue(continuation.knowledgeAuthorizationBindings.isEmpty)
  }

  private func makeContinuation(
    bindings: [KnowledgeAuthorizationBinding],
    schemaVersion: Int = AIPublishingChatAgentContinuation.currentSchemaVersion
  ) -> AIPublishingChatAgentContinuation {
    let draftID = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let checkpoint = WorkbenchAIAgentLoopCheckpoint(
      transcript: [],
      trustedBoundaryIndex: 0,
      agentTranscriptStartIndex: 0,
      limits: .default,
      allowedCommands: [],
      pendingCalls: [],
      toolRuns: [],
      modelRoundCount: 0,
      toolCallCount: 0,
      totalArgumentByteCount: 0,
      totalToolResultByteCount: 0,
      totalAssistantByteCount: 0,
      totalTranscriptByteCount: 0
    )
    let config = AIProviderConfig(model: "knowledge-fixture")
    return AIPublishingChatAgentContinuation(
      schemaVersion: schemaVersion,
      ownerConversationID: UUID(),
      ownerScope: .draft(draftID),
      ownerMessageID: UUID(),
      planID: UUID(),
      requestTemplate: AIChatCompletionRequest(
        model: "knowledge-fixture",
        messages: []
      ),
      checkpoint: checkpoint,
      providerConfig: config,
      taskConfig: config,
      promptRevision: AIPublishingChatAgentPromptRevision(),
      reviewDraftFingerprint: "draft-fixture",
      reviewDraftUpdatedAt: now,
      knowledgeAuthorizationBindings: bindings,
      createdAt: now,
      updatedAt: now
    )
  }
}
