import Combine
import Foundation
import PublishingDomainContracts
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class DraftBodyEditorBufferTests: XCTestCase {
  func testArticleWritingGoalRoundTripsAndLegacyDraftHasNoGoal() throws {
    let profileID = SiteProfile.defaultProfile.id
    let draft = ArticleDraft(
      siteProfileID: profileID,
      title: "有目标的文章",
      targetWordCount: 1800
    )
    let encoded = try JSONEncoder().encode(draft)
    XCTAssertEqual(
      try JSONDecoder().decode(ArticleDraft.self, from: encoded).targetWordCount,
      1800
    )

    var legacyObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    legacyObject.removeValue(forKey: "targetWordCountStorage")
    let legacy = try JSONDecoder().decode(
      ArticleDraft.self,
      from: JSONSerialization.data(withJSONObject: legacyObject)
    )
    XCTAssertNil(legacy.targetWordCount)
  }

  func testWritingGoalUpdateAffectsOnlyItsArticleAndAdvancesEditorRevision() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let original = try XCTUnwrap(store.selectedDraft)
    store.createDraft()
    let second = try XCTUnwrap(store.selectedDraft)
    let initialListRevision = store.draftList.presentationRevision

    var update = original
    update.targetWordCount = 1250
    XCTAssertTrue(store.updateDraftFromEditor(update))

    let changed = try XCTUnwrap(store.draft(for: original.id))
    XCTAssertEqual(changed.targetWordCount, 1250)
    XCTAssertEqual(changed.editorMetadataRevision, original.editorMetadataRevision + 1)
    XCTAssertEqual(store.draft(for: second.id)?.targetWordCount, nil)
    XCTAssertEqual(store.draftList.presentationRevision, initialListRevision)
  }

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

@MainActor
final class DraftPreflightCacheTests: XCTestCase {
  func testSequentialDraftResultsSurviveSiblingWordCountAndSelectionChanges() async throws {
    let (store, first, second) = try makeStore()
    let firstResult = await store.runPreflight(for: first.id)
    XCTAssertNotNil(firstResult)
    store.scheduleDraftWordCountRefresh(for: second.id, bodyMarkdown: second.bodyMarkdown)
    let secondResult = await store.runPreflight(for: second.id)
    XCTAssertNotNil(secondResult)

    XCTAssertEqual(store.cachedPreflightResult(for: first.id), firstResult)
    XCTAssertEqual(store.cachedPreflightResult(for: second.id), secondResult)
    store.selectDraft(second.id)
    await store.preflightRefreshTask?.value
    store.selectDraft(first.id)
    await store.preflightRefreshTask?.value
    XCTAssertEqual(store.cachedPreflightResult(for: first.id)?.context, firstResult?.context)
    XCTAssertEqual(store.cachedPreflightResult(for: second.id)?.context, secondResult?.context)
  }

  func testSelectedCalculationInstallsCacheWithoutFlushingAnotherWindowsBuffer() async throws {
    let (store, first, second) = try makeStore()
    // Make the second window active before the first window stages its body.
    // Changing selection itself intentionally commits the previous editor.
    store.selectDraft(second.id)
    let initialBuffer = store.draftBodyEditorBuffer(for: first.id)
    _ = store.stageDraftBody("另一窗口仍在输入", for: first.id, baseRevision: initialBuffer.revision)
    store.draftBodyCommitTasks[first.id]?.cancel()
    store.draftBodyCommitTasks[first.id] = nil

    store.refreshPreflightForSelection()
    await store.preflightRefreshTask?.value

    XCTAssertNotNil(store.cachedPreflightResult(for: second.id))
    XCTAssertNil(store.cachedPreflightResult(for: first.id))
    XCTAssertTrue(store.draftBodyEditorBuffer(for: first.id).isDirty)
    XCTAssertEqual(store.draft(for: first.id)?.bodyMarkdown, first.bodyMarkdown)
  }

