import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class DraftSelectionPerformanceRegressionTests: XCTestCase {
  func testSelectionDoesNotInvalidateGlobalDraftListOrImageCaches() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    if store.drafts.count < 2 {
      store.createDraft()
    }
    let drafts = store.drafts
    guard drafts.count >= 2 else {
      XCTFail("测试夹具至少需要两篇草稿才能验证切换")
      return
    }

    let initialPresentationRevision = store.draftListPresentationRevision
    let initialImageInputRevision = store.imageWorkbenchInputRevision
    store.selectDraft(drafts[1].id)

    XCTAssertEqual(store.draftListPresentationRevision, initialPresentationRevision)
    XCTAssertEqual(store.imageWorkbenchInputRevision, initialImageInputRevision)
    XCTAssertEqual(store.selectedDraftID, drafts[1].id)
  }

  func testSelectionFlushesOnlyTheDraftLeavingTheEditor() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    if store.drafts.count < 2 {
      store.createDraft()
    }
    let drafts = store.drafts
    guard drafts.count >= 2 else {
      XCTFail("测试夹具至少需要两篇草稿才能验证切换")
      return
    }

    let first = drafts[0]
    let second = drafts[1]
    store.selectDraft(first.id)
    let firstBuffer = try XCTUnwrap(
      store.stageDraftBody(
        "切换前保存",
        for: first.id,
        baseRevision: store.draftBodyEditorBuffer(for: first.id).revision
      )
    )
    _ = try XCTUnwrap(
      store.stageDraftBody(
        "另一个窗口的编辑",
        for: second.id,
        baseRevision: store.draftBodyEditorBuffer(for: second.id).revision
      )
    )

    store.selectDraft(second.id)

    XCTAssertFalse(store.draftBodyEditorBuffer(for: first.id).isDirty)
    XCTAssertEqual(store.draftBodyEditorBuffer(for: first.id).bodyMarkdown, "切换前保存")
    XCTAssertTrue(store.draftBodyEditorBuffer(for: second.id).isDirty)
    XCTAssertEqual(
      store.draftBodyEditorBuffer(for: second.id).bodyMarkdown,
      "另一个窗口的编辑"
    )
    XCTAssertGreaterThan(firstBuffer.buffer.revision, 0)
  }

  func testPerDraftImageRefreshDoesNotInvalidateEveryTaskQueueState() async throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    let draft = try XCTUnwrap(store.selectedDraft ?? store.writingDrafts.first)
    store.setSelectedDraftID(draft.id)
    let initialVersion = store.draftTaskQueueStateVersion

    await store.refreshImageWorkbenchReportInBackground(for: draft, force: true)

    XCTAssertEqual(store.draftTaskQueueStateVersion, initialVersion)
    XCTAssertNotNil(store.cachedImageWorkbenchReport(for: draft))
  }
}
