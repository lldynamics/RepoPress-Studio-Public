import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class BatchPublishPerformanceTests: XCTestCase {
  func testSharedDuplicateIndexPreservesPreflightFindings() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/{slug}.md"
    let drafts = [
      ArticleDraft(siteProfileID: profile.id, title: "Shared", slug: "one", bodyMarkdown: "First"),
      ArticleDraft(siteProfileID: profile.id, title: "shared", slug: "two", bodyMarkdown: "Second"),
      ArticleDraft(siteProfileID: profile.id, title: "Different", slug: "one", bodyMarkdown: "Third"),
    ]
    let plan = BatchPublishPlanService().plan(drafts: drafts, profile: profile, repositoryReport: nil)
    for draft in drafts {
      let expected = PreflightCheckService().run(draft: draft, allDrafts: drafts, profile: profile)
      let actual = plan.items.first { $0.draftID == draft.id }!.preflightIssues
      // The plan also adds remote-risk and batch destination checks.
      for issue in expected {
        XCTAssertTrue(actual.contains { $0.title == issue.title && $0.message == issue.message })
      }
      for field in ["title", "slug"] {
        XCTAssertEqual(
          actual.filter { $0.field == field && $0.title.contains("重复") }.map(\.message),
          expected.filter { $0.field == field && $0.title.contains("重复") }.map(\.message)
        )
      }
    }
  }

  func testCancellationStopsBetweenDraftPhasesWithoutReturningPartialPlan() {
    let profile = SiteProfile.defaultProfile
    let drafts = (0..<20).map {
      ArticleDraft(siteProfileID: profile.id, title: "Article \($0)", slug: "article-\($0)")
    }
    var checkpoints = 0
    XCTAssertThrowsError(try BatchPublishPlanService().planCheckingCancellation(
      drafts: drafts, profile: profile, repositoryReport: nil,
      checkCancellation: {
        checkpoints += 1
        if checkpoints == 6 { throw CancellationError() }
      }
    )) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertEqual(checkpoints, 6)
  }

  func testAlreadyCancelledAsyncRequestCannotReturnPlan() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await BatchPublishPlanService().planCancellableAsync(
        drafts: [], profile: .defaultProfile, repositoryReport: nil
      )
    }
    do {
      _ = try await task.value
      XCTFail("Cancelled refresh returned a publishable plan")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }
}

@MainActor
final class BatchPublishRefreshLifecycleTests: XCTestCase {
  func testSameInputReusesRunningRefreshAndChangedInputReplacesIt() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let publishing = store.publishingStore
    publishing.scheduleBatchPublishPlanRefresh(store: store)
    let firstGeneration = publishing.batchPublishPlanRefreshGeneration
    publishing.scheduleBatchPublishPlanRefresh(store: store)
    XCTAssertEqual(publishing.batchPublishPlanRefreshGeneration, firstGeneration)

    var draft = try XCTUnwrap(store.selectedDraft)
    draft.bodyMarkdown += "\nChanged input"
    store.setDrafts([draft])
    publishing.scheduleBatchPublishPlanRefresh(store: store)
    XCTAssertGreaterThan(publishing.batchPublishPlanRefreshGeneration, firstGeneration)
    XCTAssertEqual(publishing.publishSession.batchPublishPlanRefreshInput?.drafts, store.visibleDrafts)
    publishing.cancelBatchPublishPlanRefresh()
    XCTAssertNil(publishing.publishSession.batchPublishPlanRefreshInput)
    XCTAssertNil(publishing.batchPublishPlanRefreshTask)
  }

  func testUnobservedRepositoryChangeInvalidatesPlanWithoutFlushingWriting() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let body = draft.bodyMarkdown + "\nStill typing"
    _ = store.stageDraftBody(body, for: draft.id, baseRevision: 0)
    store.publishingStore.batchPublishPlan = BatchPublishPlan(
      profileID: store.activeProfileID, siteName: store.activeProfile.name, items: []
    )

    store.invalidateBatchPublishPlanForRepositoryChange()

    XCTAssertNil(store.batchPublishPlan)
    XCTAssertNil(store.publishingStore.batchPublishPlanRefreshTask)
    XCTAssertEqual(store.drafts.first { $0.id == draft.id }?.bodyMarkdown, draft.bodyMarkdown)
    XCTAssertEqual(store.draftBodyEditorBuffer(for: draft.id).bodyMarkdown, body)
  }

  func testVisibleConsumersAreTrackedIndependentlyAcrossWindows() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let first = UUID(), second = UUID()
    store.setBatchPublishPlanConsumer(first, isActive: true)
    store.setBatchPublishPlanConsumer(second, isActive: true)
    store.setBatchPublishPlanConsumer(first, isActive: false)
    store.invalidateBatchPublishPlanForRepositoryChange()
    XCTAssertNotNil(store.publishingStore.batchPublishPlanRefreshTask)
    store.setBatchPublishPlanConsumer(second, isActive: false)
    XCTAssertNil(store.publishingStore.batchPublishPlanRefreshTask)
    XCTAssertNil(store.batchPublishPlan)
    store.invalidateBatchPublishPlanForRepositoryChange()
    XCTAssertNil(store.publishingStore.batchPublishPlanRefreshTask)
  }
}
