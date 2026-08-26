import XCTest
@testable import PublishingWorkbenchCore

final class WorkbenchTaskCenterModelsTests: XCTestCase {
  func testTaskKindCoversTheSixUnifiedTaskSources() {
    XCTAssertEqual(
      WorkbenchTaskKind.allCases,
      [.aiRequest, .knowledgeImport, .imageProcessing, .siteScan, .gitPush, .deployment]
    )
  }

  func testProgressIsClampedToDisplayableRange() {
    let low = WorkbenchTaskItem(
      id: "low",
      kind: .imageProcessing,
      detail: "低于范围",
      progress: -0.4,
      state: .running
    )
    let high = WorkbenchTaskItem(
      id: "high",
      kind: .imageProcessing,
      detail: "高于范围",
      progress: 1.4,
      state: .running
    )

    XCTAssertEqual(low.progress, 0)
    XCTAssertEqual(high.progress, 1)
  }

  func testRetryIntentRoundTripsAndRequiresAnIntentToRetry() throws {
    let profileID = UUID()
    let firstDraftID = UUID()
    let secondDraftID = UUID()
    let original = WorkbenchTaskItem(
      id: "batch",
      kind: .gitPush,
      detail: "批量发布失败",
      state: .failed,
      canRetry: true,
      retryIntent: .gitRemoteBatch(
        profileID: profileID,
        draftIDs: [firstDraftID, secondDraftID]
      )
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WorkbenchTaskItem.self, from: data)

    XCTAssertEqual(decoded, original)
    XCTAssertTrue(decoded.canRetry)
    XCTAssertEqual(decoded.retryIntent, original.retryIntent)

    let untyped = WorkbenchTaskItem(
      id: "untyped",
      kind: .gitPush,
      detail: "没有原始目标",
      state: .failed,
      canRetry: true
    )
    XCTAssertFalse(untyped.canRetry)
    XCTAssertNil(untyped.retryIntent)
  }

  func testAIChatRetryIntentCarriesDuplicateChargeRequirement() {
    let intent = WorkbenchTaskRetryIntent.aiChat(
      draftID: UUID(),
      conversationID: UUID(),
      requiresDuplicateChargeConfirmation: true
    )

    XCTAssertTrue(intent.requiresDuplicateChargeConfirmation)
    XCTAssertFalse(
      WorkbenchTaskRetryIntent.aiChat(
        draftID: UUID(),
        conversationID: UUID(),
        requiresDuplicateChargeConfirmation: false
      ).requiresDuplicateChargeConfirmation
    )
  }

  func testGeneralAIChatRetryIntentRoundTripsConversationAndOperation() throws {
    let conversationID = UUID()
    let operationID = UUID()
    let original = WorkbenchTaskItem(
      id: "general-ai",
      kind: .aiRequest,
      detail: "通用 AI 失败",
      state: .failed,
      retryIntent: .generalAIChat(
        conversationID: conversationID,
        operationID: operationID,
        requiresDuplicateChargeConfirmation: true
      )
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WorkbenchTaskItem.self, from: data)

    XCTAssertEqual(decoded, original)
    XCTAssertTrue(decoded.canRetry)
    XCTAssertTrue(decoded.requiresDuplicateChargeConfirmation)
  }

  func testUnboundLegacyRetryIntentsRemainFailClosed() {
    let knowledgeTask = WorkbenchTaskItem(
      id: "knowledge",
      kind: .knowledgeImport,
      detail: "导入失败",
      state: .failed,
      retryIntent: .knowledgeImport
    )
    let imageTask = WorkbenchTaskItem(
      id: "image",
      kind: .imageProcessing,
      detail: "处理失败",
      state: .failed,
      retryIntent: .imageProcessing
    )

    XCTAssertFalse(knowledgeTask.canRetry)
    XCTAssertFalse(imageTask.canRetry)
  }

  func testImageSummaryRetryIntentCarriesProfileID() throws {
    let profileID = UUID()
    let original = WorkbenchTaskItem(
      id: "image-summary",
      kind: .imageProcessing,
      detail: "图片资源扫描失败",
      state: .failed,
      retryIntent: .imageSummary(profileID: profileID)
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WorkbenchTaskItem.self, from: data)

    XCTAssertEqual(decoded.retryIntent, .imageSummary(profileID: profileID))
    XCTAssertTrue(decoded.canRetry)
  }
}
