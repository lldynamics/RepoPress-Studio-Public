import Combine
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class StoreHotPathPerformanceTests: XCTestCase {
  func testTaskQueueAuditCacheMissSchedulesBeforePublishingSnapshot() async throws {
    let store = makeStore()
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Link audit",
      slug: "link-audit",
      bodyMarkdown: "[missing](/missing-page/)"
    )
    store.setDrafts([draft])

    let replacementCount = store.siteLinkAuditSnapshotStore.replacementCount
    let firstStates = store.draftTaskQueueStates(for: [draft])

    XCTAssertFalse(firstStates[draft.id]?.hasPreflightErrors == true)
    XCTAssertNotNil(store.siteLinkAuditRefreshTask)
    XCTAssertEqual(store.siteLinkAuditSnapshotStore.replacementCount, replacementCount)

    _ = await store.siteLinkAuditRefreshTask?.value

    XCTAssertGreaterThan(store.siteLinkAuditSnapshotStore.replacementCount, replacementCount)
    XCTAssertGreaterThan(store.draftTaskQueueStateVersion, 0)
  }

  func testImageBatchDraftTransactionPublishesDraftsOnceAndEmptyInputPublishesNothing() {
    let store = makeStore()
    let first = ArticleDraft(siteProfileID: store.activeProfileID, title: "First", slug: "first")
    let second = ArticleDraft(siteProfileID: store.activeProfileID, title: "Second", slug: "second")
    store.setDrafts([first, second])
    store.setSelectedDraftID(first.id)
    #if DEBUG
      let initialSaveInvocationCount = store.saveInvocationCount
    #endif

    var publicationCount = 0
    let subscription = store.publishingStore.$drafts
      .dropFirst()
      .sink { _ in publicationCount += 1 }
    defer { subscription.cancel() }

    XCTAssertFalse(store.applyImageBatchDraftUpdates([:]))
    XCTAssertEqual(publicationCount, 0)
    #if DEBUG
      XCTAssertEqual(store.saveInvocationCount, initialSaveInvocationCount)
    #endif

    var updatedFirst = first
    updatedFirst.summary = "updated"
    var updatedSecond = second
    updatedSecond.summary = "updated"
    XCTAssertTrue(
      store.applyImageBatchDraftUpdates([
        first.id: updatedFirst,
        second.id: updatedSecond,
      ]))

    XCTAssertEqual(publicationCount, 1)
    XCTAssertEqual(store.preflightRefreshGeneration, 1)
    #if DEBUG
      XCTAssertEqual(store.saveInvocationCount, initialSaveInvocationCount + 1)
    #endif
  }

  #if DEBUG
    func testRemoteSHABackfillDropsResultAfterCleanupRequestAndProfileDrift() async throws {
      let store = makeStore()
      let draft = ArticleDraft(
        siteProfileID: store.activeProfileID,
        title: "Remote baseline",
        slug: "remote-baseline",
        repositoryPath: "content/posts/remote-baseline.md"
      )
      let gate = SnapshotGate()
      let backfillCompleted = expectation(description: "remote SHA backfill completed")
      store.publishingStore.remoteSHABackfillCompletionTestHook = { _ in
        backfillCompleted.fulfill()
      }
      store.repositoryStore.remoteFileSnapshotTestHook = {
        await gate.waitUntilReleased()
      }
      store.repositoryStore.remoteFileSnapshotTestOverride = {
        RepositoryFileSnapshot(
          refName: "origin/main",
          repositoryPath: "content/posts/remote-baseline.md",
          content: "remote",
          repositorySHA: "remote-sha"
        )
      }
      defer {
        store.publishingStore.remoteSHABackfillCompletionTestHook = nil
        store.repositoryStore.remoteFileSnapshotTestHook = nil
        store.repositoryStore.remoteFileSnapshotTestOverride = nil
      }

      store.setDrafts([draft])
      store.setSelectedDraftID(draft.id)
      store.deleteDraft(id: draft.id)
      var didEnterGate = false
      for _ in 0..<100 {
        if await gate.hasEntered {
          didEnterGate = true
          break
        }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      XCTAssertTrue(didEnterGate)

      store.publishingStore.draftRepositoryCleanupRequests[0].repositoryPath =
        "content/posts/other.md"
      var changedProfile = store.activeProfile
      changedProfile.markdownPathPattern = "content/changed/{slug}.md"
      store.updateActiveProfile(changedProfile)
      await gate.release()
      await fulfillment(of: [backfillCompleted], timeout: 1)

      XCTAssertNil(store.publishingStore.draftRepositoryCleanupRequests[0].expectedRemoteSHA)
    }
  #endif

  private func makeStore() -> WorkbenchStore {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("store-hot-path-\(UUID().uuidString).json")
    return WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL), safeMode: true)
  }
}

#if DEBUG
  private actor SnapshotGate {
    private(set) var hasEntered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
      hasEntered = true
      await withCheckedContinuation { continuation = $0 }
    }

    func release() {
      continuation?.resume()
      continuation = nil
    }
  }
#endif