  func testDirtyTargetAndSiblingBuffersInvalidateResultsEvenWithoutEditorWillChange() async throws {
    let (store, first, second) = try makeStore()
    _ = await store.runPreflight(for: first.id)
    _ = await store.runPreflight(for: second.id)
    XCTAssertNotNil(store.cachedPreflightResult(for: first.id))
    let buffer = store.draftBodyEditorBuffer(for: second.id)

    _ = store.stageDraftBody(
      "新正文", for: second.id, baseRevision: buffer.revision, notifyEditorObservers: false
    )
    store.draftBodyCommitTasks[second.id]?.cancel()
    store.draftBodyCommitTasks[second.id] = nil

    XCTAssertNil(store.cachedPreflightResult(for: first.id))
    XCTAssertNil(store.cachedPreflightResult(for: second.id))
  }

  func testMetadataAndSiblingCollisionEditsInvalidateCache() async throws {
    let (store, first, second) = try makeStore()
    _ = await store.runPreflight(for: first.id)
    var sibling = second
    sibling.slug = first.slug
    store.updateDraft(sibling)
    XCTAssertNil(store.cachedPreflightResult(for: first.id))

    _ = await store.runPreflight(for: first.id)
    XCTAssertNotNil(store.cachedPreflightResult(for: first.id))
    var edited = try XCTUnwrap(store.draft(for: first.id))
    edited.title = "Changed title"
    store.updateDraft(edited)
    XCTAssertNil(store.cachedPreflightResult(for: first.id))
  }

  func testProfileLinkAuditAndRepositoryInputsRejectPreviousSnapshots() async throws {
    let (store, first, _) = try makeStore()
    _ = await store.runPreflight(for: first.id)
    store.updateActiveProfile { $0.siteKind = .hugo }
    XCTAssertNil(store.cachedPreflightResult(for: first.id))

    _ = await store.runPreflight(for: first.id)
    XCTAssertNotNil(store.cachedPreflightResult(for: first.id))
    store.invalidateSiteLinkAuditSnapshot()
    XCTAssertNil(store.cachedPreflightResult(for: first.id))

    _ = await store.runPreflight(for: first.id)
    XCTAssertNotNil(store.cachedPreflightResult(for: first.id))
    store.setRepositoryReport(nil)
    XCTAssertNil(store.cachedPreflightResult(for: first.id))
  }

  func testReportPublicationRejectsSnapshotEvenWhenScanRevisionIsUnchanged() async throws {
    let (store, first, _) = try makeStore()
    _ = await store.runPreflight(for: first.id)
    let scanRevision = store.repositoryStore.repositoryLineDiffReportRevision
    store.repositoryStore.repositoryReport = nil

    XCTAssertEqual(store.repositoryStore.repositoryLineDiffReportRevision, scanRevision)
    XCTAssertNil(store.cachedPreflightResult(for: first.id))
  }

  func testOlderGenerationCannotReplaceNewerResultForSameDraft() throws {
    let (store, first, _) = try makeStore()
    let oldGeneration = store.beginDraftPreflightCalculation(for: first.id)
    let key = try XCTUnwrap(store.draftScopedPreflightRequestKey(for: first.id))
    let oldSnapshot = snapshot(store: store, key: key, title: "Older result")
    let newGeneration = store.beginDraftPreflightCalculation(for: first.id)
    let newSnapshot = snapshot(store: store, key: key, title: "Newer result")

    XCTAssertTrue(store.installDraftPreflightSnapshot(newSnapshot, generation: newGeneration))
    XCTAssertFalse(store.installDraftPreflightSnapshot(oldSnapshot, generation: oldGeneration))
    XCTAssertEqual(store.cachedPreflightResult(for: first.id)?.issues.first?.title, "Newer result")
  }

