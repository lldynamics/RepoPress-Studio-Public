import Combine
import PublishingBackupCore
import PublishingDomainContracts
import XCTest

@testable import PublishingKnowledgeCore
@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchDataManagementFeatureFacadeTests: XCTestCase {
  func testFacadeIsStableAndIgnoresUnrelatedRootActivity() throws {
    let store = makeIsolatedStore()
    let facade = store.dataManagement
    XCTAssertTrue(facade === store.dataManagement)

    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    store.setPublishActionMessage("unrelated publish progress", status: .information)
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.bodyMarkdown = "Body-only autosave should not redraw data management."
    store.updateDraft(draft)

    XCTAssertEqual(changes, 0)
    withExtendedLifetime(cancellable) {}
  }

  func testFacadeNotifiesWhenRenderedCountsChange() {
    let store = makeIsolatedStore()
    let facade = store.dataManagement
    let initialCount = facade.draftCount
    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    var addedDraft = ArticleDraft.empty(profile: store.activeProfile)
    addedDraft.title = "Data management count"
    store.setDrafts(store.drafts + [addedDraft])

    XCTAssertEqual(facade.draftCount, initialCount + 1)
    XCTAssertEqual(changes, 1)
    withExtendedLifetime(cancellable) {}
  }

  func testFacadeTracksKnowledgeBusyStateWithoutRootObservation() {
    let store = makeIsolatedStore()
    let facade = store.dataManagement
    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    store.knowledge.isBusy = true

    XCTAssertTrue(facade.isKnowledgeBusy)
    XCTAssertEqual(changes, 1)
    withExtendedLifetime(cancellable) {}
  }

  func testFacadeRestoresSelectedBackupArticleIntoGeneralDraftsAndPersistsIt() async throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "DataManagementArticleRestore")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceAttachmentURL = rootURL.appendingPathComponent("source-image.png")
    let attachmentBytes = Data("restored attachment".utf8)
    try attachmentBytes.write(to: sourceAttachmentURL)
    let sourceProfile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "source-image.png",
      relativePublishPath: "/images/source-image.png",
      repositoryPath: "static/images/source-image.png",
      sourceFilePath: sourceAttachmentURL.path,
      repositorySHA: "remote-sha",
      remoteObjectKey: "remote-image",
      remoteURL: "https://example.invalid/source-image.png",
      remoteETag: "remote-etag"
    )
    let archivedDraft = ArticleDraft(
      siteProfileID: sourceProfile.id,
      title: "从备份恢复的文章",
      slug: "restored-article",
      visibility: .private,
      coverAttachmentID: attachment.id,
      bodyMarkdown: "![图片](/images/source-image.png)",
      attachments: [attachment],
      status: .published,
      repositoryPath: "content/restored-article.md",
      repositorySHA: "published-sha",
      softwareGuideID: "built-in-guide"
    )
    let archiveURL = rootURL.appendingPathComponent("source.psworkspacebackup")
    _ = try WorkspaceBackupService().createBackup(
      at: archiveURL,
      snapshot: WorkbenchSnapshot(
        profiles: [sourceProfile],
        activeProfileID: sourceProfile.id,
        drafts: [archivedDraft],
        releaseRecords: []
      ),
      knowledgeRootURL: rootURL.appendingPathComponent("SourceKnowledgeLibrary"),
      applicationVersion: "test"
    )

    let persistenceURL = rootURL.appendingPathComponent("Target/workbench.json")
    let attachmentRootURL = rootURL.appendingPathComponent("Target/ManagedAttachments")
    let store = makeIsolatedStore(
      persistenceURL: persistenceURL,
      attachmentRootURL: attachmentRootURL
    )
    var targetProfile = store.activeProfile
    let repositoryURL = rootURL.appendingPathComponent("Target/Repository")
    try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
    let sentinelURL = repositoryURL.appendingPathComponent("unchanged.txt")
    try Data("repository must not be written".utf8).write(to: sentinelURL)
    targetProfile.localRepositoryRootPath = repositoryURL.path
    store.setProfiles([targetProfile])
    let existingDraft = ArticleDraft.empty(profile: targetProfile)
    var existingContent = existingDraft
    existingContent.title = "现有草稿"
    existingContent.bodyMarkdown = "Existing content must remain."
    store.setDrafts([existingContent])

    let facade = store.dataManagement
    let preview = try await facade.workspaceBackupArticleSelectionPreview(from: archiveURL)
    XCTAssertEqual(preview.articles.map(\.id), [archivedDraft.id])
    let restoredCount = try await facade.restoreWorkspaceBackupArticles(
      preview: preview,
      selectedDraftIDs: [archivedDraft.id]
    )
    XCTAssertEqual(restoredCount, 1)

    XCTAssertEqual(store.drafts.count, 2)
    XCTAssertEqual(
      store.drafts.first(where: { $0.id == existingContent.id })?.bodyMarkdown,
      existingContent.bodyMarkdown)
    let restored = try XCTUnwrap(store.drafts.first { $0.id != existingContent.id })
    XCTAssertEqual(restored.scope, .general)
    XCTAssertEqual(restored.siteProfileID, targetProfile.id)
    XCTAssertEqual(restored.status, .draft)
    XCTAssertEqual(restored.bodyMarkdown, archivedDraft.bodyMarkdown)
    XCTAssertEqual(restored.visibility, .private)
    XCTAssertNil(restored.repositoryPath)
    XCTAssertNil(restored.repositorySHA)
    XCTAssertNil(restored.softwareGuideID)
    let restoredAttachment = try XCTUnwrap(restored.attachments.first)
    XCTAssertEqual(restored.coverAttachmentID, restoredAttachment.id)
    XCTAssertNil(restoredAttachment.repositorySHA)
    XCTAssertNil(restoredAttachment.remoteObjectKey)
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(restoredAttachment.sourceFilePath))),
      attachmentBytes
    )
    XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("repository must not be written".utf8))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: repositoryURL.path), ["unchanged.txt"])

    let reloaded = makeIsolatedStore(
      persistenceURL: persistenceURL,
      attachmentRootURL: attachmentRootURL
    )
    XCTAssertEqual(reloaded.drafts.count, 2)
    XCTAssertEqual(
      reloaded.drafts.first(where: { $0.id == existingContent.id })?.bodyMarkdown,
      existingContent.bodyMarkdown)
    XCTAssertEqual(
      reloaded.drafts.first(where: { $0.title == archivedDraft.title })?.scope, .general)
  }

  func testFacadeArticleRestoreRejectsQuickHideAndRecoveryWriteProtection() async throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "DataManagementArticleRestoreGuards")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = SiteProfile.defaultProfile
    let archivedDraft = ArticleDraft(siteProfileID: profile.id, title: "受保护操作")
    let archiveURL = rootURL.appendingPathComponent("source.psworkspacebackup")
    _ = try WorkspaceBackupService().createBackup(
      at: archiveURL,
      snapshot: WorkbenchSnapshot(
        profiles: [profile], activeProfileID: profile.id, drafts: [archivedDraft],
        releaseRecords: []
      ),
      knowledgeRootURL: rootURL.appendingPathComponent("KnowledgeLibrary"),
      applicationVersion: "test"
    )
    let store = makeIsolatedStore(
      persistenceURL: rootURL.appendingPathComponent("Target/workbench.json"),
      attachmentRootURL: rootURL.appendingPathComponent("Target/ManagedAttachments")
    )
    let facade = store.dataManagement
    let preview = try await facade.workspaceBackupArticleSelectionPreview(from: archiveURL)
    let initialDrafts = store.drafts

    store.activateQuickHide(reason: "test")
    await assertUnavailableArticleRestore {
      _ = try await facade.restoreWorkspaceBackupArticles(
        preview: preview,
        selectedDraftIDs: [archivedDraft.id]
      )
    }
    XCTAssertEqual(store.drafts, initialDrafts)

    store.deactivateQuickHide()
    store.persistenceStore.protectWritesForUnrecoverableSnapshot(message: "test protection")
    await assertUnavailableArticleRestore {
      _ = try await facade.workspaceBackupArticleSelectionPreview(from: archiveURL)
    }
    XCTAssertEqual(store.drafts, initialDrafts)
  }

  func testFacadeArticleRestoreRollsBackMemoryWhenPrimaryPersistenceFails() async throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "DataManagementArticleRestoreSaveFailure")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = SiteProfile.defaultProfile
    let existingDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "已持久化的原始草稿",
      bodyMarkdown: "Original content"
    )
    let persistenceURL = rootURL.appendingPathComponent("Target/workbench.json")
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    _ = try persistence.save(
      WorkbenchSnapshot(
        profiles: [profile], activeProfileID: profile.id, drafts: [existingDraft],
        releaseRecords: []
      )
    )
    let attachmentRootURL = rootURL.appendingPathComponent("Target/ManagedAttachments")
    let store = WorkbenchStore(
      persistence: persistence,
      safeMode: true,
      managedAttachmentFileStore: ManagedAttachmentFileStore(rootDirectoryURL: attachmentRootURL)
    )
    let sourceAttachmentURL = rootURL.appendingPathComponent("source.bin")
    let attachmentBytes = Data("must remain after uncertain persistence".utf8)
    try attachmentBytes.write(to: sourceAttachmentURL)
    let attachment = DraftAttachment(
      originalFilename: "source.bin",
      relativePublishPath: "/files/source.bin",
      repositoryPath: "static/files/source.bin",
      sourceFilePath: sourceAttachmentURL.path
    )
    let archivedDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "不能写入的恢复草稿",
      coverAttachmentID: attachment.id,
      attachments: [attachment]
    )
    let archiveURL = rootURL.appendingPathComponent("source.psworkspacebackup")
    _ = try WorkspaceBackupService().createBackup(
      at: archiveURL,
      snapshot: WorkbenchSnapshot(
        profiles: [profile], activeProfileID: profile.id, drafts: [archivedDraft],
        releaseRecords: []
      ),
      knowledgeRootURL: rootURL.appendingPathComponent("KnowledgeLibrary"),
      applicationVersion: "test"
    )
    let preservedPrimaryURL = rootURL.appendingPathComponent("preserved-workbench.json")
    let previousDrafts = store.drafts
    try FileManager.default.moveItem(at: persistenceURL, to: preservedPrimaryURL)
    try FileManager.default.createDirectory(at: persistenceURL, withIntermediateDirectories: false)

    let preview = try await store.dataManagement.workspaceBackupArticleSelectionPreview(
      from: archiveURL)
    await assertPersistenceFailedArticleRestore {
      _ = try await store.dataManagement.restoreWorkspaceBackupArticles(
        preview: preview,
        selectedDraftIDs: [archivedDraft.id]
      )
    }

    XCTAssertEqual(store.drafts, previousDrafts)
    XCTAssertTrue(store.isPersistenceRecoveryWriteProtected)
    XCTAssertTrue(FileManager.default.fileExists(atPath: preservedPrimaryURL.path))
    let promotedDirectories = try FileManager.default.contentsOfDirectory(
      at: attachmentRootURL,
      includingPropertiesForKeys: [.isDirectoryKey]
    )
    XCTAssertEqual(promotedDirectories.count, 1)
    let copiedFiles = try FileManager.default.contentsOfDirectory(
      at: try XCTUnwrap(promotedDirectories.first),
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(copiedFiles.count, 1)
    XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(copiedFiles.first)), attachmentBytes)
  }

  private func makeIsolatedStore() -> WorkbenchStore {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("data-management-facade-\(UUID().uuidString).json")
    return WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: fileURL),
      safeMode: true
    )
  }

  private func makeIsolatedStore(
    persistenceURL: URL,
    attachmentRootURL: URL
  ) -> WorkbenchStore {
    WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      safeMode: true,
      managedAttachmentFileStore: ManagedAttachmentFileStore(rootDirectoryURL: attachmentRootURL)
    )
  }

  private func assertUnavailableArticleRestore(
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("article restore unexpectedly succeeded")
    } catch let error as WorkspaceBackupArticleRestoreError {
      guard case .unavailable = error else {
        return XCTFail("unexpected article restore error: \(error)")
      }
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  private func assertPersistenceFailedArticleRestore(
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("article restore unexpectedly succeeded")
    } catch let error as WorkspaceBackupArticleRestoreError {
      guard case .persistenceFailed = error else {
        return XCTFail("unexpected article restore error: \(error)")
      }
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }
}
