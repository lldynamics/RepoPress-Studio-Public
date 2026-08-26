import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class DraftBodyEditorBufferTests: XCTestCase {
  func testArticleDraftWordCountPersistsAndLegacySnapshotDefaultsToDirty() throws {
    var draft = ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "兼容性",
      bodyMarkdown: "已统计正文"
    )
    XCTAssertTrue(draft.storeWordCount(6, for: draft.bodyMarkdown))

    let encoded = try JSONEncoder().encode(draft)
    let decoded = try JSONDecoder().decode(ArticleDraft.self, from: encoded)
    XCTAssertEqual(decoded.wordCount, 6)
    XCTAssertFalse(decoded.wordCountNeedsRefresh)

    var legacyObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    legacyObject.removeValue(forKey: "wordCountStorage")
    legacyObject.removeValue(forKey: "wordCountNeedsRefreshStorage")
    legacyObject.removeValue(forKey: "metadataUpdatedAtStorage")
    legacyObject.removeValue(forKey: "editorMetadataRevisionStorage")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    let legacy = try JSONDecoder().decode(ArticleDraft.self, from: legacyData)
    XCTAssertEqual(legacy.wordCount, 0)
    XCTAssertTrue(legacy.wordCountNeedsRefresh)
    XCTAssertEqual(legacy.metadataUpdatedAt, legacy.updatedAt)
    XCTAssertEqual(legacy.editorMetadataRevision, 0)
  }

  func testBodyOnlyUpdateMovesContentTimestampButFreezesMetadataTimestamp() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let original = try XCTUnwrap(store.selectedDraft)
    let originalMetadataUpdatedAt = original.metadataUpdatedAt
    let initialDraftListRevision = store.draftList.presentationRevision
    let originalEditorMetadataRevision = original.editorMetadataRevision

    var bodyEdit = original
    bodyEdit.bodyMarkdown = "只改变正文"
    // Some body-producing services historically advanced `updatedAt` before
    // handing the value to the store. That must not be misclassified as list
    // metadata when decoding a legacy draft without a stored metadata clock.
    bodyEdit.updatedAt = original.updatedAt.addingTimeInterval(60)
    store.updateDraft(bodyEdit)

    let bodyUpdated = try XCTUnwrap(store.draft(for: original.id))
    XCTAssertNotEqual(bodyUpdated.updatedAt, original.updatedAt)
    XCTAssertEqual(bodyUpdated.metadataUpdatedAt, originalMetadataUpdatedAt)
    XCTAssertEqual(bodyUpdated.editorMetadataRevision, originalEditorMetadataRevision)
    XCTAssertEqual(store.draftList.presentationRevision, initialDraftListRevision)

    var metadataEdit = bodyUpdated
    metadataEdit.title = "真正的元数据编辑"
    store.updateDraft(metadataEdit)
    let metadataUpdated = try XCTUnwrap(store.draft(for: original.id))
    XCTAssertGreaterThan(metadataUpdated.metadataUpdatedAt, originalMetadataUpdatedAt)
    XCTAssertGreaterThan(metadataUpdated.editorMetadataRevision, originalEditorMetadataRevision)
  }

  func testAttachmentMetadataRevisionRejectsStaleEditorWindow() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let original = try XCTUnwrap(store.selectedDraft)
    let originalMetadataUpdatedAt = original.metadataUpdatedAt
    let initialDraftListRevision = store.draftList.presentationRevision
    var firstWindow = original
    var staleWindow = original
    let attachment = DraftAttachment(
      originalFilename: "hero.png",
      relativePublishPath: "images/hero.png",
      repositoryPath: "static/images/hero.png"
    )
    firstWindow.attachments = [attachment]

    XCTAssertTrue(store.updateDraftFromEditor(firstWindow))
    XCTAssertEqual(
      store.draft(for: original.id)?.editorMetadataRevision,
      original.editorMetadataRevision + 1
    )
    XCTAssertEqual(
      store.draft(for: original.id)?.metadataUpdatedAt,
      originalMetadataUpdatedAt
    )
    XCTAssertEqual(store.draftList.presentationRevision, initialDraftListRevision)

    staleWindow.title = "陈旧窗口标题"
    XCTAssertFalse(store.updateDraftFromEditor(staleWindow))
    XCTAssertEqual(store.draft(for: original.id)?.attachments, [attachment])
    XCTAssertNotEqual(store.draft(for: original.id)?.title, staleWindow.title)
  }

  func testDraftListUpdatedSortUsesMetadataTimestampInsteadOfBodyTimestamp() {
    let profileID = SiteProfile.defaultProfile.id
    let metadataBaseline = Date(timeIntervalSince1970: 100)
    let bodyNewest = ArticleDraft(
      siteProfileID: profileID,
      title: "正文更新较新",
      updatedAt: Date(timeIntervalSince1970: 300),
      metadataUpdatedAt: metadataBaseline
    )
    let metadataNewest = ArticleDraft(
      siteProfileID: profileID,
      title: "元数据更新较新",
      updatedAt: Date(timeIntervalSince1970: 200),
      metadataUpdatedAt: Date(timeIntervalSince1970: 200)
    )

    let sorted = DraftListProjection.sorted(
      [bodyNewest, metadataNewest],
      by: .updatedNewest
    )
    XCTAssertEqual(sorted.map(\.id), [metadataNewest.id, bodyNewest.id])
  }

  func testDraftListTitleTieBreakUsesMetadataTimestamp() {
    let profileID = SiteProfile.defaultProfile.id
    let older = ArticleDraft(
      siteProfileID: profileID,
      title: "相同标题",
      updatedAt: Date(timeIntervalSince1970: 300),
      metadataUpdatedAt: Date(timeIntervalSince1970: 100)
    )
    let newer = ArticleDraft(
      siteProfileID: profileID,
      title: "相同标题",
      updatedAt: Date(timeIntervalSince1970: 100),
      metadataUpdatedAt: Date(timeIntervalSince1970: 200)
    )

    let sorted = DraftListProjection.sorted(
      [older, newer],
      by: .titleAscending
    )
    XCTAssertEqual(sorted.map(\.id), [newer.id, older.id])
  }

  func testFlushedBodyRefreshesPersistedWordCountAsynchronously() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let body = "中文正文 Swift words"

    _ = store.stageDraftBody(body, for: draft.id, baseRevision: 0)
    store.flushDraftBodyEditorBuffer(for: draft.id)

    let expected = MarkdownWritingStatisticsService.statistics(in: body).writingUnitCount
    for _ in 0..<100 {
      if store.drafts.first(where: { $0.id == draft.id })?.wordCount == expected {
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    let refreshed = try XCTUnwrap(store.drafts.first(where: { $0.id == draft.id }))
    XCTAssertEqual(refreshed.wordCount, expected)
    XCTAssertFalse(refreshed.wordCountNeedsRefresh)
  }

  func testStaleWordCountResultCannotOverwriteNewerBody() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    var draft = try XCTUnwrap(store.selectedDraft)
    let staleBody = String(repeating: "旧正文 ", count: 20_000)
    let currentBody = "最新正文"

    draft.bodyMarkdown = staleBody
    store.updateDraft(draft)
    draft = try XCTUnwrap(store.drafts.first(where: { $0.id == draft.id }))
    draft.bodyMarkdown = currentBody
    store.updateDraft(draft)

    let expected = MarkdownWritingStatisticsService.statistics(in: currentBody).writingUnitCount
    for _ in 0..<100 {
      if store.drafts.first(where: { $0.id == draft.id })?.wordCount == expected {
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    let refreshed = try XCTUnwrap(store.drafts.first(where: { $0.id == draft.id }))
    XCTAssertEqual(refreshed.bodyMarkdown, currentBody)
    XCTAssertEqual(refreshed.wordCount, expected)
    XCTAssertFalse(refreshed.wordCountNeedsRefresh)
  }

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

  func testDeletedDraftRejectsStaleEditorWriteInsteadOfResurrectingIt() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let staleEditorDraft = try XCTUnwrap(store.selectedDraft)

    store.deleteDraft(id: staleEditorDraft.id)
    XCTAssertNil(store.draft(for: staleEditorDraft.id))

    var staleWrite = staleEditorDraft
    staleWrite.title = "旧窗口不应复活文章"
    XCTAssertFalse(store.updateDraftFromEditor(staleWrite))
    XCTAssertNil(store.draft(for: staleEditorDraft.id))
    XCTAssertTrue(store.publishActionMessage?.contains("已被删除或下线") == true)
  }

  func testDeletingDraftFlushesDirtyBodyIntoRecycleBin() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let stagedBody = "删除前还没到延迟落盘时间的正文"
    let buffer = store.draftBodyEditorBuffer(for: draft.id)

    let result = try XCTUnwrap(
      store.stageDraftBody(stagedBody, for: draft.id, baseRevision: buffer.revision)
    )
    XCTAssertTrue(result.wasAccepted)
    store.deleteDraft(id: draft.id)

    XCTAssertNil(store.draft(for: draft.id))
    XCTAssertTrue(store.restoreRecycledDraft(draft.id))
    XCTAssertEqual(store.draft(for: draft.id)?.bodyMarkdown, stagedBody)
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