  func testOlderAsyncRequestWaitingForWordCountCannotOverwriteNewerRequest() async throws {
    let (store, first, _) = try makeStore()
    var resumeWordCount: CheckedContinuation<Void, Never>?
    let wordCountTask = Task {
      await withCheckedContinuation { resumeWordCount = $0 }
    }
    store.draftWordCountRefreshTasks[first.id] = wordCountTask
    let oldRequest = Task { await store.runPreflight(for: first.id) }
    for _ in 0..<20 {
      if store.publishingStore.publishSession.draftPreflightGenerations[first.id] != nil,
        resumeWordCount != nil
      {
        break
      }
      await Task.yield()
    }
    let continuation = try XCTUnwrap(resumeWordCount)
    store.draftWordCountRefreshTasks[first.id] = nil
    let newerResult = await store.runPreflight(for: first.id)
    XCTAssertNotNil(newerResult)
    continuation.resume()
    let olderResult = await oldRequest.value

    XCTAssertNil(olderResult)
    XCTAssertEqual(store.cachedPreflightResult(for: first.id), newerResult)
  }

  func testDerivedWordCountPublicationPreservesCachesWithoutCacheNotifications() async throws {
    let (store, first, second) = try makeStore()
    _ = await store.runPreflight(for: first.id)
    _ = await store.runPreflight(for: second.id)
    await drainNotifications()
    var notifications = 0
    let cancellable = store.publishingStore.publishSession.draftPublishStatusDidChange.sink {
      notifications += 1
    }

    store.publishingStore.updateDraftWordCount(
      2, for: second.id, matching: second.bodyMarkdown, store: store
    )
    await drainNotifications()

    XCTAssertNotNil(store.cachedPreflightResult(for: first.id))
    XCTAssertNotNil(store.cachedPreflightResult(for: second.id))
    XCTAssertEqual(notifications, 0)
    XCTAssertFalse(store.publishingStore.publishSession.isPublishingDerivedWordCount)
    withExtendedLifetime(cancellable) {}
  }

  func testBackgroundCacheInstallAndInvalidationNotifyAfterInputsCommit() async throws {
    let (store, first, second) = try makeStore()
    let facade = store.publishStatus
    var visibleResults: [DraftPreflightResult?] = []
    let cancellable = facade.objectWillChange.sink {
      visibleResults.append(store.cachedPreflightResult(for: second.id))
    }
    store.setSelectedDraftID(first.id)
    _ = await store.runPreflight(for: second.id)
    await drainNotifications()
    XCTAssertTrue(visibleResults.contains { $0?.context.draftID == second.id })
    visibleResults.removeAll()

    let buffer = store.draftBodyEditorBuffer(for: second.id)
    _ = store.stageDraftBody("Background edit", for: second.id, baseRevision: buffer.revision)
    store.draftBodyCommitTasks[second.id]?.cancel()
    store.draftBodyCommitTasks[second.id] = nil
    await drainNotifications()
    XCTAssertFalse(visibleResults.isEmpty)
    XCTAssertTrue(visibleResults.allSatisfy { $0 == nil })
    withExtendedLifetime(cancellable) {}
  }

  func testBackgroundInputsContinueNotifyingAfterCacheIsEmpty() async throws {
    let (store, first, second) = try makeStore()
    _ = await store.runPreflight(for: second.id)
    await drainNotifications()
    store.setSelectedDraftID(first.id)
    var notifications = 0
    let cancellable = store.publishStatus.objectWillChange.sink { notifications += 1 }
    let initialBuffer = store.draftBodyEditorBuffer(for: second.id)
    _ = store.stageDraftBody("First edit", for: second.id, baseRevision: initialBuffer.revision)
    store.draftBodyCommitTasks[second.id]?.cancel()
    store.draftBodyCommitTasks[second.id] = nil
    await drainNotifications()
    XCTAssertNil(store.cachedPreflightResult(for: second.id))
    let previousNotifications = notifications
    XCTAssertGreaterThan(previousNotifications, 0)

    let nextBuffer = store.draftBodyEditorBuffer(for: second.id)
    _ = store.stageDraftBody("Second edit", for: second.id, baseRevision: nextBuffer.revision)
    store.draftBodyCommitTasks[second.id]?.cancel()
    store.draftBodyCommitTasks[second.id] = nil
    await drainNotifications()
    XCTAssertGreaterThan(notifications, previousNotifications)
    XCTAssertNil(store.cachedPreflightResult(for: second.id))
    withExtendedLifetime(cancellable) {}
  }

