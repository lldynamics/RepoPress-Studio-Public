import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class DraftRecoveryJournalTests: XCTestCase {
  func testJournalRoundTripsRecordsAndCapsHistory() throws {
    let directoryURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "DraftRecoveryJournal")
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let journal = DraftRecoveryJournal(
      fileURL: directoryURL.appendingPathComponent("draft-recovery.json")
    )
    let profile = SiteProfile.defaultProfile
    let records = (0..<(DraftRecoveryJournal.maximumRecordCount + 2)).map { offset in
      DraftRecoveryRecord(
        draftID: UUID(),
        siteProfileID: profile.id,
        scope: .site(profile.id),
        title: "草稿 \(offset)",
        slug: "draft-\(offset)",
        tags: [],
        categories: [],
        authors: [],
        draft: true,
        visibility: .public,
        summary: "",
        repositoryPath: nil,
        baselineBodyMarkdown: "旧正文",
        recoveredBodyMarkdown: "未保存正文 \(offset)",
        capturedAt: Date(timeIntervalSince1970: TimeInterval(offset))
      )
    }

    try journal.save(records)
    let loaded = try journal.load()

    XCTAssertEqual(loaded.count, DraftRecoveryJournal.maximumRecordCount)
    XCTAssertEqual(loaded.first?.recoveredBodyMarkdown, "未保存正文 17")
    XCTAssertEqual(loaded.last?.recoveredBodyMarkdown, "未保存正文 2")
  }

  func testJournalDeduplicatesDraftIDAndKeepsNewestRecovery() throws {
    let directoryURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "DraftRecoveryDuplicates"
    )
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let journal = DraftRecoveryJournal(
      fileURL: directoryURL.appendingPathComponent("draft-recovery.json")
    )
    let draft = ArticleDraft(siteProfileID: SiteProfile.defaultProfile.id, title: "重复草稿")
    let older = DraftRecoveryRecord(
      draft: draft,
      recoveredBodyMarkdown: "旧恢复",
      capturedAt: Date(timeIntervalSince1970: 1)
    )
    let newer = DraftRecoveryRecord(
      draft: draft,
      recoveredBodyMarkdown: "新恢复",
      capturedAt: Date(timeIntervalSince1970: 2)
    )

    try journal.save([older, newer])
    let loaded = try journal.load()

    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded.first?.recoveredBodyMarkdown, "新恢复")
  }

  func testUnreadableJournalIsReportedAndQuarantinedOnLaunch() throws {
    let persistenceURL = try TestWorkbenchFactory.temporaryPersistenceURL(
      prefix: "DraftRecoveryUnreadable"
    )
    let directoryURL = persistenceURL.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    try Data("not-json".utf8).write(to: persistence.draftRecoveryJournalURL)

    let store = WorkbenchStore(persistence: persistence, safeMode: true)

    XCTAssertTrue(store.draftRecoveryJournalErrorMessage?.contains("原文件已隔离") == true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.draftRecoveryJournalURL.path))
    let quarantinedNames = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
      .filter { $0.contains("draft-recovery.unreadable-") }
    XCTAssertEqual(quarantinedNames.count, 1)
  }

  func testUncommittedEditorBodySurvivesStoreReloadAndCanBeRestored() async throws {
    let persistenceURL = try TestWorkbenchFactory.temporaryPersistenceURL(prefix: "DraftRecoveryStore")
    defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    let store = WorkbenchStore(persistence: persistence, safeMode: true)
    let draft = try XCTUnwrap(store.selectedDraft)
    store.save()
    await store.waitForPendingSave()

    _ = store.stageDraftBody(
      "这段正文尚未进入主工作台快照。",
      for: draft.id,
      baseRevision: 0
    )
    store.flushDraftRecoveryJournal()

    let reloaded = WorkbenchStore(persistence: persistence, safeMode: true)
    let recovery = try XCTUnwrap(reloaded.pendingDraftRecoveries.first)
    XCTAssertEqual(recovery.draftID, draft.id)
    XCTAssertEqual(recovery.recoveredBodyMarkdown, "这段正文尚未进入主工作台快照。")
    XCTAssertEqual(
      reloaded.drafts.first(where: { $0.id == draft.id })?.bodyMarkdown,
      draft.bodyMarkdown
    )

    XCTAssertTrue(reloaded.restoreDraftRecovery(recovery))
    XCTAssertEqual(
      reloaded.drafts.first(where: { $0.id == draft.id })?.bodyMarkdown,
      "这段正文尚未进入主工作台快照。"
    )
    XCTAssertTrue(reloaded.pendingDraftRecoveries.isEmpty)
  }

  func testBackgroundJournalFailureIsObservableAndNextSuccessfulWriteClearsIt() async throws {
    let persistenceURL = try TestWorkbenchFactory.temporaryPersistenceURL(
      prefix: "DraftRecoveryWriteFailure"
    )
    let directoryURL = persistenceURL.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    let journalURL = persistence.draftRecoveryJournalURL
    let store = WorkbenchStore(persistence: persistence, safeMode: true)
    let draft = try XCTUnwrap(store.selectedDraft)
    let editorState = WorkbenchMarkdownEditorFeatureFacade(store: store, draftID: draft.id)
    // Create the obstacle after launch. Startup intentionally quarantines an
    // unreadable journal path, while this test covers a later write failure.
    try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)
    _ = store.stageDraftBody(
      "第一次尝试保存的恢复内容。",
      for: draft.id,
      baseRevision: 0
    )

    await store.waitForPendingDraftRecoveryJournalWrite()

    let failureMessage = try XCTUnwrap(store.draftRecoveryJournalErrorMessage)
    XCTAssertFalse(failureMessage.isEmpty)
    XCTAssertEqual(store.lastSaveError, failureMessage)
    XCTAssertEqual(editorState.lastSaveStatus, failureMessage)
    XCTAssertTrue(editorState.hasUnsavedChanges)

    try FileManager.default.removeItem(at: journalURL)
    let currentBuffer = store.draftBodyEditorBuffer(for: draft.id)
    _ = store.stageDraftBody(
      "第二次尝试已经可以写入恢复日志。",
      for: draft.id,
      baseRevision: currentBuffer.revision
    )

    await store.waitForPendingDraftRecoveryJournalWrite()

    XCTAssertNil(store.draftRecoveryJournalErrorMessage)
    XCTAssertNil(store.lastSaveError)
    XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
  }

  func testExitFlushPreservesRecoveryWhenPrimarySnapshotCannotBeSaved() throws {
    let persistenceURL = try TestWorkbenchFactory.temporaryPersistenceURL(
      prefix: "DraftRecoveryPrimaryFailure"
    )
    let directoryURL = persistenceURL.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    let store = WorkbenchStore(persistence: persistence, safeMode: true)
    let draft = try XCTUnwrap(store.selectedDraft)

    _ = store.stageDraftBody(
      "主快照写入失败时仍须保留的正文。",
      for: draft.id,
      baseRevision: 0
    )
    try FileManager.default.createDirectory(at: persistenceURL, withIntermediateDirectories: true)

    XCTAssertFalse(store.flushPendingChanges())

    let recovery = try XCTUnwrap(
      DraftRecoveryJournal(fileURL: persistence.draftRecoveryJournalURL)
        .load()
        .first(where: { $0.draftID == draft.id })
    )
    XCTAssertEqual(recovery.recoveredBodyMarkdown, "主快照写入失败时仍须保留的正文。")
    XCTAssertNotNil(store.lastSaveError)
  }

  func testExitFlushPreservesRecoveryWhilePrimarySnapshotIsWriteProtected() throws {
    let persistenceURL = try TestWorkbenchFactory.temporaryPersistenceURL(
      prefix: "DraftRecoveryWriteProtected"
    )
    let directoryURL = persistenceURL.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    let store = WorkbenchStore(persistence: persistence, safeMode: true)
    let draft = try XCTUnwrap(store.selectedDraft)
    store.persistenceStore.protectWritesForUnrecoverableSnapshot(
      message: "测试中的损坏主快照"
    )

    _ = store.stageDraftBody(
      "主快照受保护时仍须保留的正文。",
      for: draft.id,
      baseRevision: 0
    )

    XCTAssertTrue(store.flushPendingChanges())
    let recovery = try XCTUnwrap(
      DraftRecoveryJournal(fileURL: persistence.draftRecoveryJournalURL)
        .load()
        .first(where: { $0.draftID == draft.id })
    )
    XCTAssertEqual(recovery.recoveredBodyMarkdown, "主快照受保护时仍须保留的正文。")
  }

  func testOlderJournalGenerationCannotOverwriteNewerCommit() throws {
    let directoryURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "DraftRecoveryGeneration"
    )
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let journal = DraftRecoveryJournal(
      fileURL: directoryURL.appendingPathComponent("draft-recovery.json")
    )
    let coordinator = DraftRecoveryJournalWriteCoordinator()
    let draft = ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "测试草稿",
      bodyMarkdown: "基线"
    )
    let older = DraftRecoveryRecord(draft: draft, recoveredBodyMarkdown: "旧内容")
    let newer = DraftRecoveryRecord(draft: draft, recoveredBodyMarkdown: "新内容")

    XCTAssertTrue(try coordinator.save([newer], to: journal, generation: 2))
    XCTAssertFalse(try coordinator.save([older], to: journal, generation: 1))
    XCTAssertEqual(try journal.load().first?.recoveredBodyMarkdown, "新内容")
  }

  func testEditingAfterDeferringRecoveryMaterializesOldRecoveryBeforeReplacingJournal() async throws {
    let persistenceURL = try TestWorkbenchFactory.temporaryPersistenceURL(
      prefix: "DraftRecoveryDeferredEditing"
    )
    let directoryURL = persistenceURL.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    let initialStore = WorkbenchStore(persistence: persistence, safeMode: true)
    let draft = try XCTUnwrap(initialStore.selectedDraft)
    initialStore.save()
    await initialStore.waitForPendingSave()
    _ = initialStore.stageDraftBody("上次崩溃留下的正文。", for: draft.id, baseRevision: 0)
    XCTAssertTrue(initialStore.flushDraftRecoveryJournal())

    let resumedStore = WorkbenchStore(persistence: persistence, safeMode: true)
    XCTAssertEqual(resumedStore.pendingDraftRecoveries.first?.recoveredBodyMarkdown, "上次崩溃留下的正文。")
    _ = resumedStore.stageDraftBody("本次继续输入的新正文。", for: draft.id, baseRevision: 0)
    await resumedStore.waitForPendingDraftRecoveryJournalWrite()

    XCTAssertTrue(resumedStore.drafts.contains {
      $0.id != draft.id && $0.bodyMarkdown == "上次崩溃留下的正文。"
    })
    let reloaded = WorkbenchStore(persistence: persistence, safeMode: true)
    XCTAssertTrue(reloaded.drafts.contains {
      $0.id != draft.id && $0.bodyMarkdown == "上次崩溃留下的正文。"
    })
    XCTAssertEqual(reloaded.pendingDraftRecoveries.first?.recoveredBodyMarkdown, "本次继续输入的新正文。")
  }

  func testDeletingAndUndoingProfileKeepsLatestDirtyEditorBody() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftRecoveryProfileUndo")
    _ = store.createProfile(named: "可撤销站点")
    store.createDraft()
    let draft = try XCTUnwrap(store.selectedDraft)
    _ = store.stageDraftBody("删除前尚在防抖缓冲区里的正文。", for: draft.id, baseRevision: 0)

    let deletedProfile = try XCTUnwrap(store.deleteActiveProfile())
    XCTAssertFalse(deletedProfile.draftVersions.isEmpty)
    XCTAssertFalse(store.draftVersions.contains { $0.draftID == draft.id })
    XCTAssertTrue(
      store.flushPendingChanges(),
      store.lastSaveError ?? "profile deletion snapshot failed without an error"
    )
    XCTAssertTrue(store.restoreRecentlyDeletedProfile())

    XCTAssertEqual(store.selectedDraft?.id, draft.id)
    XCTAssertEqual(store.selectedDraft?.bodyMarkdown, "删除前尚在防抖缓冲区里的正文。")
    XCTAssertTrue(store.draftVersions.contains { $0.draftID == draft.id })
  }

  func testDeletingProfileTemporarilyRemovesItsRecycledDraftDependencies() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftRecoveryProfileRecycleUndo")
    let deletedProfile = store.createProfile(named: "含回收站文章的站点")
    store.createDraft()
    let recycledDraft = try XCTUnwrap(store.selectedDraft)
    var repositoryDraft = recycledDraft
    repositoryDraft.repositoryPath = "content/posts/recycled.md"
    store.updateDraft(repositoryDraft)
    store.deleteSelectedDraft()
    XCTAssertTrue(store.recycledDrafts.contains { $0.id == recycledDraft.id })

    let deletion = try XCTUnwrap(store.deleteActiveProfile())

    XCTAssertEqual(deletion.profile.id, deletedProfile.id)
    XCTAssertTrue(deletion.recycledDrafts.contains { $0.id == recycledDraft.id })
    XCTAssertFalse(store.recycledDrafts.contains { $0.id == recycledDraft.id })
    XCTAssertFalse(store.draftVersions.contains { $0.draftID == recycledDraft.id })
    XCTAssertFalse(store.draftRepositoryCleanupRequests.contains {
      $0.siteProfileID == deletedProfile.id
    })
    XCTAssertTrue(
      store.flushPendingChanges(),
      store.lastSaveError ?? "profile deletion snapshot failed without an error"
    )

    XCTAssertTrue(store.restoreRecentlyDeletedProfile())
    XCTAssertTrue(store.recycledDrafts.contains { $0.id == recycledDraft.id })
    XCTAssertTrue(store.draftVersions.contains { $0.draftID == recycledDraft.id })
    XCTAssertTrue(store.draftRepositoryCleanupRequests.contains {
      $0.siteProfileID == deletedProfile.id
    })
  }

  func testDeletingEditingProfileRebindsGeneralDraftHistoryAndRecycleBin() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftRecoveryGeneralRebind")
    let fallbackProfileID = store.activeProfileID
    let deletedProfile = store.createProfile(named: "通用草稿编辑上下文")

    store.createDraft()
    let retainedSiteDraft = try XCTUnwrap(store.selectedDraft)
    XCTAssertTrue(store.createManualVersion(for: retainedSiteDraft.id))
    let retainMovePlan = store.draftOwnershipTransferPlan(
      draftIDs: [retainedSiteDraft.id],
      operation: .moveToGeneral,
      targetProfileID: nil
    )
    XCTAssertNotNil(store.applyDraftOwnershipTransfer(retainMovePlan))
    let retainedGeneralDraft = try XCTUnwrap(store.selectedDraft)
    XCTAssertTrue(retainedGeneralDraft.isGeneralDraft)

    store.createDraft()
    let recycledSiteDraft = try XCTUnwrap(store.selectedDraft)
    XCTAssertTrue(store.createManualVersion(for: recycledSiteDraft.id))
    let movePlan = store.draftOwnershipTransferPlan(
      draftIDs: [recycledSiteDraft.id],
      operation: .moveToGeneral,
      targetProfileID: nil
    )
    XCTAssertNotNil(store.applyDraftOwnershipTransfer(movePlan))
    let recycledGeneralDraft = try XCTUnwrap(store.selectedDraft)
    XCTAssertTrue(recycledGeneralDraft.isGeneralDraft)
    store.deleteSelectedDraft()
    XCTAssertTrue(store.recycledDrafts.contains { $0.id == recycledGeneralDraft.id })
    let retainedGeneralIDs = Set([retainedGeneralDraft.id, recycledGeneralDraft.id])
    let versionCountBeforeDeletion = store.draftVersions.filter {
      retainedGeneralIDs.contains($0.draftID)
    }.count
    XCTAssertGreaterThan(versionCountBeforeDeletion, 0)

    let deletion = try XCTUnwrap(store.deleteActiveProfile())

    XCTAssertEqual(store.activeProfileID, fallbackProfileID)
    XCTAssertFalse(deletion.draftVersions.contains {
      retainedGeneralIDs.contains($0.draftID)
    })
    XCTAssertEqual(
      store.drafts.first { $0.id == retainedGeneralDraft.id }?.siteProfileID,
      fallbackProfileID
    )
    XCTAssertEqual(
      store.recycledDrafts.first { $0.id == recycledGeneralDraft.id }?.draft.siteProfileID,
      fallbackProfileID
    )
    XCTAssertEqual(
      store.draftVersions.filter { retainedGeneralIDs.contains($0.draftID) }.count,
      versionCountBeforeDeletion
    )
    XCTAssertFalse(store.draftVersions.contains {
      ($0.draftID == retainedGeneralDraft.id || $0.draftID == recycledGeneralDraft.id)
        && $0.draft.siteProfileID == deletedProfile.id
    })
    XCTAssertTrue(
      store.flushPendingChanges(),
      store.lastSaveError ?? "general draft rebinding failed without an error"
    )
  }

  func testDeletingFormerProfileRebindsMovedSiteDraftHistoryToCurrentSite() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftRecoveryMovedSiteHistory")
    let targetProfileID = store.activeProfileID
    let sourceProfile = store.createProfile(named: "历史来源站点")
    store.createDraft()
    var sourceDraft = try XCTUnwrap(store.selectedDraft)
    sourceDraft.title = "跨站点历史重绑"
    sourceDraft.slug = "moved-site-history-\(UUID().uuidString.lowercased())"
    store.updateDraft(sourceDraft)
    XCTAssertTrue(store.createManualVersion(for: sourceDraft.id))
    XCTAssertTrue(store.draftVersions.contains {
      $0.draftID == sourceDraft.id
        && $0.draft.belongs(toSiteProfileID: sourceProfile.id)
    })

    let movePlan = store.draftOwnershipTransferPlan(
      draftIDs: [sourceDraft.id],
      operation: .moveToSite,
      targetProfileID: targetProfileID
    )
    XCTAssertNotNil(store.applyDraftOwnershipTransfer(movePlan))
    XCTAssertEqual(store.selectedDraft?.scope, .site(targetProfileID))
    let versionCountBeforeDeletion = store.draftVersions.filter {
      $0.draftID == sourceDraft.id
    }.count

    store.selectProfile(sourceProfile.id)
    let deletion = try XCTUnwrap(store.deleteActiveProfile())

    XCTAssertFalse(deletion.draftVersions.contains { $0.draftID == sourceDraft.id })
    XCTAssertEqual(
      store.draftVersions.filter { $0.draftID == sourceDraft.id }.count,
      versionCountBeforeDeletion
    )
    XCTAssertTrue(store.draftVersions
      .filter { $0.draftID == sourceDraft.id }
      .allSatisfy {
        $0.draft.siteProfileID == targetProfileID
          && $0.draft.scope == .site(targetProfileID)
      })
    XCTAssertTrue(
      store.flushPendingChanges(),
      store.lastSaveError ?? "moved site history rebinding failed without an error"
    )
  }

  func testRestoringSiteDraftAfterItsProfileWasDeletedCreatesGeneralDraft() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftRecoveryDeletedProfile")
    let fallbackProfileID = store.activeProfileID
    let deletedProfile = store.createProfile(named: "即将删除的站点")
    store.createDraft()
    let deletedSiteDraft = try XCTUnwrap(store.selectedDraft)
    XCTAssertEqual(deletedSiteDraft.scope, .site(deletedProfile.id))

    _ = store.stageDraftBody(
      "这段未保存内容必须在删除站点后仍可恢复。",
      for: deletedSiteDraft.id,
      baseRevision: 0
    )
    let recovery = try XCTUnwrap(store.draftRecoveryRecords[deletedSiteDraft.id])

    _ = store.deleteActiveProfile()
    XCTAssertFalse(store.profiles.contains { $0.id == deletedProfile.id })
    XCTAssertEqual(store.activeProfileID, fallbackProfileID)
    XCTAssertTrue(
      store.restoreDraftRecovery(recovery),
      store.lastSaveError ?? "restoreDraftRecovery failed without a persistence error"
    )

    let restored = try XCTUnwrap(store.selectedDraft)
    XCTAssertNotEqual(restored.id, deletedSiteDraft.id)
    XCTAssertTrue(restored.isGeneralDraft)
    XCTAssertEqual(restored.siteProfileID, fallbackProfileID)
    XCTAssertEqual(
      restored.bodyMarkdown,
      "这段未保存内容必须在删除站点后仍可恢复。"
    )
    XCTAssertNil(restored.repositoryPath)
    XCTAssertNil(restored.repositorySHA)
    XCTAssertNil(restored.repositoryImportFingerprint)
    XCTAssertTrue(store.pendingDraftRecoveries.isEmpty)
  }

  func testRestoredGeneralDraftIsDurableBeforeRecoveryRecordIsRemoved() throws {
    let persistenceURL = try TestWorkbenchFactory.temporaryPersistenceURL(
      prefix: "DraftRecoveryDurableRestore"
    )
    let directoryURL = persistenceURL.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    let store = WorkbenchStore(persistence: persistence, safeMode: true)
    _ = store.createProfile(named: "待删除站点")
    store.createDraft()
    let draft = try XCTUnwrap(store.selectedDraft)
    _ = store.stageDraftBody("必须先持久化再删除恢复记录。", for: draft.id, baseRevision: 0)
    let recovery = try XCTUnwrap(store.draftRecoveryRecords[draft.id])
    _ = store.deleteActiveProfile()

    XCTAssertTrue(
      store.restoreDraftRecovery(recovery),
      store.lastSaveError ?? "restoreDraftRecovery failed without a persistence error"
    )
    let restoredID = try XCTUnwrap(store.selectedDraft?.id)
    let reloaded = WorkbenchStore(persistence: persistence, safeMode: true)
    let durableDraft = try XCTUnwrap(reloaded.drafts.first { $0.id == restoredID })
    XCTAssertTrue(durableDraft.isGeneralDraft)
    XCTAssertEqual(durableDraft.bodyMarkdown, "必须先持久化再删除恢复记录。")
    XCTAssertTrue(reloaded.pendingDraftRecoveries.isEmpty)
  }

  func testRecoveryTitleSuffixesResolveInEnglish() {
    let english = Locale(identifier: "en")
    XCTAssertEqual(CoreL10n.text("（恢复副本）", locale: english), " (Recovered Copy)")
    XCTAssertEqual(CoreL10n.text("（恢复草稿）", locale: english), " (Recovered Draft)")
  }
}
