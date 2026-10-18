import Combine
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

@MainActor
final class WorkspacePublishSessionTests: XCTestCase {
  func testReviewIsDeliveredAndDiscardingItReturnsToIdle() async {
    let session = WorkspacePublishSession()
    let context = context(draftID: UUID())
    var discarded = 0
    XCTAssertTrue(
      session.prepare(
        .article(context.draftID!), context: context, currentContext: { context },
        operation: { .review(self.review(.article(context.draftID!))) },
        onDiscard: { discarded += 1 }))
    XCTAssertTrue(session.isBusy)
    await session.waitUntilIdle()
    XCTAssertNotNil(session.pendingReview)
    XCTAssertTrue(session.presentsSheet)
    XCTAssertEqual(discarded, 0, "A delivered review keeps its temporary draft change")
    XCTAssertFalse(session.isBusy)
  }

  func testBlockersAndOutcomesUndoTemporaryChanges() async {
    let session = WorkspacePublishSession()
    let draftID = UUID()
    let context = context(draftID: draftID)
    var discarded = 0
    session.prepare(
      .article(draftID), context: context, currentContext: { context },
      operation: {
        .blockers(.init(draftID: draftID, title: "Article", issues: []))
      },
      onDiscard: { discarded += 1 })
    await session.waitUntilIdle()
    XCTAssertNotNil(session.pendingBlockers)
    XCTAssertEqual(discarded, 1)

    session.pendingBlockers = nil
    session.prepare(
      .all, context: context, currentContext: { context },
      operation: {
        .outcome(
          .init(message: "Nothing", status: .information, recordID: nil, offersPushRetry: false))
      },
      onDiscard: { discarded += 1 })
    await session.waitUntilIdle()
    XCTAssertEqual(session.outcome?.message, "Nothing")
    XCTAssertEqual(discarded, 2)
  }

  func testSwitchingArticleDiscardsArticlePreparationButNotSiteWidePreparation() async {
    let draftID = UUID()
    let window = WorkspaceWindowSession(
      windowID: UUID(), selectedSection: .writing, selectedDraftID: draftID)
    let profiles = CurrentValueSubject<UUID, Never>(UUID())
    let session = WorkspacePublishSession()
    session.observeWindow(window, profileChanges: profiles.eraseToAnyPublisher())
    let articleContext = WorkspacePublishSession.Context(
      windowID: window.windowID, profileID: profiles.value, draftID: draftID)
    let currentArticle: @MainActor () -> WorkspacePublishSession.Context? = {
      guard window.selectedDraftID == draftID else { return nil }
      return articleContext
    }
    let gate = SuspendedOperation()
    var discarded = 0
    session.prepare(
      .article(draftID), context: articleContext, currentContext: currentArticle,
      operation: {
        await gate.run()
        return .review(self.review(.article(draftID)))
      },
      onDiscard: { discarded += 1 })
    await gate.waitUntilStarted()
    window.selectDraft(UUID()) { _ in }
    XCTAssertFalse(session.isBusy)
    gate.resume()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertNil(session.pendingReview)
    XCTAssertEqual(discarded, 1)

    let siteContext = WorkspacePublishSession.Context(
      windowID: window.windowID, profileID: profiles.value, draftID: nil)
    let siteGate = SuspendedOperation()
    session.prepare(
      .all, context: siteContext, currentContext: { siteContext },
      operation: {
        await siteGate.run()
        return .review(self.review(.all))
      })
    await siteGate.waitUntilStarted()
    window.selectDraft(UUID()) { _ in }
    XCTAssertTrue(session.isBusy, "Publishing everything does not depend on the shown article")
    siteGate.resume()
    await session.waitUntilIdle()
    XCTAssertEqual(session.pendingReview?.target, .all)
  }

