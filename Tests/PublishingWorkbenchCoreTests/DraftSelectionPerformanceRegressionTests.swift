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

  func testWindowContextActivationAlignsScopeWithoutFlushingTargetBuffer() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    let siteDraft = try XCTUnwrap(store.drafts.first)
    let generalDraft = ArticleDraft.emptyGeneralDraft(editingProfile: store.activeProfile)
    store.setDrafts([siteDraft, generalDraft])
    store.selectDraft(siteDraft.id)

    _ = try XCTUnwrap(
      store.stageDraftBody(
        "站点草稿离开窗口前提交",
        for: siteDraft.id,
        baseRevision: store.draftBodyEditorBuffer(for: siteDraft.id).revision
      )
    )
    _ = try XCTUnwrap(
      store.stageDraftBody(
        "通用草稿仍由另一个窗口暂存",
        for: generalDraft.id,
        baseRevision: store.draftBodyEditorBuffer(for: generalDraft.id).revision
      )
    )

    let activatedDraftID = store.activateDraftSelectionContext(generalDraft.id)

    XCTAssertEqual(activatedDraftID, generalDraft.id)
    XCTAssertEqual(store.selectedDraftID, generalDraft.id)
    XCTAssertEqual(store.draftListContentScope, .general)
    XCTAssertFalse(store.draftBodyEditorBuffer(for: siteDraft.id).isDirty)
    XCTAssertTrue(store.draftBodyEditorBuffer(for: generalDraft.id).isDirty)
    XCTAssertEqual(
      store.draftBodyEditorBuffer(for: generalDraft.id).bodyMarkdown,
      "通用草稿仍由另一个窗口暂存"
    )
  }

  func testWindowContextActivationFallsBackWhenRememberedDraftWasDeleted() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    let retainedDraft = try XCTUnwrap(store.drafts.first)

    let activatedDraftID = store.activateDraftSelectionContext(UUID())

    XCTAssertEqual(activatedDraftID, retainedDraft.id)
    XCTAssertEqual(store.selectedDraftID, retainedDraft.id)
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
