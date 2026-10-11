import AppKit
import Combine
import PublishingGitCore
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class PublishDrawerPresentationTests: XCTestCase {
  @MainActor
  func testRefreshCannotReplaceOrCancelAnInFlightOperation() async {
    let controller = PublishDrawerOperationController()
    let cancelled = expectation(description: "cleanup cancels original operation")
    var started = false
    var observedCancellation = false
    var refreshStarted = false
    controller.start {
      started = true
      do {
        try await Task.sleep(for: .seconds(30))
      } catch {
        observedCancellation = true
        cancelled.fulfill()
      }
    }
    for _ in 0..<20 where !started { await Task.yield() }
    XCTAssertTrue(started)
    XCTAssertFalse(controller.startIfIdle { refreshStarted = true })
    await Task.yield()
    XCTAssertTrue(controller.isRunning)
    XCTAssertFalse(observedCancellation)
    XCTAssertFalse(refreshStarted)
    controller.cancel()
    await fulfillment(of: [cancelled], timeout: 1)
  }

  func testInspectorTabsShareOneResizableWidthRange() {
    XCTAssertEqual(WorkbenchLayoutMode.inspectorMinimumWidth, 280)
    XCTAssertEqual(WorkbenchLayoutMode.inspectorIdealWidth, 320)
    XCTAssertEqual(WorkbenchLayoutMode.inspectorMaximumWidth, 560)
    XCTAssertLessThan(
      WorkbenchLayoutMode.inspectorMinimumWidth, WorkbenchLayoutMode.inspectorMaximumWidth,
      "Users must be able to drag the Inspector narrower or wider."
    )
  }

  @MainActor
  func testPublishDrawerOperationControllerReleasesBusyStateWhenCancelled() async {
    let controller = PublishDrawerOperationController()
    let cancellationExpectation = expectation(description: "operation observes cancellation")
    var operationStarted = false

    controller.start {
      operationStarted = true
      do {
        try await Task.sleep(for: .seconds(30))
      } catch is CancellationError {
        cancellationExpectation.fulfill()
      } catch {
        XCTFail("Unexpected cancellation error: \(error)")
      }
    }

    for _ in 0..<10 where !operationStarted {
      await Task.yield()
    }
    XCTAssertTrue(operationStarted)
    XCTAssertTrue(controller.isRunning)

    controller.cancel()
    await fulfillment(of: [cancellationExpectation], timeout: 1)

    XCTAssertFalse(controller.isRunning)
  }

  func testPublishFeedbackPreservesSeverityAndProvidesAccessiblePresentation() {
    let expectations: [(PublishActionMessageStatus, String, String)] = [
      (.information, "信息", "info.circle.fill"),
      (.success, "成功", "checkmark.circle.fill"),
      (.warning, "警告", "exclamationmark.triangle.fill"),
      (.failure, "失败", "xmark.octagon.fill"),
    ]

    for (status, title, systemImage) in expectations {
      XCTAssertEqual(status.publishDrawerTitle, title)
      XCTAssertEqual(status.publishDrawerSystemImage, systemImage)
    }
  }

  func testBatchActionExplainsMissingRepositoryConfiguration() {
    let state = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: false,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 2,
      changedFileCount: 4
    )

    XCTAssertFalse(PublishDrawerBatchActionPresentation.isEnabled(state))
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(state),
      "先配置线上仓库"
    )
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.accessibilityHint(
        isEnabled: false,
        status: PublishDrawerBatchActionPresentation.status(state)
      ),
      "先配置线上仓库"
    )
  }

  func testBatchActionExplainsTokenAndPermissionGates() {
    let missingToken = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: false,
      publishableArticleCount: 2,
      changedFileCount: 4
    )
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(missingToken),
      "请先保存仓库 Token"
    )

    let unchecked = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .unchecked,
      publishableArticleCount: 2,
      changedFileCount: 4
    )
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(unchecked),
      "请先检查仓库写入权限"
    )
    XCTAssertFalse(PublishDrawerBatchActionPresentation.isEnabled(unchecked))

    let readOnly = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .readOnly,
      publishableArticleCount: 2,
      changedFileCount: 4
    )
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(readOnly),
      "Token 没有仓库写入权限"
    )
  }

  func testBatchActionExplainsEmptyQueueAndBusyStates() {
    let empty = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 0,
      changedFileCount: 0
    )
    XCTAssertFalse(PublishDrawerBatchActionPresentation.isEnabled(empty))
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(empty),
      "没有待处理变更"
    )

    let refreshing = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 2,
      changedFileCount: 4,
      isPlanRefreshing: true
    )
    XCTAssertFalse(PublishDrawerBatchActionPresentation.isEnabled(refreshing))
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(refreshing),
      "正在汇总文章发布包"
    )

    let publishing = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 2,
      changedFileCount: 4,
      isPublishing: true
    )
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(publishing),
      "正在发布文章"
    )
  }

  func testBatchActionUsesArticleSpecificNameAndEnablesOnlyWhenReady() {
    let ready = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 2,
      changedFileCount: 4
    )

    XCTAssertTrue(PublishDrawerBatchActionPresentation.isEnabled(ready))
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(ready),
      "可发布 2 篇文章 · 4 个文章文件"
    )
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.title,
      "审阅并发布文章变更"
    )
    XCTAssertTrue(
      PublishDrawerBatchActionPresentation.detail.contains("CSS")
    )
    XCTAssertTrue(
      PublishDrawerBatchActionPresentation.detail.contains("模板")
    )
    XCTAssertTrue(
      PublishDrawerBatchActionPresentation.detail.contains("脚本")
    )
  }

  func testBatchActionAllowsKnownRemoteConflictToEnterAuthoritativeRecheck() {
    let conflicted = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      hasRemoteConflict: true,
      publishableArticleCount: 2,
      changedFileCount: 2
    )

    XCTAssertTrue(PublishDrawerBatchActionPresentation.isEnabled(conflicted))
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(conflicted),
      "远端存在冲突，请先核对"
    )
  }

  func testBatchActionExcludesCleanupOnlyQueue() {
    let cleanupOnly = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 0,
      pendingDeletionCount: 2,
      changedFileCount: 2
    )

    XCTAssertFalse(PublishDrawerBatchActionPresentation.isEnabled(cleanupOnly))
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(cleanupOnly),
      "没有可发布文章；待下线请求请到回收站单独处理"
    )
  }

  func testBatchActionExplainsCleanupIsExcludedFromMixedQueue() {
    let mixed = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 3,
      pendingDeletionCount: 2,
      changedFileCount: 7
    )

    XCTAssertTrue(PublishDrawerBatchActionPresentation.isEnabled(mixed))
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(mixed),
      "可发布 3 篇 · 7 个文件 · 不包含 2 个待下线请求"
    )
  }

  func testBatchActionExplainsThatWebsiteDraftsUseSeparateSyncQueue() {
    let draftOnly = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 0,
      draftSyncArticleCount: 2,
      changedFileCount: 2
    )

    XCTAssertFalse(PublishDrawerBatchActionPresentation.isEnabled(draftOnly))
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(draftOnly),
      "2 篇网站草稿未纳入发布，请单独同步"
    )

    var mixed = draftOnly
    mixed.publishableArticleCount = 1
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(mixed),
      "可发布 1 篇文章 · 2 个文章文件 · 另有 2 篇网站草稿未纳入发布"
    )
  }

  func testSingleWebsiteDraftActionUsesExplicitSyncLanguage() {
    let presentation = PublishDrawerSingleArticleActionPresentation.make(
      isWebsiteDraft: true
    )

    XCTAssertEqual(presentation.actionTitle, "同步当前网站草稿…")
    XCTAssertEqual(presentation.accessibilityLabel, "同步当前网站草稿")
    XCTAssertTrue(presentation.enabledHint.contains("不会纳入批量正式发布"))
    XCTAssertEqual(
      presentation.confirmationPurpose.confirmationTitle,
      "网站草稿同步确认"
    )
    XCTAssertTrue(
      presentation.confirmationPurpose.confirmationDetail.contains("不会移除 draft 标记")
    )
    XCTAssertEqual(
      presentation.confirmationPurpose.confirmActionTitle,
      "确认同步网站草稿"
    )
  }

  func testSingleFormalArticleActionKeepsPublicationLanguage() {
    let presentation = PublishDrawerSingleArticleActionPresentation.make(
      isWebsiteDraft: false
    )

    XCTAssertEqual(presentation.actionTitle, "仅发布当前文章…")
    XCTAssertEqual(presentation.confirmationPurpose, .publication)
    XCTAssertEqual(presentation.confirmationPurpose.confirmationTitle, "最终发布确认")
  }

  func testPermissionActionUsesDetectedOriginWhenProfileIsMissing() {
    let origin = RepositoryRemote(
      remoteURL: "git@github.com:lldynamics/site.git",
      provider: .github,
      repositoryBaseURL: "https://api.github.com",
      owner: "lldynamics",
      name: "site"
    )

    let presentation = RepositoryPermissionActionPresentation.make(
      configuredOwner: "",
      configuredRepository: "",
      detectedOrigin: origin
    )

    XCTAssertTrue(presentation.isEnabled)
    XCTAssertEqual(presentation.title, "使用 lldynamics/site 并诊断连接")
    XCTAssertTrue(presentation.help.contains("lldynamics/site"))
  }

  func testPermissionActionDisablesWhenConfiguredOwnerDoesNotMatchOrigin() {
    let origin = RepositoryRemote(
      remoteURL: "git@github.com:lldynamics/site.git",
      provider: .github,
      repositoryBaseURL: "https://api.github.com",
      owner: "lldynamics",
      name: "site"
    )

    let presentation = RepositoryPermissionActionPresentation.make(
      configuredOwner: "other-owner",
      configuredRepository: "",
      detectedOrigin: origin
    )

    XCTAssertFalse(presentation.isEnabled)
    XCTAssertTrue(presentation.help.contains("不一致"))
    XCTAssertTrue(presentation.help.contains("修正"))
  }

  func testPermissionActionDisablesWhenConfiguredRepositoryDoesNotMatchOrigin() {
    let origin = RepositoryRemote(
      remoteURL: "git@github.com:lldynamics/site.git",
      provider: .github,
      repositoryBaseURL: "https://api.github.com",
      owner: "lldynamics",
      name: "site"
    )

    let presentation = RepositoryPermissionActionPresentation.make(
      configuredOwner: "",
      configuredRepository: "other-site",
      detectedOrigin: origin
    )

    XCTAssertFalse(presentation.isEnabled)
    XCTAssertTrue(presentation.help.contains("不一致"))
    XCTAssertTrue(presentation.help.contains("完成"))
  }

  func testPermissionActionDisablesWithoutConfiguredRepositoryOrOrigin() {
    let presentation = RepositoryPermissionActionPresentation.make(
      configuredOwner: "",
      configuredRepository: "",
      detectedOrigin: nil
    )

    XCTAssertFalse(presentation.isEnabled)
    XCTAssertEqual(presentation.title, "连接诊断")
    XCTAssertTrue(presentation.help.contains("先配置仓库"))
  }

  func testPermissionActionKeepsCheckTitleForConfiguredRepository() {
    let presentation = RepositoryPermissionActionPresentation.make(
      configuredOwner: "lldynamics",
      configuredRepository: "site",
      detectedOrigin: nil
    )

    XCTAssertTrue(presentation.isEnabled)
    XCTAssertEqual(presentation.title, "连接诊断")
  }

  func testReviewRequestRemoteConflictDoesNotBlockBatchActionPresentation() {
    let state = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      hasRemoteConflict: false,
      publishableArticleCount: 1,
      changedFileCount: 1
    )

    XCTAssertTrue(PublishDrawerBatchActionPresentation.isEnabled(state))
  }
}