  func testCacheAndGenerationBookkeepingAreBoundedAndDeletedDraftsAreRemoved() async throws {
    let (store, _, _) = try makeStore()
    let drafts = (0..<68).map { index in
      var draft = ArticleDraft.emptyGeneralDraft(editingProfile: store.activeProfile)
      draft.title = "General \(index)"
      return draft
    }
    store.setDrafts(drafts)
    for draft in drafts {
      let result = await store.runPreflight(for: draft.id)
      XCTAssertNotNil(result)
    }
    let session = store.publishingStore.publishSession
    XCTAssertEqual(session.draftPreflightSnapshots.count, 64)
    XCTAssertEqual(session.draftPreflightGenerations.count, 64)
    XCTAssertNil(store.cachedPreflightResult(for: drafts[0].id))
    XCTAssertNotNil(store.cachedPreflightResult(for: drafts[67].id))

    store.setDrafts([])
    XCTAssertTrue(session.draftPreflightSnapshots.isEmpty)
    XCTAssertTrue(session.draftPreflightGenerations.isEmpty)
    XCTAssertTrue(session.draftPreflightAccessOrder.isEmpty)
  }

  func testTwoEnsureRequestsShareOneCalculationAndThenUseCache() async throws {
    let (store, first, _) = try makeStore()
    let resumeWordCount = try await blockWordCount(store: store, for: first.id)
    let firstRequest = Task { await store.ensurePreflight(for: first.id) }
    let operation = try await waitForOperation(store: store, for: first.id)
    let secondRequest = Task { await store.ensurePreflight(for: first.id) }
    await drainNotifications()
    let session = store.publishingStore.publishSession
    XCTAssertEqual(session.draftPreflightGeneration, operation.generation)
    XCTAssertEqual(session.draftPreflightRefreshTasks.count, 1)
    resumeWordCount.resume()

    let firstResult = await firstRequest.value
    let secondResult = await secondRequest.value
    XCTAssertNotNil(firstResult)
    XCTAssertEqual(firstResult, secondResult)
    let cachedResult = await store.ensurePreflight(for: first.id)
    XCTAssertEqual(cachedResult, firstResult)
    XCTAssertEqual(session.draftPreflightGeneration, operation.generation)
    await drainNotifications()
    XCTAssertTrue(session.draftPreflightRefreshTasks.isEmpty)
  }

  func testCancellingOneEnsureWaiterDoesNotCancelSharedCalculation() async throws {
    let (store, first, _) = try makeStore()
    let resumeWordCount = try await blockWordCount(store: store, for: first.id)
    let cancelledRequest = Task { await store.ensurePreflight(for: first.id) }
    let operation = try await waitForOperation(store: store, for: first.id)
    let survivingRequest = Task { await store.ensurePreflight(for: first.id) }
    await drainNotifications()
    cancelledRequest.cancel()

    let cancelledResult = await cancelledRequest.value
    XCTAssertNil(cancelledResult)
    XCTAssertFalse(operation.task.isCancelled)
    XCTAssertNil(store.cachedPreflightResult(for: first.id))
    resumeWordCount.resume()
    let result = await survivingRequest.value
    XCTAssertNotNil(result)
    XCTAssertEqual(store.cachedPreflightResult(for: first.id), result)
  }

