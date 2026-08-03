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
        detail: "article.md"
      )
    )

    let tasks = activityStatus.taskCenterItems
    XCTAssertEqual(tasks.map(\.kind), [.aiRequest, .siteScan, .gitPush])
    XCTAssertEqual(tasks.first(where: { $0.kind == .gitPush })?.progress, 0.4)
    XCTAssertTrue(tasks.allSatisfy(\.isActive))
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
}