@MainActor
final class WorkspaceArticlePublishSessionTests: XCTestCase {
  func testAttachedConfirmationSheetSharesItsOwnerAndOtherWindowsDoNot() {
    _ = NSApplication.shared
    let owner = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    let sheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    let other = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    owner.beginSheet(sheet)
    defer {
      owner.endSheet(sheet)
      sheet.orderOut(nil)
      owner.orderOut(nil)
      other.orderOut(nil)
    }
    XCTAssertTrue(WorkspaceArticlePublishSession.isOwnedWindow(owner, owner: owner))
    XCTAssertTrue(WorkspaceArticlePublishSession.isOwnedWindow(sheet, owner: owner))
    XCTAssertFalse(WorkspaceArticlePublishSession.isOwnedWindow(other, owner: owner))
    XCTAssertFalse(WorkspaceArticlePublishSession.isOwnedWindow(sheet, owner: other))
    XCTAssertFalse(WorkspaceArticlePublishSession.isOwnedWindow(nil, owner: owner))
  }

  func testWindowOrSiteSwitchBackStillInvalidatesOldPreparationAndAllowsNewOne() async {
    for switchSite in [false, true] {
      let initial = context()
      let window = WorkspaceWindowSession(
        windowID: initial.windowID, selectedSection: .writing, selectedDraftID: initial.draftID)
      window.setKeyWindow(true) { _, _ in }
      let profiles = CurrentValueSubject<UUID, Never>(initial.profileID)
      let session = WorkspaceArticlePublishSession()
      session.observeWindow(window, profileChanges: profiles.eraseToAnyPublisher())
      let old = SuspendedPublishSessionOperation()
      let replacement = SuspendedPublishSessionOperation()
      var deliveries = 0
      let current: @MainActor () -> WorkspaceArticlePublishSession.Context? = {
        guard window.isKeyWindow, window.selectedSection == .writing,
          let draftID = window.selectedDraftID
        else { return nil }
        return .init(windowID: window.windowID, draftID: draftID, profileID: profiles.value)
      }
      XCTAssertTrue(
        session.prepare(
          context: initial, currentContext: current,
          operation: {
            await old.run()
            return .drawer
          },
          onResult: { _ in deliveries += 1 }))
      await old.waitUntilStarted()
      if switchSite {
        profiles.send(UUID())
        profiles.send(initial.profileID)
      } else {
        window.selectDraft(UUID()) { _ in }
        window.selectDraft(initial.draftID) { _ in }
      }
      XCTAssertFalse(session.isPreparing)
      XCTAssertTrue(
        session.prepare(
          context: initial, currentContext: current,
          operation: {
            await replacement.run()
            return .drawer
          },
          onResult: { _ in deliveries += 1 }))
      await replacement.waitUntilStarted()
      old.resume()
      await old.waitUntilFinished()
      XCTAssertEqual(deliveries, 0)
      XCTAssertTrue(session.isPreparing)
      replacement.resume()
      await session.waitUntilIdle()
      XCTAssertEqual(deliveries, 1)
    }
  }