  func testEnsureFollowsSameInputForceRefreshBeforeOldWordCountFinishes() async throws {
    let (store, first, _) = try makeStore()
    let resumeWordCount = try await blockWordCount(store: store, for: first.id)
    let ensured = expectation(description: "Ensure follows the replacement task")
    let ensureRequest = Task {
      let result = await store.ensurePreflight(for: first.id)
      ensured.fulfill()
      return result
    }
    let previous = try await waitForOperation(store: store, for: first.id)
    store.draftWordCountRefreshTasks[first.id] = nil
    let forcedResult = await store.runPreflight(for: first.id)
    XCTAssertNotNil(forcedResult)
    XCTAssertTrue(previous.task.isCancelled)
    await fulfillment(of: [ensured], timeout: 1)
    resumeWordCount.resume()
    let ensuredResult = await ensureRequest.value

    XCTAssertEqual(ensuredResult, forcedResult)
    XCTAssertEqual(store.cachedPreflightResult(for: first.id), forcedResult)
  }

  func testRefreshIdentityIncludesSiblingBufferAndSameRevisionRepositoryInputs() throws {
    let (store, first, second) = try makeStore()
    let initial = try XCTUnwrap(store.draftPreflightRefreshIdentity(for: first.id))
    let buffer = store.draftBodyEditorBuffer(for: second.id)
    _ = store.stageDraftBody("Sibling input", for: second.id, baseRevision: buffer.revision)
    store.draftBodyCommitTasks[second.id]?.cancel()
    store.draftBodyCommitTasks[second.id] = nil
    let siblingChanged = try XCTUnwrap(store.draftPreflightRefreshIdentity(for: first.id))
    XCTAssertNotEqual(siblingChanged, initial)
    XCTAssertEqual(
      siblingChanged.requestKey.bodyRevision, initial.requestKey.bodyRevision
    )
    let scanRevision = store.repositoryStore.repositoryLineDiffReportRevision
    store.repositoryStore.repositoryReport = nil
    let repositoryChanged = try XCTUnwrap(store.draftPreflightRefreshIdentity(for: first.id))

    XCTAssertEqual(store.repositoryStore.repositoryLineDiffReportRevision, scanRevision)
    XCTAssertNotEqual(repositoryChanged, siblingChanged)
    XCTAssertNotEqual(
      repositoryChanged.repositoryInputGeneration, siblingChanged.repositoryInputGeneration
    )
  }

  func testDerivedWordCountDoesNotChangeRefreshIdentity() throws {
    let (store, first, second) = try makeStore()
    let initial = try XCTUnwrap(store.draftPreflightRefreshIdentity(for: first.id))
    let originalDraftRevision = store.draftMutationRevision
    store.publishingStore.updateDraftWordCount(
      2, for: second.id, matching: second.bodyMarkdown, store: store
    )

    XCTAssertGreaterThan(store.draftMutationRevision, originalDraftRevision)
    XCTAssertEqual(store.draftPreflightRefreshIdentity(for: first.id), initial)
  }

  func testEnsureWithoutFlushRejectsDirtyTargetAndDefaultFlushOnlyCommitsTarget() async throws {
    let (store, first, second) = try makeStore()
    for draft in [first, second] {
      let buffer = store.draftBodyEditorBuffer(for: draft.id)
      _ = store.stageDraftBody(
        "Pending \(draft.title)", for: draft.id, baseRevision: buffer.revision
      )
      store.draftBodyCommitTasks[draft.id]?.cancel()
      store.draftBodyCommitTasks[draft.id] = nil
    }
    let dirtyResult = await store.ensurePreflight(for: second.id, flushEditorBuffer: false)
    XCTAssertNil(dirtyResult)
    XCTAssertTrue(store.draftBodyEditorBuffer(for: second.id).isDirty)

    let flushedResult = await store.ensurePreflight(for: second.id)
    XCTAssertNotNil(flushedResult)
    XCTAssertFalse(store.draftBodyEditorBuffer(for: second.id).isDirty)
    XCTAssertTrue(store.draftBodyEditorBuffer(for: first.id).isDirty)
    XCTAssertEqual(store.selectedDraftID, first.id)
  }

