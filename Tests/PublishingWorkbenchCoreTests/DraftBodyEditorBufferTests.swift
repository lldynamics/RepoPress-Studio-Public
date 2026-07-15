import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class DraftBodyEditorBufferTests: XCTestCase {
  func testStaleEditorMetadataIsRejectedInsteadOfOverwritingNewerWindow() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let original = try XCTUnwrap(store.selectedDraft)
    var firstWindow = original
    var staleWindow = original

    firstWindow.title = "主窗口的新标题"
    XCTAssertTrue(store.updateDraftFromEditor(firstWindow))

    staleWindow.summary = "独立窗口的陈旧摘要"
    XCTAssertFalse(store.updateDraftFromEditor(staleWindow))

    let current = try XCTUnwrap(store.drafts.first(where: { $0.id == original.id }))
    XCTAssertEqual(current.title, "主窗口的新标题")
    XCTAssertEqual(current.summary, original.summary)
    XCTAssertTrue(store.publishActionMessage?.contains("陈旧元数据未写入") == true)
    XCTAssertTrue(store.lastSaveStatus.contains("编辑冲突"))
  }

  func testRefreshedEditorMetadataCanSaveAfterConflict() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let original = try XCTUnwrap(store.selectedDraft)
    var firstWindow = original
    var staleWindow = original
    firstWindow.title = "另一窗口的新标题"
    XCTAssertTrue(store.updateDraftFromEditor(firstWindow))
    staleWindow.summary = "第一次尝试"
    XCTAssertFalse(store.updateDraftFromEditor(staleWindow))

    var refreshed = try XCTUnwrap(store.drafts.first(where: { $0.id == original.id }))
    refreshed.summary = "同步后的摘要"
    XCTAssertTrue(store.updateDraftFromEditor(refreshed))

    let current = try XCTUnwrap(store.drafts.first(where: { $0.id == original.id }))
    XCTAssertEqual(current.title, "另一窗口的新标题")
    XCTAssertEqual(current.summary, "同步后的摘要")
  }

  func testImmediateSaveFlushesStagedBody() async throws {
    let persistenceURL = try temporaryPersistenceURL(prefix: "DraftBodyBufferSave")
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    let draft = try XCTUnwrap(store.selectedDraft)
    let stagedBody = "正文在输入后立刻保存，不应丢失。"

    let result = try XCTUnwrap(
      store.stageDraftBody(stagedBody, for: draft.id, baseRevision: 0)
    )
    XCTAssertTrue(result.wasAccepted)
    XCTAssertTrue(result.buffer.isDirty)

    store.save()
    await store.waitForPendingSave()

    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    XCTAssertEqual(reloaded.drafts.first(where: { $0.id == draft.id })?.bodyMarkdown, stagedBody)
  }

  func testImmediatePublishPackageFlushesStagedBody() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let stagedBody = "正文在打开发布流程前必须进入发布包。"

    _ = store.stageDraftBody(stagedBody, for: draft.id, baseRevision: 0)
    let package = store.publishingPackage(for: draft)

    XCTAssertTrue(package.markdownFile?.content?.contains(stagedBody) == true)
    XCTAssertEqual(store.drafts.first(where: { $0.id == draft.id })?.bodyMarkdown, stagedBody)
  }

  func testImmediatePreflightFlushesStagedBody() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let stagedBody = "正文在运行检查前必须先进入 Store。"

    _ = store.stageDraftBody(stagedBody, for: draft.id, baseRevision: 0)
    store.runPreflight()

    XCTAssertEqual(store.drafts.first(where: { $0.id == draft.id })?.bodyMarkdown, stagedBody)
  }

  func testStaleWindowBodyIsRejectedInsteadOfOverwritingNewerBuffer() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let draft = try XCTUnwrap(store.selectedDraft)

    let first = try XCTUnwrap(
      store.stageDraftBody("来自主窗口的正文", for: draft.id, baseRevision: 0)
    )
    let stale = try XCTUnwrap(
      store.stageDraftBody("来自独立窗口的陈旧正文", for: draft.id, baseRevision: 0)
    )

    XCTAssertTrue(first.wasAccepted)
    XCTAssertFalse(stale.wasAccepted)
    XCTAssertEqual(stale.buffer.revision, first.buffer.revision)
    XCTAssertEqual(stale.buffer.bodyMarkdown, "来自主窗口的正文")
    XCTAssertEqual(store.draftBodyEditorBuffer(for: draft.id).bodyMarkdown, "来自主窗口的正文")
  }

  func testStaleRevisionRebasesWhenDisplayedBaseBodyIsStillCurrent() throws {
    let store = try TestWorkbenchFactory.makeStore()
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.bodyMarkdown = "同步后的正文"
    store.updateDraft(draft)

    let result = try XCTUnwrap(
      store.stageDraftBody(
        "同步后的正文，继续输入。",
        for: draft.id,
        baseRevision: 0,
        replacingBaseBody: "同步后的正文"
      )
    )

    XCTAssertTrue(result.wasAccepted)
    XCTAssertEqual(result.buffer.revision, 2)
    XCTAssertEqual(result.buffer.bodyMarkdown, "同步后的正文，继续输入。")
  }

  func testStaleRevisionStillRejectsWhenDisplayedBaseBodyIsNoLongerCurrent() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let first = try XCTUnwrap(
      store.stageDraftBody("另一窗口的新正文", for: draft.id, baseRevision: 0)
    )

    let stale = try XCTUnwrap(
      store.stageDraftBody(
        "陈旧窗口继续输入",
        for: draft.id,
        baseRevision: 0,
        replacingBaseBody: draft.bodyMarkdown
      )
    )

    XCTAssertTrue(first.wasAccepted)
    XCTAssertFalse(stale.wasAccepted)
    XCTAssertEqual(stale.buffer.bodyMarkdown, "另一窗口的新正文")
    XCTAssertEqual(stale.buffer.revision, first.buffer.revision)
  }

  func testStaleEditorCommandIsRejectedInsteadOfReplacingNewerBuffer() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let draft = try XCTUnwrap(store.selectedDraft)

    let first = try XCTUnwrap(
      store.stageDraftBody("来自主窗口的正文", for: draft.id, baseRevision: 0)
    )
    let staleCommand = try XCTUnwrap(
      store.replaceDraftBody(
        "来自陈旧窗口的格式化正文",
        for: draft.id,
        expectedRevision: 0
      )
    )

    XCTAssertTrue(first.wasAccepted)
    XCTAssertFalse(staleCommand.wasAccepted)
    XCTAssertEqual(staleCommand.buffer.revision, first.buffer.revision)
    XCTAssertEqual(staleCommand.buffer.bodyMarkdown, "来自主窗口的正文")
  }

  func testExternalBodyUpdateAdvancesBufferRevisionForOpenEditors() throws {
    let store = try TestWorkbenchFactory.makeStore()
    var draft = try XCTUnwrap(store.selectedDraft)
    _ = store.draftBodyEditorBuffer(for: draft.id)

    draft.bodyMarkdown = "来自 AI 或 Inspector 的新正文"
    store.updateDraft(draft)

    let buffer = store.draftBodyEditorBuffer(for: draft.id)
    XCTAssertEqual(buffer.bodyMarkdown, draft.bodyMarkdown)
    XCTAssertEqual(buffer.revision, 1)
    XCTAssertFalse(buffer.isDirty)
  }

  func testDraftOperationBaselineDetectsMetadataChanges() throws {
    let store = try TestWorkbenchFactory.makeStore()
    var draft = try XCTUnwrap(store.selectedDraft)
    let baseline = try XCTUnwrap(store.draftOperationBaseline(for: draft.id))

    XCTAssertTrue(store.draftStillMatchesOperationBaseline(baseline))
    draft.title = "处理中修改后的标题"
    store.updateDraft(draft)

    XCTAssertFalse(store.draftStillMatchesOperationBaseline(baseline))
  }

  func testDraftOperationBaselineDetectsUnflushedBodyChanges() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let baseline = try XCTUnwrap(store.draftOperationBaseline(for: draft.id))

    _ = store.stageDraftBody(
      "图片或导入任务运行期间的新正文",
      for: draft.id,
      baseRevision: baseline.bodyRevision
    )

    XCTAssertFalse(store.draftStillMatchesOperationBaseline(baseline))
  }

  func testFlushPendingChangesIncludesStagedBodyForExitSnapshot() throws {
    let persistenceURL = try temporaryPersistenceURL(prefix: "DraftBodyBufferExit")
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    let draft = try XCTUnwrap(store.selectedDraft)
    let stagedBody = "退出前的最后一段正文。"

    _ = store.stageDraftBody(stagedBody, for: draft.id, baseRevision: 0)

    XCTAssertTrue(store.flushPendingChanges())

    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    XCTAssertEqual(reloaded.drafts.first(where: { $0.id == draft.id })?.bodyMarkdown, stagedBody)
  }
}