  func testCancellationBeforeSchedulingDoesNotStartPreparationOrRepair() async {
    let session = WorkspaceArticlePublishSession()
    let context = context()
    let repairID = UUID()
    var operations = 0
    XCTAssertTrue(
      session.prepare(
        context: context, currentContext: { context },
        operation: {
          operations += 1
          return .drawer
        }, onResult: { _ in XCTFail("Cancelled result") }))
    XCTAssertTrue(
      session.refreshChecks(
        context: context, repairID: repairID, currentContext: { context },
        currentRepairID: { repairID },
        operation: { operations += 1 }, onResult: { XCTFail("Cancelled repair") }))
    session.cancel()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(operations, 0)
    XCTAssertFalse(session.isPreparing)
    XCTAssertFalse(session.isRefreshingChecks)
  }

  func testCancelledPreparationCannotClearOrDeliverIntoReplacementOperation() async {
    let session = WorkspaceArticlePublishSession()
    let context = context()
    let old = SuspendedPublishSessionOperation()
    let replacement = SuspendedPublishSessionOperation()
    var deliveries = 0
    XCTAssertTrue(
      session.prepare(
        context: context, currentContext: { context },
        operation: {
          await old.run()
          return .drawer
        },
        onResult: { _ in deliveries += 1 }))
    await old.waitUntilStarted()
    session.cancel()
    XCTAssertFalse(session.isPreparing)
    XCTAssertTrue(
      session.prepare(
        context: context, currentContext: { context },
        operation: {
          await replacement.run()
          return .drawer
        },
        onResult: { _ in deliveries += 1 }))
    await replacement.waitUntilStarted()

    old.resume()
    await old.waitUntilFinished()
    XCTAssertTrue(session.isPreparing)
    XCTAssertEqual(deliveries, 0)
    replacement.resume()
    await session.waitUntilIdle()
    XCTAssertFalse(session.isPreparing)
    XCTAssertEqual(deliveries, 1)
  }

