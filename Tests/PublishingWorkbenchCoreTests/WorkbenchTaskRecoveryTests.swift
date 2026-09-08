import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchTaskRecoveryTests: WorkbenchStoreRemotePublishingTestCase {
  func testPreviewFailureRecoveryOnlyLocatesOriginalRecordWithoutPublishing() async throws {
    let transport = CountingRemoteRepositoryTransport()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport)
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    let package = store.publishingPackage(for: draft)
    let record = ReleaseRecord.remotePublishFailure(
      package: package, profile: store.activeProfile, mode: .previewBranch,
      errorMessage: "Preview request failed"
    )
    store.setReleaseRecords([record])
    store.setPublishActionMessage(record.summary, status: .failure)
    let task = try XCTUnwrap(store.activityStatus.taskCenterItems.first { $0.kind == .gitPush })
    XCTAssertTrue(task.requiresPublishReview)
    XCTAssertEqual(task.target, .releaseRecord(record.id))
    XCTAssertTrue(task.detail.contains(package.draftPreviewBranchName))
    await store.activityStatus.retryTask(task)
    let requests = await transport.requestCount()
    XCTAssertEqual(requests, 0)
    XCTAssertEqual(store.releaseRecords.map(\.id), [record.id])
    XCTAssertTrue(store.publishActionMessage?.contains("未自动提交或推送") == true)
  }

  func testLegacyLocalWriteRetryCannotCommitInGitRepository() async throws {
    let root = try preparedGitRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TestWorkbenchFactory.makeStore()
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(root)
    store.updateActiveProfile(profile)
    let draft = try XCTUnwrap(store.selectedDraft)
    let head = try git(["rev-parse", "HEAD"], rootURL: root)
    let status = try git(["status", "--porcelain"], rootURL: root)
    let task = WorkbenchTaskItem(
      id: "old-local-write", kind: .gitPush, detail: "Write failed", state: .failed,
      retryIntent: .gitDraft(profileID: profile.id, draftID: draft.id), target: .draft(draft.id)
    )
    await store.activityStatus.retryTask(task)
    XCTAssertEqual(try git(["rev-parse", "HEAD"], rootURL: root), head)
    XCTAssertEqual(try git(["status", "--porcelain"], rootURL: root), status)
    XCTAssertNil(store.localGitPublishResult)
  }

  func testLocalSuccessDoesNotReusePreviousRemoteFailure() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let activity = store.activityStatus
    store.setRemoteRepositoryPublishing(true)
    store.setRemoteRepositoryPublishProgress(
      .init(stage: .failed, progress: nil, message: "A failed"))
    store.setRemoteRepositoryPublishing(false)
    store.createDraft()
    let local = try XCTUnwrap(
      store.publishingStore.beginLocalRepositoryMutation(profile: store.activeProfile))
    store.setPublishActionMessage("B succeeded", status: .success)
    store.publishingStore.finishLocalRepositoryMutation(local)
    XCTAssertNil(activity.taskCenterItems.first { $0.kind == .gitPush })
  }

  func testNewRemoteFailureDoesNotBorrowOlderFailureRecord() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let old = ReleaseRecord(
      kind: .remotePublishFailure, title: "A", summary: "A failed",
      siteProfileID: store.activeProfileID)
    store.setReleaseRecords([old])
    let activity = store.activityStatus
    store.createDraft()
    let currentID = try XCTUnwrap(store.selectedDraftID)
    store.setRemoteRepositoryPublishing(true)
    store.setRemoteRepositoryPublishProgress(
      .init(stage: .failed, progress: nil, message: "B failed"))
    store.setRemoteRepositoryPublishing(false)
    let task = try XCTUnwrap(activity.taskCenterItems.first { $0.kind == .gitPush })
    XCTAssertEqual(task.target, .draft(currentID))
    XCTAssertEqual(task.failureReason, "B failed")
    XCTAssertNotEqual(task.target, .releaseRecord(old.id))
  }

  func testHistoricalDeploymentResultsStayActionableWithoutCountingAsActive() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let record = ReleaseRecord(
      kind: .remoteDirectCommit, title: "Release", summary: "Pushed",
      siteProfileID: store.activeProfileID)
    store.setReleaseRecords([record])
    let checkedAt = Date(timeIntervalSince1970: 123_456)
    for (level, state) in [
      (DeploymentStatusLevel.running, WorkbenchTaskState.waiting), (.unknown, .needsAttention),
      (.failed, .failed),
    ] {
      store.deploymentStore.recordDeploymentStatusSnapshot(
        DeploymentStatusSnapshot(
          profileID: store.activeProfileID, releaseRecordID: record.id, provider: .cloudflarePages,
          level: level, title: "Deployment", message: "Awaiting evidence", siteURLText: nil,
          checkedAt: checkedAt, signals: []
        ), for: record
      )
      let task = try XCTUnwrap(
        store.activityStatus.taskCenterItems.first { $0.kind == .deployment })
      XCTAssertEqual(task.state, state)
      XCTAssertFalse(task.isActive)
      XCTAssertTrue(task.canRetry)
      XCTAssertEqual(task.checkedAt, checkedAt)
      XCTAssertEqual(task.retryIntent, .deployment(recordID: record.id))
      XCTAssertEqual(store.activityStatus.activeTaskCount, 0)
      let roundTrip = try JSONDecoder().decode(
        WorkbenchTaskItem.self, from: JSONEncoder().encode(task))
      XCTAssertEqual(roundTrip, task)
    }
    store.deploymentStore.isDeploymentStatusChecking = true
    let checking = try XCTUnwrap(
      store.activityStatus.taskCenterItems.first { $0.kind == .deployment })
    XCTAssertTrue(checking.isActive)
    XCTAssertNil(checking.target, "A global check must not claim an unrelated historical target")
  }
}