  func testInputInvalidationCancelsAndRemovesRegisteredCalculation() async throws {
    let (store, first, second) = try makeStore()
    let resumeWordCount = try await blockWordCount(store: store, for: first.id)
    let request = Task { await store.ensurePreflight(for: first.id) }
    let operation = try await waitForOperation(store: store, for: first.id)
    var changedSibling = second
    changedSibling.title = "New sibling input"
    store.updateDraft(changedSibling)
    let cancelledResult = await request.value
    XCTAssertNil(cancelledResult)
    XCTAssertTrue(operation.task.isCancelled)
    XCTAssertTrue(store.publishingStore.publishSession.draftPreflightRefreshTasks.isEmpty)
    resumeWordCount.resume()
    _ = await operation.task.value
    XCTAssertNil(store.cachedPreflightResult(for: first.id))
  }

  func testDrawerReceivesFirstBackgroundPreflightCacheNotification() async throws {
    let (store, _, second) = try makeStore()
    var notifications = 0
    let cancellable = store.publishDrawerObservation.objectWillChange.sink { notifications += 1 }
    _ = await store.ensurePreflight(for: second.id)
    await drainNotifications()

    XCTAssertGreaterThan(notifications, 0)
    withExtendedLifetime(cancellable) {}
  }

  func testRegisteredTasksStayBoundedAndAreCancelledWhenDraftsAreRemoved() async throws {
    let (store, first, _) = try makeStore()
    let resumeWordCount = try await blockWordCount(store: store, for: first.id)
    let sharedWordCountTask = try XCTUnwrap(store.draftWordCountRefreshTasks[first.id])
    let drafts = (0..<68).map { index in
      ArticleDraft(
        siteProfileID: store.activeProfileID, title: "Draft \(index)", slug: "draft-\(index)",
        bodyMarkdown: "Body", wordCount: 1
      )
    }
    store.setDrafts(drafts)
    for draft in drafts { store.draftWordCountRefreshTasks[draft.id] = sharedWordCountTask }
    let session = store.publishingStore.publishSession
    let initialGeneration = session.draftPreflightGeneration
    let requests = drafts.map { draft in Task { await store.ensurePreflight(for: draft.id) } }
    for _ in 0..<100 {
      if session.draftPreflightGeneration == initialGeneration + 68 { break }
      await Task.yield()
    }
    XCTAssertEqual(session.draftPreflightGeneration, initialGeneration + 68)
    XCTAssertEqual(session.draftPreflightRefreshTasks.count, 64)
    XCTAssertEqual(session.draftPreflightGenerations.count, 64)

    store.setDrafts([])
    XCTAssertTrue(session.draftPreflightRefreshTasks.isEmpty)
    XCTAssertTrue(session.draftPreflightGenerations.isEmpty)
    resumeWordCount.resume()
    for request in requests {
      let result = await request.value
      XCTAssertNil(result)
    }
    XCTAssertTrue(session.draftPreflightSnapshots.isEmpty)
  }

  func testDisplayedResultKeepsPreviousChecklistWhileAnEditInvalidatesTheCache() async throws {
    let (store, first, second) = try makeStore()
    XCTAssertNil(store.displayedPreflightResult(for: first.id), "Never calculated")
    let result = await store.runPreflight(for: first.id)
    let calculated = try XCTUnwrap(result)
    XCTAssertEqual(store.displayedPreflightResult(for: first.id)?.isCurrent, true)

    // Typing invalidates every cache; the previous complete result stays
    // displayable so a badge cannot fall to a partial count mid-edit.
    let buffer = store.draftBodyEditorBuffer(for: first.id)
    _ = store.stageDraftBody("Edited body", for: first.id, baseRevision: buffer.revision)
    store.draftBodyCommitTasks[first.id]?.cancel()
    store.draftBodyCommitTasks[first.id] = nil
    XCTAssertNil(store.cachedPreflightResult(for: first.id))
    let displayed = try XCTUnwrap(store.displayedPreflightResult(for: first.id))
    XCTAssertFalse(displayed.isCurrent)
    XCTAssertEqual(displayed.result, calculated)
    XCTAssertNil(store.displayedPreflightResult(for: second.id))
  }

