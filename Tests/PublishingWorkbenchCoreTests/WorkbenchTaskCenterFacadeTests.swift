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
}
