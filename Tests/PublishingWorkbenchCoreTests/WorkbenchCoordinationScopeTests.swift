import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchCoordinationScopeTests: XCTestCase {
  func testSafeSyncRejectsNestedMutationAndReleasesAfterEarlyReturn() async {
    let fixture = TestWorkbenchFixture()
    let store = fixture.store
    let repository = store.repositoryStore
    let result: Int? = await repository.withRepositorySafeSyncOperation(
      store: store, unavailable: { nil }
    ) { context in
      XCTAssertTrue(store.isLocalRepositoryMutationRunning)
      XCTAssertTrue(repository.repositorySafeSyncOperationIsCurrent(context, store: store))
      let nested: Int? = await repository.withRepositorySafeSyncOperation(
        store: store, unavailable: { nil }
      ) { _ in
        XCTFail("A concurrent mutation must not enter")
        return 1
      }
      XCTAssertNil(nested)
      XCTAssertTrue(store.isLocalRepositoryMutationRunning)
      return nil
    }
    XCTAssertNil(result)
    XCTAssertFalse(store.isLocalRepositoryMutationRunning)
    XCTAssertFalse(repository.isLocalRepositoryBranchOperationRunning)
  }

  func testSafeSyncReleasesAfterErrorAndAllowsNextOperation() async throws {
    enum Failure: Error { case expected }
    let fixture = TestWorkbenchFixture()
    let store = fixture.store
    do {
      let _: Bool = try await store.repositoryStore.withRepositorySafeSyncOperation(
        store: store, unavailable: { false }
      ) { _ in
        throw Failure.expected
      }
      XCTFail("Expected the operation error")
    } catch Failure.expected {}
    XCTAssertFalse(store.isLocalRepositoryMutationRunning)
    let result = await store.repositoryStore.withRepositorySafeSyncOperation(
      store: store, unavailable: { false }
    ) { _ in true }
    XCTAssertTrue(result)
    XCTAssertFalse(store.isLocalRepositoryMutationRunning)
  }

  func testSafeSyncCancellationReleasesLocks() async {
    let fixture = TestWorkbenchFixture()
    let store = fixture.store
    let task = Task { @MainActor in
      await store.repositoryStore.withRepositorySafeSyncOperation(
        store: store, unavailable: { false }
      ) { _ in
        withUnsafeCurrentTask { $0?.cancel() }
        XCTAssertTrue(Task.isCancelled)
        return false
      }
    }
    let result = await task.value
    XCTAssertFalse(result)
    XCTAssertFalse(store.isLocalRepositoryMutationRunning)
  }

  func testDraftImpactKeepsBodyAndImagesOutsideSidebarMetadata() {
    let original = ArticleDraft(siteProfileID: UUID(), title: "Original", slug: "original", bodyMarkdown: "Body")
    var updated = original
    updated.bodyMarkdown += " more words"
    XCTAssertEqual(
      DraftChangeImpact(previous: original, updated: updated), .body(imageReferencesChanged: false))
    updated.bodyMarkdown += " ![Cover](/images/cover.png)"
    XCTAssertEqual(
      DraftChangeImpact(previous: original, updated: updated), .body(imageReferencesChanged: true))
    updated.title = "Renamed"
    XCTAssertEqual(DraftChangeImpact(previous: original, updated: updated), .listMetadata)
    updated = original
    updated.aliases = ["/previous/"]
    XCTAssertEqual(DraftChangeImpact(previous: original, updated: updated), .editorMetadata)
  }
}