  func testDisplayedResultIsDroppedWhenTheDraftIsRemoved() async throws {
    let (store, first, second) = try makeStore()
    _ = await store.runPreflight(for: first.id)
    _ = await store.runPreflight(for: second.id)

    store.setDrafts([second])
    XCTAssertNil(store.displayedPreflightResult(for: first.id))
    XCTAssertNotNil(store.displayedPreflightResult(for: second.id))
    XCTAssertNil(
      store.publishingStore.publishSession.draftPreflightLastKnownResults[first.id],
      "Removed drafts must not keep a remembered result")
  }

  private func makeStore() throws -> (WorkbenchStore, ArticleDraft, ArticleDraft) {
    let persistence = try TestWorkbenchFactory.persistence(prefix: "DraftPreflightCache")
    let rootURL = persistence.fileURL.deletingLastPathComponent()
    addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }
    func tokens(_ role: String) -> KeychainTokenStore {
      KeychainTokenStore(
        service: "draft-preflight-cache-\(role)-\(UUID())", accountPrefix: "tests", inMemory: true)
    }
    let store = WorkbenchStore(
      persistence: persistence, safeMode: true,
      keychainTokenStore: tokens("ai"), repositoryTokenStore: tokens("repository"),
      deploymentTokenStore: tokens("deployment")
    )
    let first = ArticleDraft(
      siteProfileID: store.activeProfileID, title: "First", slug: "first",
      bodyMarkdown: "First body", wordCount: 2
    )
    let second = ArticleDraft(
      siteProfileID: store.activeProfileID, title: "Second", slug: "second",
      bodyMarkdown: "Second body"
    )
    store.setDrafts([first, second])
    store.setSelectedDraftID(first.id)
    return (store, first, second)
  }

  private func snapshot(
    store: WorkbenchStore,
    key: DraftScopedPreflightRequestKey,
    title: String
  ) -> DraftPreflightSnapshot {
    store.makeDraftPreflightSnapshot(
      result: DraftPreflightResult(
        context: DraftExecutionContext(
          draftID: key.draftID, profileID: key.profile.id, bodyRevision: key.bodyRevision
        ),
        issues: [PreflightIssue(severity: .warning, title: title, message: title)]
      ),
      requestKey: key
    )
  }

  private func drainNotifications() async {
    for _ in 0..<5 { await Task.yield() }
  }

  private func blockWordCount(
    store: WorkbenchStore,
    for draftID: UUID
  ) async throws -> CheckedContinuation<Void, Never> {
    let blocked = expectation(description: "Word-count task is blocked")
    var resumeWordCount: CheckedContinuation<Void, Never>?
    store.draftWordCountRefreshTasks[draftID] = Task {
      await withCheckedContinuation {
        resumeWordCount = $0
        blocked.fulfill()
      }
    }
    await fulfillment(of: [blocked], timeout: 1)
    return try XCTUnwrap(resumeWordCount)
  }

  private func waitForOperation(
    store: WorkbenchStore,
    for draftID: UUID
  ) async throws -> DraftPreflightRefreshOperation {
    for _ in 0..<100 {
      if let operation = store.publishingStore.publishSession.draftPreflightRefreshTasks[draftID] {
        return operation
      }
      await Task.yield()
    }
    return try XCTUnwrap(store.publishingStore.publishSession.draftPreflightRefreshTasks[draftID])
  }
}