  func testChangingWindowDraftOrSiteRejectsPreparedResult() async {
    let initial = context()
    let replacements = [
      context(windowID: UUID(), draftID: initial.draftID, profileID: initial.profileID),
      context(windowID: initial.windowID, draftID: UUID(), profileID: initial.profileID),
      context(windowID: initial.windowID, draftID: initial.draftID, profileID: UUID()),
    ]
    for replacement in replacements {
      let session = WorkspaceArticlePublishSession()
      let gate = SuspendedPublishSessionOperation()
      var current = initial
      var delivered = false
      XCTAssertTrue(
        session.prepare(
          context: initial, currentContext: { current },
          operation: {
            await gate.run()
            return .drawer
          },
          onResult: { _ in delivered = true }))
      await gate.waitUntilStarted()
      current = replacement
      gate.resume()
      await session.waitUntilIdle()
      XCTAssertFalse(delivered)
      XCTAssertFalse(session.isPreparing)
      XCTAssertNil(session.pendingReview)
    }
  }

  func testClosingWindowCancelsPreparationAndRepairWithoutLateDelivery() async {
    let session = WorkspaceArticlePublishSession()
    let context = context()
    let repairID = UUID()
    let preparation = SuspendedPublishSessionOperation()
    let repair = SuspendedPublishSessionOperation()
    var deliveries = 0
    XCTAssertTrue(
      session.prepare(
        context: context, currentContext: { context },
        operation: {
          await preparation.run()
          return .drawer
        },
        onResult: { _ in deliveries += 1 }))
    XCTAssertTrue(
      session.refreshChecks(
        context: context, repairID: repairID, currentContext: { context },
        currentRepairID: { repairID }, operation: { await repair.run() },
        onResult: { deliveries += 1 }))
    await preparation.waitUntilStarted()
    await repair.waitUntilStarted()
    session.cancel()
    XCTAssertFalse(session.isPreparing)
    XCTAssertFalse(session.isRefreshingChecks)
    preparation.resume()
    repair.resume()
    await preparation.waitUntilFinished()
    await repair.waitUntilFinished()
    XCTAssertEqual(deliveries, 0)
  }

