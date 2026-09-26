import PublishingDomainContracts
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchTaskCenterFacadeTests: XCTestCase {
  private func makeStore() -> WorkbenchStore {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("task-center-followup-" + UUID().uuidString + ".json")
    return WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
  }

  func testResourceNavigationCanOnlyBeConsumedByRequestingWindow() throws {
    let store = makeStore()
    let windowID = UUID()
    let task = WorkbenchTaskItem(
      id: "resource-owner", kind: .imageProcessing, detail: "Done", state: .completed,
      target: .assetResourceManager(profileID: store.activeProfileID)
    )
    XCTAssertNil(store.activityStatus.locateTask(task, windowID: windowID))
    let request = try XCTUnwrap(store.imageWorkbench.assetResourceManagerNavigationRequest)
    XCTAssertEqual(request.windowID, windowID)
    store.imageWorkbench.consumeAssetResourceManagerNavigationRequest(request, from: UUID())
    XCTAssertEqual(store.imageWorkbench.assetResourceManagerNavigationRequest, request)
    store.imageWorkbench.consumeAssetResourceManagerNavigationRequest(request, from: windowID)
    XCTAssertNil(store.imageWorkbench.assetResourceManagerNavigationRequest)
  }

  func testTaskCenterAggregatesRunningAIRepositoryAndGitTasks() throws {
    let store = makeStore()
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
    let store = makeStore()
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
    let store = makeStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let conversationID = UUID()
    store.setReleaseRecords([
      ReleaseRecord(
        kind: .remotePublishFailure, title: "Unrelated publish", summary: "Failed",
        siteProfileID: store.activeProfileID
      )
    ])
    store.aiStore.aiChatManualRetryState = AIChatManualRetryState(
      draftID: draft.id,
      conversationID: conversationID,
      requiresDuplicateChargeConfirmation: false
    )
    store.setAIChatFailureMessage("AI 讨论失败：网络超时")

    let task = try XCTUnwrap(store.activityStatus.taskCenterItems.first)
    XCTAssertEqual(task.kind, .aiRequest)
    XCTAssertEqual(task.state, .failed)
    XCTAssertEqual(task.failureReason, "AI 讨论失败：网络超时")
    XCTAssertTrue(task.canRetry)
    XCTAssertEqual(
      task.target, .articleConversation(draftID: draft.id, conversationID: conversationID)
    )
  }

  func testCancellingAnOldTaskCannotCancelTheNewAIChatOperation() throws {
    let store = makeStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    store.aiStore.prepareAIChat(for: draft)
    _ = try XCTUnwrap(store.aiStore.startNewAIChatConversation(draft: draft))
    let firstOperationID = try XCTUnwrap(
      store.aiStore.beginAIChatOperation(statusMessage: "第一项任务")
    )
    let oldTask = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first { $0.kind == .aiRequest }
    )
    XCTAssertTrue(oldTask.canCancel)
    store.aiStore.finishAIChatOperation(firstOperationID)

    let secondOperationID = try XCTUnwrap(
      store.aiStore.beginAIChatOperation(statusMessage: "第二项任务")
    )
    XCTAssertNotNil(store.activityStatus.cancelTask(oldTask))
    XCTAssertEqual(store.aiStore.activeAIChatOperationID, secondOperationID)
    XCTAssertFalse(store.aiStore.aiChatCancellationRequested())
    store.aiStore.finishAIChatOperation(secondOperationID)
  }

  func testAIRequestFailureUsesTypedStatusAndClearsOnNewMessage() throws {
    let store = makeStore()
    store.setAIChatFailureMessage("The request was rejected by the provider.")

    let task = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first { $0.kind == .aiRequest }
    )
    XCTAssertEqual(task.state, .failed)
    XCTAssertEqual(task.failureReason, "The request was rejected by the provider.")

    store.setAIChatMessage("无法完成请求")
    XCTAssertNil(store.activityStatus.taskCenterItems.first { $0.kind == .aiRequest })

    store.setAIActionFailureMessage("The metadata request timed out.")
    XCTAssertEqual(
      store.activityStatus.taskCenterItems.first { $0.kind == .aiRequest }?.failureReason,
      "The metadata request timed out."
    )
    store.setAIActionMessage("Ready")
    XCTAssertNil(store.activityStatus.taskCenterItems.first { $0.kind == .aiRequest })
  }

  func testTaskCenterStopCancelsRegisteredRequestTaskAndReleasesAIRequestLane() async throws {
    let store = makeStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    store.aiStore.prepareAIChat(for: draft)
    _ = try XCTUnwrap(store.aiStore.startNewAIChatConversation(draft: draft))
    let operationID = try XCTUnwrap(
      store.aiStore.beginAIChatOperation(statusMessage: "等待首个响应")
    )
    let taskRow = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first { $0.kind == .aiRequest }
    )
    let started = expectation(description: "request task started")
    let cancelled = expectation(description: "request task cancelled")
    let request = Task { @MainActor in
      await store.aiStore.runAIChatRequestTask(operationID: operationID) {
        started.fulfill()
        defer { store.aiStore.finishAIChatOperation(operationID) }
        do {
          try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch is CancellationError {
          cancelled.fulfill()
        } catch {
          XCTFail("Unexpected request error: \(error)")
        }
        return nil
      }
    }
    await fulfillment(of: [started], timeout: 1)

    XCTAssertNil(store.activityStatus.cancelTask(taskRow))
    await fulfillment(of: [cancelled], timeout: 1)
    _ = await request.value
    XCTAssertFalse(store.isAIChatRunning)
    XCTAssertNil(store.aiStore.activeAIChatOperationID)
  }

  func testParentTaskCancellationPropagatesToRegisteredRequestTask() async throws {
    let store = makeStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    store.aiStore.prepareAIChat(for: draft)
    _ = try XCTUnwrap(store.aiStore.startNewAIChatConversation(draft: draft))
    let operationID = try XCTUnwrap(
      store.aiStore.beginAIChatOperation(statusMessage: "等待首个响应")
    )
    let started = expectation(description: "request task started")
    let cancelled = expectation(description: "child task cancelled")
    let parent = Task { @MainActor in
      await store.aiStore.runAIChatRequestTask(operationID: operationID) {
        started.fulfill()
        defer { store.aiStore.finishAIChatOperation(operationID) }
        do {
          try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch is CancellationError {
          cancelled.fulfill()
        } catch {
          XCTFail("Unexpected request error: \(error)")
        }
        return nil
      }
    }
    await fulfillment(of: [started], timeout: 1)

    parent.cancel()
    await fulfillment(of: [cancelled], timeout: 1)
    _ = await parent.value
    XCTAssertFalse(store.isAIChatRunning)
    XCTAssertNil(store.aiStore.activeAIChatOperationID)
  }

  func testRunningAIChatTaskKeepsOriginalConversationWhenFocusChanges() throws {
    let store = makeStore()
    let originalDraft = try XCTUnwrap(store.selectedDraft)
    store.aiStore.prepareAIChat(for: originalDraft)
    let originalConversation = try XCTUnwrap(
      store.aiStore.startNewAIChatConversation(draft: originalDraft)
    )

    store.createDraft()
    let differentDraft = try XCTUnwrap(store.selectedDraft)
    store.aiStore.prepareAIChat(for: differentDraft)
    _ = try XCTUnwrap(store.aiStore.startNewAIChatConversation(draft: differentDraft))

    store.aiStore.prepareAIChat(for: originalDraft)
    let operationID = try XCTUnwrap(
      store.aiStore.beginAIChatOperation(statusMessage: "原对话正在回复")
    )
    store.aiStore.prepareAIChat(for: differentDraft)
    let task = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first { $0.kind == .aiRequest }
    )

    XCTAssertEqual(
      task.target,
      .articleConversation(draftID: originalDraft.id, conversationID: originalConversation.id)
    )
    XCTAssertEqual(
      task.cancellationIntent,
      .aiChat(
        operationID: operationID,
        target: .articleConversation(
          draftID: originalDraft.id,
          conversationID: originalConversation.id
        )
      )
    )
    XCTAssertNil(store.activityStatus.cancelTask(task))
    XCTAssertTrue(store.aiStore.aiChatCancellationRequested())
    store.aiStore.finishAIChatOperation(operationID)
  }

  func testLocatingTaskUsesFrozenDraftTargetInsteadOfCurrentSelection() throws {
    let store = makeStore()
    let originalDraftID = try XCTUnwrap(store.selectedDraft?.id)
    store.createDraft()
    let differentDraftID = try XCTUnwrap(store.selectedDraft?.id)
    XCTAssertNotEqual(originalDraftID, differentDraftID)
    let task = WorkbenchTaskItem(
      id: "frozen-draft-target",
      kind: .gitPush,
      detail: "需要定位",
      state: .failed,
      target: .draft(originalDraftID)
    )

    XCTAssertNil(store.activityStatus.locateTask(task))
    XCTAssertEqual(store.selectedDraftID, originalDraftID)
  }

  func testUnrelatedPublishFailureDoesNotBecomeGitTaskAfterRemoteOperation() {
    let store = makeStore()
    _ = store.activityStatus
    store.setRemoteRepositoryPublishing(true)
    store.setPublishActionMessage(
      "本地预览启动失败。",
      status: .failure
    )

    let runningTask = store.activityStatus.taskCenterItems.first {
      $0.kind == .gitPush
    }
    guard let runningTask else {
      return XCTFail("expected the active Git operation")
    }
    XCTAssertEqual(runningTask.state, .running)
    XCTAssertEqual(runningTask.detail, "正在执行 Git 操作…")
    XCTAssertEqual(store.publishActionFeedback?.source, .general)
    XCTAssertNil(store.publishDrawerFeedback)
    store.setRemoteRepositoryPublishing(false)
    XCTAssertNil(
      store.activityStatus.taskCenterItems.first { $0.kind == .gitPush }
    )
    XCTAssertEqual(store.activityStatus.failedTaskCount, 0)
  }

  func testPublishDrawerFeedbackRequiresExplicitPublishingSource() {
    let store = makeStore()

    store.setPublishActionMessage("站点文件写入失败。", status: .failure)
    XCTAssertNil(store.publishDrawerFeedback)

    store.publishingStore.setPublishingActionMessage("线上发布失败。", status: .failure)

    XCTAssertEqual(store.publishDrawerFeedback?.message, "线上发布失败。")
    XCTAssertEqual(store.publishDrawerFeedback?.source, .publishing)
  }

  func testFailedRemoteGitProgressCreatesRetryableGitTask() throws {
    let store = makeStore()
    let draftID = try XCTUnwrap(store.selectedDraft?.id)
    _ = store.activityStatus
    store.setRemoteRepositoryPublishing(true)
    store.setRemoteRepositoryPublishProgress(
      RemoteRepositoryPublishProgress(
        stage: .failed,
        progress: nil,
        message: "远端推送失败",
        detail: "权限被拒绝"
      )
    )
    store.setRemoteRepositoryPublishing(false)

    let task = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first { $0.kind == .gitPush }
    )
    XCTAssertEqual(task.state, .failed)
    XCTAssertEqual(task.failureReason, "权限被拒绝")
    XCTAssertTrue(task.canRetry)
    XCTAssertEqual(
      task.retryIntent,
      .gitRemoteDraft(profileID: store.activeProfileID, draftID: draftID)
    )
    XCTAssertEqual(
      task.target,
      .draft(draftID)
    )
  }

  func testExplicitGitFailureFeedbackKeepsRetryableGitTask() throws {
    let store = makeStore()
    let draftID = try XCTUnwrap(store.selectedDraft?.id)
    _ = store.activityStatus
    store.setRemoteRepositoryPublishing(true)
    store.setRemoteRepositoryPublishing(false)
    store.setGitActionMessage("Git 推送失败。", status: .failure)

    let task = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first { $0.kind == .gitPush }
    )
    XCTAssertEqual(task.failureReason, "Git 推送失败。")
    XCTAssertEqual(
      task.retryIntent,
      .gitRemoteDraft(profileID: store.activeProfileID, draftID: draftID)
    )
    XCTAssertEqual(task.target, .draft(draftID))
  }

  func testHistoricalGitFailureRecordDoesNotCreateTaskBeforeGitOperation() {
    let store = makeStore()
    _ = store.activityStatus
    store.publishingStore.prependReleaseRecord(
      ReleaseRecord(
        kind: .remotePublishFailure, title: "Old failure", summary: "权限被拒绝",
        siteProfileID: store.activeProfileID,
        createdAt: Date(timeIntervalSinceNow: -86_400)
      )
    )

    XCTAssertNil(
      store.activityStatus.taskCenterItems.first { $0.kind == .gitPush }
    )
    XCTAssertEqual(store.activityStatus.failedTaskCount, 0)
    store.setGitActionMessage("Git 推送失败。", status: .failure)
    XCTAssertEqual(
      store.activityStatus.taskCenterItems.first { $0.kind == .gitPush }?.failureReason,
      "Git 推送失败。"
    )
  }

  func testGitWarningDoesNotBecomeFailureFromMessageText() {
    let store = makeStore()
    store.setPublishActionMessage("没有可提交的发布包。", status: .warning)

    XCTAssertNil(
      store.activityStatus.taskCenterItems.first { $0.kind == .gitPush }
    )
  }

  func testLegacyMessageDefaultsToInformation() {
    let store = makeStore()
    store.setPublishActionMessage("旧调用中的失败文案")

    XCTAssertEqual(store.publishActionFeedback?.status, .information)
    XCTAssertNil(
      store.activityStatus.taskCenterItems.first { $0.kind == .gitPush }
    )
  }

  func testAIRetryWithoutConfirmationDoesNotClearRetryStateOrSend() async throws {
    let store = makeStore()
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
    let store = makeStore()
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
    guard
      case .generalAIChat(
        let taskConversationID,
        let taskOperationID,
        let requiresConfirmation
      )? = task.retryIntent
    else {
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
    let store = makeStore()
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
    let store = makeStore()
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
