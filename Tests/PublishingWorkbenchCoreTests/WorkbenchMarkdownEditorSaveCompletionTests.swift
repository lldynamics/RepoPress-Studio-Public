import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchMarkdownEditorSaveCompletionTests: XCTestCase {
  private func makeStore() -> WorkbenchStore {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("editor-save-completion-\(UUID().uuidString).json")
    return WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
  }

  private func makeSiteDraft(in store: WorkbenchStore, title: String) -> ArticleDraft {
    var draft = ArticleDraft.empty(profile: store.activeProfile)
    draft.title = title
    draft.repositoryPath = "content/posts/\(draft.id.uuidString).md"
    return draft
  }

  func testInitialStateDoesNotEmitACompletionEvent() {
    let store = makeStore()
    let draft = makeSiteDraft(in: store, title: "初始状态")
    store.setDrafts([draft])

    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: draft.id
    )

    XCTAssertEqual(facade.saveCompletionRevision, 0)
  }

  func testTrackedSiteDraftPendingToSavedEmitsExactlyOneCompletionEvent() {
    let store = makeStore()
    let draft = makeSiteDraft(in: store, title: "项目草稿")
    store.setDrafts([draft])
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: draft.id
    )

    store.siteDraftFileSaveStates[draft.id] = .pending(repositoryPath: "content/posts/test.md")
    store.siteDraftFileSaveStates[draft.id] = .saved(
      repositoryPath: "content/posts/test.md",
      savedAt: Date()
    )
    XCTAssertEqual(facade.saveCompletionRevision, 1)

    store.siteDraftFileSaveStates[draft.id] = .saved(
      repositoryPath: "content/posts/test.md",
      savedAt: Date().addingTimeInterval(1)
    )
    XCTAssertEqual(facade.saveCompletionRevision, 1)
  }

  func testTrackedSiteDraftPendingToFailureDoesNotEmitACompletionEvent() {
    let store = makeStore()
    let draft = makeSiteDraft(in: store, title: "失败草稿")
    store.setDrafts([draft])
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: draft.id
    )

    store.siteDraftFileSaveStates[draft.id] = .pending(repositoryPath: "content/posts/failure.md")
    store.siteDraftFileSaveStates[draft.id] = .failed(
      repositoryPath: "content/posts/failure.md",
      message: "写入失败"
    )

    XCTAssertEqual(facade.saveCompletionRevision, 0)
  }

  func testUnrelatedSiteDraftTransitionsDoNotEmitACompletionEvent() {
    let store = makeStore()
    let trackedDraft = makeSiteDraft(in: store, title: "当前草稿")
    let otherDraft = makeSiteDraft(in: store, title: "其他草稿")
    store.setDrafts([trackedDraft, otherDraft])
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: trackedDraft.id
    )

    store.siteDraftFileSaveStates[otherDraft.id] = .pending(
      repositoryPath: "content/posts/other.md")
    store.siteDraftFileSaveStates[otherDraft.id] = .saved(
      repositoryPath: "content/posts/other.md",
      savedAt: Date()
    )

    XCTAssertEqual(facade.saveCompletionRevision, 0)
  }

  func testGlobalPersistenceSuccessDoesNotEmitForASiteDraft() {
    let store = makeStore()
    let draft = makeSiteDraft(in: store, title: "项目草稿")
    store.setDrafts([draft])
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: draft.id
    )

    store.persistenceStore.markUnsavedChanges()
    store.persistenceStore.recordSuccess()

    XCTAssertEqual(facade.saveCompletionRevision, 0)
  }

  func testTrackingACleanDraftResetsTheSaveBaselineWithoutAnEvent() {
    let store = makeStore()
    let dirtyDraft = makeSiteDraft(in: store, title: "正在保存")
    let cleanDraft = makeSiteDraft(in: store, title: "已保存")
    store.setDrafts([dirtyDraft, cleanDraft])
    store.siteDraftFileSaveStates[dirtyDraft.id] = .pending(
      repositoryPath: "content/posts/dirty.md")
    store.siteDraftFileSaveStates[cleanDraft.id] = .saved(
      repositoryPath: "content/posts/clean.md",
      savedAt: Date()
    )
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: dirtyDraft.id
    )

    facade.trackDraft(cleanDraft.id)

    XCTAssertEqual(facade.saveCompletionRevision, 0)
  }

  func testGeneralDraftGlobalPendingToSavedEmitsOneCompletionEvent() {
    let store = makeStore()
    let draft = ArticleDraft.emptyGeneralDraft(editingProfile: store.activeProfile)
    store.setDrafts([draft])
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: draft.id
    )

    store.persistenceStore.markUnsavedChanges()
    store.persistenceStore.recordSuccess()

    XCTAssertEqual(facade.saveCompletionRevision, 1)
  }
}