  func testChangedRepairIdentityRejectsLateCheckResult() async {
    let session = WorkspaceArticlePublishSession()
    let context = context()
    let initialRepairID = UUID()
    var currentRepairID: UUID? = initialRepairID
    let gate = SuspendedPublishSessionOperation()
    var delivered = false
    XCTAssertTrue(
      session.refreshChecks(
        context: context, repairID: initialRepairID, currentContext: { context },
        currentRepairID: { currentRepairID }, operation: { await gate.run() },
        onResult: { delivered = true }))
    await gate.waitUntilStarted()
    currentRepairID = UUID()
    gate.resume()
    await session.waitUntilIdle()
    XCTAssertFalse(delivered)
    XCTAssertFalse(session.isRefreshingChecks)
  }

  private func context(
    windowID: UUID = UUID(), draftID: UUID = UUID(), profileID: UUID = UUID()
  ) -> WorkspaceArticlePublishSession.Context {
    .init(windowID: windowID, draftID: draftID, profileID: profileID)
  }
}

/// Deliberately finishes even when its caller is cancelled, like a late
/// provider callback. Tests control both suspension and completion.
@MainActor
private final class SuspendedPublishSessionOperation {
  private var continuation: CheckedContinuation<Void, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []
  private var started = false
  private var finished = false

