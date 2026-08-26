import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchTaskCenterFacadeTests: XCTestCase {
  func testTaskCenterAggregatesRunningAIRepositoryAndGitTasks() throws {
    let store = WorkbenchStore()
    let activityStatus = store.activityStatus

    store.setAIChatRunning(true)
    store.repositoryStore.repositoryScanState = .scanning()
    store.setRemoteRepositoryPublishing(true)
    store.setRemoteRepositoryPublishProgress(
      RemoteRepositoryPublishProgress(
        stage: .uploadingFiles,
        progress: 0.4,
        message: "正在上传",
        detail: "article.md",
        completedByteCount: 12_300_000,
        totalByteCount: 18_900_000
      )
    )

    let tasks = activityStatus.taskCenterItems
    let gitTask = try XCTUnwrap(tasks.first(where: { $0.kind == .gitPush }))
    XCTAssertEqual(tasks.map(\.kind), [.aiRequest, .siteScan, .gitPush])
    XCTAssertEqual(
      try XCTUnwrap(gitTask.progress),
      12_300_000.0 / 18_900_000.0,
      accuracy: 0.000_001
    )
    XCTAssertTrue(gitTask.detail.contains("12.3 MB"))
    XCTAssertTrue(tasks.allSatisfy(\.isActive))
  }

  func testTaskCenterKeepsGitProgressIndeterminateWithoutByteTotals() throws {
    let store = WorkbenchStore()
    store.setRemoteRepositoryPublishing(true)
    store.setRemoteRepositoryPublishProgress(
      RemoteRepositoryPublishProgress(
        stage: .uploadingFiles,
        progress: 0.4,
        message: "正在上传",
        detail: "article.md"
      )
    )

    let task = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first { $0.kind == .gitPush }
    )
    XCTAssertNil(task.progress)
    XCTAssertEqual(task.detail, "正在上传 · article.md")
  }

  func testTaskCenterExposesAIFailureAndManualRetryAvailability() throws {
    let store = WorkbenchStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let conversationID = UUID()
    store.aiStore.aiChatManualRetryState = AIChatManualRetryState(
      draftID: draft.id,
      conversationID: conversationID,
      requiresDuplicateChargeConfirmation: false
    )
    store.setAIChatMessage("AI 讨论失败：网络超时")

    let task = try XCTUnwrap(store.activityStatus.taskCenterItems.first)
    XCTAssertEqual(task.kind, .aiRequest)
    XCTAssertEqual(task.state, .failed)
    XCTAssertEqual(task.failureReason, "AI 讨论失败：网络超时")
    XCTAssertTrue(task.canRetry)
  }

  func testGitFailureUsesStructuredStatusInsteadOfMessageKeywords() throws {
    let store = WorkbenchStore()
    store.setPublishActionMessage(
      "Repository rejected the operation.",
      status: .failure
    )

    let task = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first { $0.kind == .gitPush }
    )
    XCTAssertEqual(task.state, .failed)
    XCTAssertEqual(task.failureReason, "Repository rejected the operation.")
  }

  func testGitWarningDoesNotBecomeFailureFromMessageText() {
    let store = WorkbenchStore()
    store.setPublishActionMessage("没有可提交的发布包。", status: .warning)

    XCTAssertNil(
      store.activityStatus.taskCenterItems.first { $0.kind == .gitPush }
    )
  }

  func testLegacyMessageDefaultsToInformation() {
    let store = WorkbenchStore()
    store.setPublishActionMessage("旧调用中的失败文案")

    XCTAssertEqual(store.publishActionFeedback?.status, .information)
    XCTAssertNil(
      store.activityStatus.taskCenterItems.first { $0.kind == .gitPush }
    )
  }

  func testAIRetryWithoutConfirmationDoesNotClearRetryStateOrSend() async throws {
    let store = WorkbenchStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let retryState = AIChatManualRetryState(
      draftID: draft.id,
      conversationID: UUID(),
      requiresDuplicateChargeConfirmation: true
    )
    store.aiStore.aiChatManualRetryState = retryState
    store.setAIChatMessage("AI 讨论失败：网络超时")

    let task = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first { $0.kind == .aiRequest }
    )
    XCTAssertTrue(task.requiresDuplicateChargeConfirmation)

    await store.activityStatus.retryTask(task)

    XCTAssertEqual(store.aiStore.aiChatManualRetryState, retryState)
  }

  func testGeneralAIRetryRequiresExactOperationAndConfirmation() async throws {
    let store = WorkbenchStore()
    let conversation = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation()
    )
    let retryState = AIGeneralChatManualRetryState(
      conversationID: conversation.id,
      operationID: UUID(),
      requiresDuplicateChargeConfirmation: true
    )
    store.aiStore.aiGeneralChatManualRetryState = retryState
    store.setAIChatMessage("AI 通用对话失败：网络超时")

    let task = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first { $0.kind == .aiRequest }
    )
    guard case .generalAIChat(
      let taskConversationID,
      let taskOperationID,
      let requiresConfirmation
    )? = task.retryIntent else {
      return XCTFail("expected a typed general AI retry intent")
    }
    XCTAssertEqual(taskConversationID, conversation.id)
    XCTAssertEqual(taskOperationID, retryState.operationID)
    XCTAssertTrue(requiresConfirmation)

    await store.activityStatus.retryTask(task)

    XCTAssertEqual(store.aiStore.aiGeneralChatManualRetryState, retryState)
    XCTAssertFalse(store.isAIChatRunning)

    let changedRetryState = AIGeneralChatManualRetryState(
      conversationID: conversation.id,
      operationID: UUID(),
      requiresDuplicateChargeConfirmation: true
    )
    store.aiStore.aiGeneralChatManualRetryState = changedRetryState
    await store.activityStatus.retryTask(
      task,
      confirmingPossibleDuplicateCharge: true
    )

    XCTAssertEqual(store.aiStore.aiGeneralChatManualRetryState, changedRetryState)
    XCTAssertFalse(store.isAIChatRunning)
  }

  func testImageSummaryRetryFailsClosedForAnotherProfile() async throws {
    let store = WorkbenchStore()
    let task = WorkbenchTaskItem(
      id: "image-summary",
      kind: .imageProcessing,
      detail: "图片资源扫描失败",
      state: .failed,
      retryIntent: .imageSummary(profileID: UUID())
    )

    await store.activityStatus.retryTask(task)

    XCTAssertNil(store.imageStore.siteSummaryErrorMessage)
    XCTAssertFalse(store.imageStore.isSiteSummaryLoading)
  }

  func testBatchGitFailureCarriesBatchIntentInsteadOfSelectedDraft() throws {
    let store = WorkbenchStore()
    let firstDraftID = UUID()
    let secondDraftID = UUID()
    let record = ReleaseRecord(
      kind: .remotePublishFailure,
      title: "批量线上发布失败",
      summary: "批量发布失败",
      siteProfileID: store.activeProfileID,
      batchItems: [
        ReleaseRecordBatchItem(
          draftID: firstDraftID,
          draftTitle: "第一篇",
          markdownPath: "content/first.md",
          changedPaths: ["content/first.md"]
        ),
        ReleaseRecordBatchItem(
          draftID: secondDraftID,
          draftTitle: "第二篇",
          markdownPath: "content/second.md",
          changedPaths: ["content/second.md"]
        ),
      ]
    )
    store.setReleaseRecords([record])
    store.setPublishActionMessage("批量线上发布失败", status: .failure)

    let task = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first { $0.kind == .gitPush }
    )
    guard case .gitRemoteBatch(let profileID, let draftIDs)? = task.retryIntent else {
      return XCTFail("expected a typed batch retry intent")
    }
    XCTAssertEqual(profileID, store.activeProfileID)
    XCTAssertEqual(draftIDs, [firstDraftID, secondDraftID])
    XCTAssertTrue(task.canRetry)
  }

}