  func testSiteSwitchCancelsPreparationAndAllowsANewOne() async {
    let window = WorkspaceWindowSession(windowID: UUID(), selectedSection: .writing)
    let profiles = CurrentValueSubject<UUID, Never>(UUID())
    let session = WorkspacePublishSession()
    session.observeWindow(window, profileChanges: profiles.eraseToAnyPublisher())
    let initialProfile = profiles.value
    let current: @MainActor () -> WorkspacePublishSession.Context? = {
      .init(windowID: window.windowID, profileID: profiles.value, draftID: nil)
    }
    let context = current()!
    let old = SuspendedOperation()
    var deliveries = 0
    session.prepare(
      .all, context: context, currentContext: current,
      operation: {
        await old.run()
        deliveries += 1
        return .review(self.review(.all))
      })
    await old.waitUntilStarted()
    profiles.send(UUID())
    profiles.send(initialProfile)
    XCTAssertFalse(session.isBusy)
    XCTAssertTrue(
      session.prepare(
        .all, context: context, currentContext: current,
        operation: { .review(self.review(.all)) }))
    await session.waitUntilIdle()
    old.resume()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertNotNil(session.pendingReview)
    XCTAssertEqual(deliveries, 1, "The old operation finished but could not replace the new review")
  }

  func testConfirmedPublishFinishesAndReportsEvenAfterCancel() async throws {
    let session = WorkspacePublishSession()
    let context = context(draftID: nil)
    session.prepare(
      .all, context: context, currentContext: { context },
      operation: { .review(self.review(.all)) })
    await session.waitUntilIdle()
    let review = try XCTUnwrap(session.pendingReview)
    let gate = SuspendedOperation()
    XCTAssertTrue(
      session.publish(review: review) {
        await gate.run()
        return .init(message: "Pushed", status: .success, recordID: UUID(), offersPushRetry: false)
      })
    await gate.waitUntilStarted()
    XCTAssertTrue(session.isPublishing)
    session.cancel()
    XCTAssertTrue(session.isPublishing, "A running commit and push is never interrupted")
    XCTAssertNotNil(session.pendingReview)
    gate.resume()
    await session.waitUntilIdle()
    XCTAssertNil(session.pendingReview)
    XCTAssertEqual(session.outcome?.message, "Pushed")
    XCTAssertTrue(session.presentsSheet)
  }

  func testCancellationBeforeSchedulingDoesNotStartPreparationOrRepair() async {
    let session = WorkspacePublishSession()
    let context = context(draftID: nil)
    let repairID = UUID()
    var operations = 0
    XCTAssertTrue(
      session.prepare(
        .all, context: context, currentContext: { context },
        operation: {
          operations += 1
          return .review(self.review(.all))
        }))
    XCTAssertTrue(
      session.refreshChecks(
        context: context, repairID: repairID, currentContext: { context },
        currentRepairID: { repairID },
        operation: { operations += 1 }, onResult: { XCTFail("Cancelled repair") }))
    session.cancel()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(operations, 0)
    XCTAssertFalse(session.isBusy)
    XCTAssertFalse(session.isRefreshingChecks)
  }

  private func context(draftID: UUID?) -> WorkspacePublishSession.Context {
    .init(windowID: UUID(), profileID: UUID(), draftID: draftID)
  }

  private func review(_ target: WorkspacePublishSession.Target) -> WorkspacePublishSession.Review {
    let snapshot = RepositoryWorktreePublishSnapshot(
      repositoryRoot: "/tmp/site", gitCommonDirectory: "/tmp/site/.git", branch: "main",
      headSHA: "a", originURL: "origin", remoteBranchSHA: "a", statusFingerprint: "",
      entries: [RepositoryWorktreePublishEntry(kind: .modified, status: " M", path: "a.md")])
    return .init(
      target: target, title: "Title",
      confirmation: RepositoryWorktreePublishConfirmation(
        snapshot: snapshot, commitMessage: "Publish",
        pathScope: target == .all ? nil : ["a.md"]),
      clearedDraftFlag: false)
  }
}

/// Finishes only when resumed, even if its caller was cancelled, like a late
/// Git or provider callback.
@MainActor
private final class SuspendedOperation {
  private var continuation: CheckedContinuation<Void, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var started = false

  func run() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      started = true
      for waiter in startWaiters { waiter.resume() }
      startWaiters.removeAll()
    }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}