  func run() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      started = true
      for waiter in startWaiters { waiter.resume() }
      startWaiters.removeAll()
    }
    finished = true
    for waiter in finishWaiters { waiter.resume() }
    finishWaiters.removeAll()
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func waitUntilFinished() async {
    guard !finished else { return }
    await withCheckedContinuation { finishWaiters.append($0) }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

final class SingleArticlePublishFastPathPolicyTests: XCTestCase {
  @MainActor
  func testCancellationBeforeSchedulingCannotStartDirectPublish() async throws {
    let snapshot = makeSnapshot(includesImage: false)
    let profile = SiteProfile(
      id: snapshot.context.profileID, name: "Isolated site", repoOwner: "owner", repoName: "site")
    let draft = ArticleDraft(
      id: snapshot.context.draftID, siteProfileID: profile.id, title: "Article",
      bodyMarkdown: "Body")
    let review = try SinglePublishReviewSnapshot(draft: draft, profile: profile, snapshot: snapshot)
    let context = WorkspaceArticlePublishSession.Context(
      windowID: UUID(), draftID: draft.id, profileID: profile.id)
    let session = WorkspaceArticlePublishSession()
    var started = false
    XCTAssertTrue(
      session.publish(
        context: context, review: review, currentContext: { context },
        operation: {
          started = true
          return nil
        }, onResult: { _ in XCTFail("Cancelled publish") }))
    session.cancel()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertFalse(started)
    XCTAssertFalse(session.isPublishing)
  }

  func testCleanArticleOnlyChangeCanOpenConfirmationDirectly() {
    let snapshot = makeSnapshot()
    XCTAssertTrue(
      SingleArticlePublishFastPathPolicy.qualifies(
        snapshot, draftID: snapshot.publishPackage.draftID, profileID: snapshot.context.profileID
      ))
  }

  func testWarningsAndForeignFilesKeepTheDrawer() {
    var warning = makeSnapshot().remotePublishPreview
    warning.warningIssues = [.init(severity: .warning, title: "需要确认", message: "检查正文")]
    let warned = makeSnapshot(remotePreview: warning)
    XCTAssertFalse(
      SingleArticlePublishFastPathPolicy.qualifies(
        warned, draftID: warned.context.draftID, profileID: warned.context.profileID
      ))

    var foreign = makeSnapshot().remotePublishPreview
    foreign.changedPaths.append("config.toml")
    let broadened = makeSnapshot(remotePreview: foreign)
    XCTAssertFalse(
      SingleArticlePublishFastPathPolicy.qualifies(
        broadened, draftID: broadened.context.draftID, profileID: broadened.context.profileID
      ))
  }

  func testChangedDraftOrProfileCannotUsePreviousReview() {
    let snapshot = makeSnapshot()
    XCTAssertFalse(
      SingleArticlePublishFastPathPolicy.qualifies(
        snapshot, draftID: UUID(), profileID: snapshot.context.profileID
      ))
    XCTAssertFalse(
      SingleArticlePublishFastPathPolicy.qualifies(
        snapshot, draftID: snapshot.context.draftID, profileID: UUID()
      ))
  }

  func testLocalReadinessNeedsReviewKeepsTheDrawer() {
    let snapshot = makeSnapshot(localWriteReadiness: .needsReview)
    XCTAssertFalse(
      SingleArticlePublishFastPathPolicy.qualifies(
        snapshot, draftID: snapshot.context.draftID, profileID: snapshot.context.profileID
      ))
  }

  private func makeSnapshot(
    remotePreview: RemoteRepositoryPublishPreview? = nil,
    localWriteReadiness: LocalPublishActionReadiness = .ready,
    includesImage: Bool = true
  ) -> DraftPublishPreviewSnapshot {
    let draftID = UUID()
    let profileID = UUID()
    let package = PublishPackage(
      draftID: draftID,
      title: "Article",
      markdownPath: "content/article.md",
      files: [
        PublishPackageFile(kind: .markdown, repositoryPath: "content/article.md", content: "Body")
      ]
        + (includesImage
          ? [PublishPackageFile(kind: .image, repositoryPath: "static/article.png")] : []),
      commitMessage: "Publish article",
      reviewBranchName: "article-review",
      reviewTitle: "Article review",
      reviewChecklist: []
    )
    let preview =
      remotePreview
      ?? RemoteRepositoryPublishPreview(
        provider: .github,
        repositoryName: "owner/site",
        mode: .directCommit,
        branchName: "main",
        targetBranch: "main",
        changedPaths: ["content/article.md"],
        remoteRiskState: .clean,
        hasToken: true,
        accessCheck: RemoteRepositoryAccessCheck(
          provider: .github,
          repositoryName: "owner/site",
          defaultBranch: "main",
          canRead: true,
          canWrite: true,
          message: "Ready"
        ),
        blockingIssues: [],
        warningIssues: []
      )
    return DraftPublishPreviewSnapshot(
      context: DraftExecutionContext(draftID: draftID, profileID: profileID, bodyRevision: 0),
      publishPackage: package,
      localPublishPreview: LocalPublishPreview(package: package, fileDiffs: [], issues: []),
      localPublishReadiness: LocalPublishReadiness(
        writeReadiness: localWriteReadiness,
        commitReadiness: .ready,
        changedFileCount: 1,
        fileCount: package.files.count,
        writeBlockingIssues: [],
        commitBlockingIssues: [],
        warningIssues: []
      ),
      remotePublishPreview: preview,
      remoteReviewDraft: RemoteReviewDraft(
        provider: .github,
        branchName: "article-review",
        targetBranch: "main",
        title: "Article review",
        body: "Ready",
        webURL: nil
      )
    )
  }
}

@MainActor
final class PublishDrawerOperationControllerTests: XCTestCase {
  func testCompletionRestoresSectionOnlyWhileThePanelOwnsSharedNavigation() {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PublishDrawerOperationController-\(UUID().uuidString).json")
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: fileURL),
      safeMode: true
    )
    let controller = PublishDrawerOperationController()

    store.selectSection(.writing)
    let uninterrupted = controller.claimSharedNavigation(from: store.publishing)
    store.selectSection(.library)
    controller.restoreSharedSection(uninterrupted, using: store.publishing)
    XCTAssertEqual(store.publishing.selectedSection, .writing)

    // The panel is hidden mid-publish, the user navigates, then the panel is
    // shown again before the old operation finishes: its claim stays revoked.
    let interrupted = controller.claimSharedNavigation(from: store.publishing)
    controller.setOwnsSharedNavigation(false)
    store.selectSection(.library)
    controller.setOwnsSharedNavigation(true)
    controller.restoreSharedSection(interrupted, using: store.publishing)
    XCTAssertEqual(store.publishing.selectedSection, .library)

    // A claim made after the panel regained ownership restores normally.
    let fresh = controller.claimSharedNavigation(from: store.publishing)
    store.selectSection(.images)
    controller.restoreSharedSection(fresh, using: store.publishing)
    XCTAssertEqual(store.publishing.selectedSection, .library)

    // A claim taken while hidden never restores: not while hidden, and not
    // after the panel regains ownership.
    controller.setOwnsSharedNavigation(false)
    let whileHidden = controller.claimSharedNavigation(from: store.publishing)
    store.selectSection(.images)
    controller.restoreSharedSection(whileHidden, using: store.publishing)
    XCTAssertEqual(store.publishing.selectedSection, .images)
    controller.setOwnsSharedNavigation(true)
    controller.restoreSharedSection(whileHidden, using: store.publishing)
    XCTAssertEqual(store.publishing.selectedSection, .images)
  }
}
