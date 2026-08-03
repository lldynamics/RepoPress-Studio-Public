import XCTest
@testable import PublishingWorkbenchCore

final class WorkspaceBackupServiceTests: XCTestCase {
  func testBackupIncludesWorkspaceStateAndDoesNotEmbedSourceAbsolutePaths() throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "WorkspaceBackup")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let sourceURL = rootURL.appendingPathComponent("source-image.png")
    try Data("image-bytes".utf8).write(to: sourceURL)
    let profile = SiteProfile.defaultProfile
    var draft = ArticleDraft.empty(profile: profile)
    draft.title = "完整备份测试"
    draft.bodyMarkdown = "# 正文"
    draft.attachments = [
      DraftAttachment(
        originalFilename: "source-image.png",
        relativePublishPath: "/images/source-image.png",
        repositoryPath: "static/images/source-image.png",
        sourceFilePath: sourceURL.path
      )
    ]
    let historicalDraft = ArticleDraft(
      id: draft.id,
      siteProfileID: profile.id,
      title: "历史版本",
      slug: "history",
      bodyMarkdown: "# 旧正文"
    )
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [draft],
      draftVersions: [
        DraftVersionSnapshot(draft: historicalDraft, reason: .manual)
      ],
      releaseRecords: [
        ReleaseRecord(title: "测试发布", summary: "已记录")
      ]
    )
    let archiveURL = rootURL.appendingPathComponent("workspace.psworkspacebackup")
    let service = WorkspaceBackupService()

    let preview = try service.createBackup(
      at: archiveURL,
      snapshot: snapshot,
      knowledgeRootURL: rootURL.appendingPathComponent("KnowledgeLibrary"),
      applicationVersion: "test"
    )

    XCTAssertFalse(preview.includesAPIKeys)
    XCTAssertEqual(preview.profileCount, 1)
    XCTAssertEqual(preview.draftCount, 1)
    XCTAssertEqual(preview.draftVersionCount, 1)
    XCTAssertEqual(preview.releaseRecordCount, 1)
    XCTAssertEqual(preview.attachmentReferenceCount, 1)

    let workbenchData = try Data(
      contentsOf: archiveURL.appendingPathComponent(WorkspaceBackupService.workbenchRelativePath)
    )
    let workbenchText = String(decoding: workbenchData, as: UTF8.self)
    XCTAssertFalse(workbenchText.contains(sourceURL.path))
    let archivedSnapshot = try JSONDecoder.workbench.decode(
      WorkbenchSnapshot.self,
      from: workbenchData
    )
    let archivedAttachmentPath = try XCTUnwrap(
      archivedSnapshot.drafts.first?.attachments.first?.sourceFilePath
    )
    XCTAssertTrue(archivedAttachmentPath.hasPrefix(WorkspaceBackupService.attachmentMarkerPrefix))

    let manifestData = try Data(
      contentsOf: archiveURL.appendingPathComponent(WorkspaceBackupService.manifestFileName)
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(WorkspaceBackupManifest.self, from: manifestData)
    XCTAssertFalse(manifest.includesAPIKeys)
    XCTAssertEqual(manifest.fileCount, manifest.files.count)
    XCTAssertEqual(manifest.totalByteCount, preview.totalByteCount)
    XCTAssertTrue(manifest.files.contains { $0.relativePath.hasPrefix("knowledge.pslibrarybackup/") })

    let inspected = try service.inspectBackup(at: archiveURL)
    XCTAssertEqual(inspected, preview)
  }

  func testTamperedWorkspaceBackupIsRejectedByChecksumValidation() throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "WorkspaceBackupTamper")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let profile = SiteProfile.defaultProfile
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [ArticleDraft.empty(profile: profile)],
      releaseRecords: []
    )
    let archiveURL = rootURL.appendingPathComponent("workspace.psworkspacebackup")
    let service = WorkspaceBackupService()
    _ = try service.createBackup(
      at: archiveURL,
      snapshot: snapshot,
      knowledgeRootURL: rootURL.appendingPathComponent("KnowledgeLibrary"),
      applicationVersion: "test"
    )

    let workbenchURL = archiveURL.appendingPathComponent(WorkspaceBackupService.workbenchRelativePath)
    let originalWorkbenchData = try Data(contentsOf: workbenchURL)
    var tamperedWorkbenchData = originalWorkbenchData
    tamperedWorkbenchData[tamperedWorkbenchData.index(before: tamperedWorkbenchData.endIndex)] ^= 0x01
    try tamperedWorkbenchData.write(to: workbenchURL, options: .atomic)

    XCTAssertThrowsError(try service.inspectBackup(at: archiveURL)) { error in
      guard case WorkspaceBackupError.checksumMismatch = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testWorkspaceBackupRejectsManifestThatClaimsAPIKeys() throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "WorkspaceBackupAPIKeys")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let profile = SiteProfile.defaultProfile
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [],
      releaseRecords: []
    )
    let archiveURL = rootURL.appendingPathComponent("workspace.psworkspacebackup")
    let service = WorkspaceBackupService()
    _ = try service.createBackup(
      at: archiveURL,
      snapshot: snapshot,
      knowledgeRootURL: rootURL.appendingPathComponent("KnowledgeLibrary"),
      applicationVersion: "test"
    )

    let manifestURL = archiveURL.appendingPathComponent(WorkspaceBackupService.manifestFileName)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var manifest = try decoder.decode(
      WorkspaceBackupManifest.self,
      from: Data(contentsOf: manifestURL)
    )
    manifest.includesAPIKeys = true
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

    XCTAssertThrowsError(try service.inspectBackup(at: archiveURL)) { error in
      guard case WorkspaceBackupError.apiKeysNotAllowed = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testWorkspaceBackupReportsApplicationVersionCompatibility() throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "WorkspaceBackupCompatibility")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let profile = SiteProfile.defaultProfile
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [],
      releaseRecords: []
    )
    let archiveURL = rootURL.appendingPathComponent("workspace.psworkspacebackup")
    let service = WorkspaceBackupService()
    let created = try service.createBackup(
      at: archiveURL,
      snapshot: snapshot,
      knowledgeRootURL: rootURL.appendingPathComponent("KnowledgeLibrary"),
      applicationVersion: "1.4.0",
      currentApplicationVersion: "1.5.0"
    )
    XCTAssertEqual(created.compatibility, .createdByOlderApplication)

    let newer = try service.inspectBackup(at: archiveURL, currentApplicationVersion: "1.3.0")
    XCTAssertEqual(newer.compatibility, .createdByNewerApplication)
    let same = try service.inspectBackup(at: archiveURL, currentApplicationVersion: "1.4")
    XCTAssertEqual(same.compatibility, .compatible)
  }

  func testStagedRestoreInstallsSnapshotAndRewritesAttachmentPath() throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "WorkspaceBackupRestore")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let sourceRootURL = rootURL.appendingPathComponent("Source")
    let targetRootURL = rootURL.appendingPathComponent("Target")
    try FileManager.default.createDirectory(at: sourceRootURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: targetRootURL, withIntermediateDirectories: true)

    let sourceAttachmentURL = sourceRootURL.appendingPathComponent("source.mov")
    try Data("video-bytes".utf8).write(to: sourceAttachmentURL)
    let profile = SiteProfile.defaultProfile
    var restoredDraft = ArticleDraft.empty(profile: profile)
    restoredDraft.title = "待恢复工作区"
    restoredDraft.attachments = [
      DraftAttachment(
        originalFilename: "source.mov",
        relativePublishPath: "/videos/source.mov",
        repositoryPath: "static/videos/source.mov",
        sourceFilePath: sourceAttachmentURL.path
      )
    ]
    let sourceSnapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [restoredDraft],
      releaseRecords: []
    )
    let archiveURL = sourceRootURL.appendingPathComponent("workspace.psworkspacebackup")
    let service = WorkspaceBackupService()
    _ = try service.createBackup(
      at: archiveURL,
      snapshot: sourceSnapshot,
      knowledgeRootURL: sourceRootURL.appendingPathComponent("KnowledgeLibrary"),
      applicationVersion: "test"
    )

    let targetPersistenceURL = targetRootURL.appendingPathComponent("workbench.json")
    let oldSnapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [ArticleDraft.empty(profile: profile)],
      releaseRecords: []
    )
    let targetPersistence = WorkbenchPersistence(fileURL: targetPersistenceURL)
    _ = try targetPersistence.save(oldSnapshot)
    let oldDraftRecoveryData = Data("restore-before-draft-recovery".utf8)
    try oldDraftRecoveryData.write(to: targetPersistence.draftRecoveryJournalURL)
    let targetKnowledgeURL = targetRootURL.appendingPathComponent("KnowledgeLibrary")
    let targetAttachmentURL = targetRootURL.appendingPathComponent("ManagedAttachments")
    try FileManager.default.createDirectory(at: targetAttachmentURL, withIntermediateDirectories: true)
    try Data("old-attachment".utf8).write(
      to: targetAttachmentURL.appendingPathComponent("old.txt")
    )

    _ = try service.stageRestore(
      from: archiveURL,
      persistenceFileURL: targetPersistenceURL
    )
    let outcome = WorkspaceBackupService.applyPendingRestoreIfNeeded(
      persistenceFileURL: targetPersistenceURL,
      knowledgeRootURL: targetKnowledgeURL,
      attachmentRootURL: targetAttachmentURL
    )

    guard case .restored(let result) = outcome else {
      return XCTFail("workspace restore did not complete: \(outcome)")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.recoveryURL.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: targetPersistence.draftRecoveryJournalURL.path)
    )
    XCTAssertEqual(
      try Data(contentsOf: result.recoveryURL.appendingPathComponent("draft-recovery.json")),
      oldDraftRecoveryData
    )
    let loaded = try XCTUnwrap(WorkbenchPersistence(fileURL: targetPersistenceURL).load())
    XCTAssertEqual(loaded.drafts.first?.title, "待恢复工作区")
    let restoredSourcePath = try XCTUnwrap(loaded.drafts.first?.attachments.first?.sourceFilePath)
    XCTAssertTrue(restoredSourcePath.hasPrefix(targetAttachmentURL.path))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: restoredSourcePath)), Data("video-bytes".utf8))
    XCTAssertTrue(FileManager.default.fileExists(atPath: targetKnowledgeURL.appendingPathComponent("library.sqlite").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: WorkspaceBackupService.pendingRestoreURL(for: targetPersistenceURL).path
      )
    )
  }

  func testV2BackupIncludesInspectsAndRestoresRSSSnapshot() throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "WorkspaceBackupRSSV2"
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let sourceRootURL = rootURL.appendingPathComponent("Source", isDirectory: true)
    let targetRootURL = rootURL.appendingPathComponent("Target", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceRootURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: targetRootURL, withIntermediateDirectories: true)

    let sourceRSSURL = sourceRootURL
      .appendingPathComponent("RSSReader", isDirectory: true)
      .appendingPathComponent("reader.sqlite")
    let sourceDatabase = try populatedRSSDatabase(
      at: sourceRSSURL,
      feedTitle: "需要恢复的 RSS",
      articleID: "source-rss-article"
    )
    let profile = SiteProfile.defaultProfile
    let sourceSnapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [],
      releaseRecords: []
    )
    let archiveURL = sourceRootURL.appendingPathComponent("workspace.psworkspacebackup")
    let service = WorkspaceBackupService()

    let created = try withExtendedLifetime(sourceDatabase) {
      try service.createBackup(
        at: archiveURL,
        snapshot: sourceSnapshot,
        knowledgeRootURL: sourceRootURL.appendingPathComponent("KnowledgeLibrary"),
        rssDatabaseURL: sourceRSSURL,
        applicationVersion: "test"
      )
    }

    XCTAssertEqual(created.formatVersion, WorkspaceBackupManifest.currentFormatVersion)
    let rssComponent = try XCTUnwrap(
      created.components.first { $0.component == .rssReader }
    )
    XCTAssertEqual(rssComponent.fileCount, 1)
    XCTAssertGreaterThan(rssComponent.byteCount, 0)
    let archivedRSSURL = archiveURL.appendingPathComponent(
      WorkspaceBackupService.rssDatabaseRelativePath
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: archivedRSSURL.path))
    let archivedRSS = try RSSReaderBackupService().inspectBackup(at: archivedRSSURL)
    XCTAssertEqual(archivedRSS.feedCount, 1)
    XCTAssertEqual(archivedRSS.articleCount, 1)
    XCTAssertEqual(archivedRSS.highlightCount, 1)
    XCTAssertEqual(archivedRSS.indexedArticleCount, 1)
    XCTAssertEqual(try service.inspectBackup(at: archiveURL), created)

    let targetPersistenceURL = targetRootURL.appendingPathComponent("workbench.json")
    _ = try WorkbenchPersistence(fileURL: targetPersistenceURL).save(sourceSnapshot)
    let targetRSSURL = targetRootURL
      .appendingPathComponent("RSSReader", isDirectory: true)
      .appendingPathComponent("reader.sqlite")
    try writePopulatedRSSDatabase(
      at: targetRSSURL,
      feedTitle: "恢复前的 RSS",
      articleID: "old-rss-article"
    )
    let targetKnowledgeURL = targetRootURL.appendingPathComponent(
      "KnowledgeLibrary",
      isDirectory: true
    )
    let targetAttachmentURL = targetRootURL.appendingPathComponent(
      "ManagedAttachments",
      isDirectory: true
    )

    _ = try service.stageRestore(
      from: archiveURL,
      persistenceFileURL: targetPersistenceURL
    )
    let outcome = WorkspaceBackupService.applyPendingRestoreIfNeeded(
      persistenceFileURL: targetPersistenceURL,
      knowledgeRootURL: targetKnowledgeURL,
      rssDatabaseURL: targetRSSURL,
      attachmentRootURL: targetAttachmentURL
    )

    guard case .restored(let result) = outcome else {
      return XCTFail("workspace v2 restore did not complete: \(outcome)")
    }
    XCTAssertEqual(result.restoredPreview.formatVersion, 2)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: result.recoveryURL
          .appendingPathComponent("RSSReader/reader.sqlite")
          .path
      )
    )
    let restoredRSS = try RSSReaderBackupService().inspectBackup(at: targetRSSURL)
    XCTAssertEqual(restoredRSS, archivedRSS)
    let restoredDatabase = try RSSReaderDatabase(fileURL: targetRSSURL)
    XCTAssertEqual(try restoredDatabase.feeds().map(\.title), ["需要恢复的 RSS"])
    XCTAssertEqual(try restoredDatabase.articles().map(\.id), ["source-rss-article"])
    XCTAssertEqual(try restoredDatabase.highlights().map(\.note), ["RSS 备份恢复测试"])
  }

  func testV1RestoreDoesNotTouchExistingRSSDatabase() throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "WorkspaceBackupRSSV1"
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let sourceRootURL = rootURL.appendingPathComponent("Source", isDirectory: true)
    let targetRootURL = rootURL.appendingPathComponent("Target", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceRootURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: targetRootURL, withIntermediateDirectories: true)

    let profile = SiteProfile.defaultProfile
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [],
      releaseRecords: []
    )
    let archiveURL = sourceRootURL.appendingPathComponent("workspace.psworkspacebackup")
    let service = WorkspaceBackupService()
    let created = try service.createBackup(
      at: archiveURL,
      snapshot: snapshot,
      knowledgeRootURL: sourceRootURL.appendingPathComponent("KnowledgeLibrary"),
      applicationVersion: "test"
    )

    XCTAssertEqual(created.formatVersion, WorkspaceBackupManifest.minimumSupportedFormatVersion)
    XCTAssertFalse(created.components.contains { $0.component == .rssReader })
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: archiveURL
          .appendingPathComponent(WorkspaceBackupService.rssDatabaseRelativePath)
          .path
      )
    )
    XCTAssertEqual(try service.inspectBackup(at: archiveURL), created)

    let targetPersistenceURL = targetRootURL.appendingPathComponent("workbench.json")
    _ = try WorkbenchPersistence(fileURL: targetPersistenceURL).save(snapshot)
    let targetRSSURL = targetRootURL
      .appendingPathComponent("RSSReader", isDirectory: true)
      .appendingPathComponent("reader.sqlite")
    try writePopulatedRSSDatabase(
      at: targetRSSURL,
      feedTitle: "必须保留的 RSS",
      articleID: "preserved-rss-article"
    )
    let targetKnowledgeURL = targetRootURL.appendingPathComponent(
      "KnowledgeLibrary",
      isDirectory: true
    )
    let targetAttachmentURL = targetRootURL.appendingPathComponent(
      "ManagedAttachments",
      isDirectory: true
    )

    _ = try service.stageRestore(
      from: archiveURL,
      persistenceFileURL: targetPersistenceURL
    )
    let outcome = WorkspaceBackupService.applyPendingRestoreIfNeeded(
      persistenceFileURL: targetPersistenceURL,
      knowledgeRootURL: targetKnowledgeURL,
      rssDatabaseURL: targetRSSURL,
      attachmentRootURL: targetAttachmentURL
    )

    guard case .restored(let result) = outcome else {
      return XCTFail("workspace v1 restore did not complete: \(outcome)")
    }
    XCTAssertEqual(result.restoredPreview.formatVersion, 1)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: result.recoveryURL.appendingPathComponent("RSSReader").path
      )
    )
    let preservedDatabase = try RSSReaderDatabase(fileURL: targetRSSURL)
    XCTAssertEqual(try preservedDatabase.feeds().map(\.title), ["必须保留的 RSS"])
    XCTAssertEqual(try preservedDatabase.articles().map(\.id), ["preserved-rss-article"])
    XCTAssertEqual(try preservedDatabase.highlights().map(\.note), ["RSS 备份恢复测试"])
  }

  func testInterruptedRestoreIsRolledBackIdempotentlyOnNextStartup() throws {
    let fixture = try makeRestoreTransactionFixture(prefix: "WorkspaceBackupInterrupted")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let service = WorkspaceBackupService { checkpoint in
      guard checkpoint == .existingDataMoved else { return }
      throw WorkspaceRestoreProcessInterruption()
    }

    XCTAssertThrowsError(
      try service.applyPendingRestore(
        persistenceFileURL: fixture.persistenceURL,
        knowledgeRootURL: fixture.knowledgeURL,
        rssDatabaseURL: fixture.rssURL,
        attachmentRootURL: fixture.attachmentURL,
        currentApplicationVersion: "test"
      )
    ) { error in
      XCTAssertTrue(error is WorkspaceRestoreProcessInterruption)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journalURL.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: fixture.targetRootURL
          .appendingPathComponent(WorkspaceBackupService.restoreTransactionFileName)
          .path
      )
    )

    let recovery = WorkspaceBackupService.recoverInterruptedRestoreIfNeeded(
      persistenceFileURL: fixture.persistenceURL,
      knowledgeRootURL: fixture.knowledgeURL,
      rssDatabaseURL: fixture.rssURL,
      attachmentRootURL: fixture.attachmentURL
    )
    XCTAssertEqual(recovery, .rolledBack)
    try assertOriginalRestoreFixtureWasRecovered(fixture)
    XCTAssertEqual(
      WorkspaceBackupService.recoverInterruptedRestoreIfNeeded(
        persistenceFileURL: fixture.persistenceURL,
        knowledgeRootURL: fixture.knowledgeURL,
        rssDatabaseURL: fixture.rssURL,
        attachmentRootURL: fixture.attachmentURL
      ),
      .none
    )
  }

  func testRestoreFailureRollsDraftRecoveryJournalBackByteForByte() throws {
    let fixture = try makeRestoreTransactionFixture(prefix: "WorkspaceBackupRollback")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let service = WorkspaceBackupService { checkpoint in
      guard checkpoint == .existingDataMoved else { return }
      throw InjectedRestoreFailure.expected
    }

    XCTAssertThrowsError(
      try service.applyPendingRestore(
        persistenceFileURL: fixture.persistenceURL,
        knowledgeRootURL: fixture.knowledgeURL,
        rssDatabaseURL: fixture.rssURL,
        attachmentRootURL: fixture.attachmentURL,
        currentApplicationVersion: "test"
      )
    ) { error in
      guard case WorkspaceBackupError.restoreFailed = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    try assertOriginalRestoreFixtureWasRecovered(fixture)
    XCTAssertEqual(
      WorkspaceBackupService.recoverInterruptedRestoreIfNeeded(
        persistenceFileURL: fixture.persistenceURL,
        knowledgeRootURL: fixture.knowledgeURL,
        rssDatabaseURL: fixture.rssURL,
        attachmentRootURL: fixture.attachmentURL
      ),
      .none
    )
  }

  func testInterruptedAfterNewDataInstallStillRollsBackToOriginalWorkspace() throws {
    let fixture = try makeRestoreTransactionFixture(
      prefix: "WorkspaceBackupInterruptedAfterInstall"
    )
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let service = WorkspaceBackupService { checkpoint in
      guard checkpoint == .newDataInstalled else { return }
      throw WorkspaceRestoreProcessInterruption()
    }

    XCTAssertThrowsError(
      try service.applyPendingRestore(
        persistenceFileURL: fixture.persistenceURL,
        knowledgeRootURL: fixture.knowledgeURL,
        rssDatabaseURL: fixture.rssURL,
        attachmentRootURL: fixture.attachmentURL,
        currentApplicationVersion: "test"
      )
    ) { error in
      XCTAssertTrue(error is WorkspaceRestoreProcessInterruption)
    }
    let installedSnapshot = try XCTUnwrap(
      WorkbenchPersistence(fileURL: fixture.persistenceURL).load()
    )
    XCTAssertEqual(installedSnapshot.drafts.first?.title, "transaction-restored")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journalURL.path))

    XCTAssertEqual(
      WorkspaceBackupService.recoverInterruptedRestoreIfNeeded(
        persistenceFileURL: fixture.persistenceURL,
        knowledgeRootURL: fixture.knowledgeURL,
        rssDatabaseURL: fixture.rssURL,
        attachmentRootURL: fixture.attachmentURL
      ),
      .rolledBack
    )
    try assertOriginalRestoreFixtureWasRecovered(fixture)
  }

  private func populatedRSSDatabase(
    at fileURL: URL,
    feedTitle: String,
    articleID: String
  ) throws -> RSSReaderDatabase {
    let database = try RSSReaderDatabase(fileURL: fileURL)
    let feed = RSSFeed(
      title: feedTitle,
      url: try XCTUnwrap(URL(string: "https://example.com/\(articleID).xml"))
    )
    let article = RSSArticle(
      id: articleID,
      feedID: feed.id,
      title: "RSS 备份文章",
      summaryHTML: "RSS 备份摘要",
      contentHTML: "RSS 备份正文",
      tags: ["资料库"]
    )
    try database.upsertFeed(feed)
    try database.upsertArticles([article])
    try database.saveHighlight(
      RSSArticleHighlight(
        articleID: article.id,
        text: "RSS 备份正文",
        note: "RSS 备份恢复测试",
        tags: ["资料库"]
      )
    )
    return database
  }

  private func writePopulatedRSSDatabase(
    at fileURL: URL,
    feedTitle: String,
    articleID: String
  ) throws {
    _ = try populatedRSSDatabase(
      at: fileURL,
      feedTitle: feedTitle,
      articleID: articleID
    )
  }

  private func makeRestoreTransactionFixture(
    prefix: String
  ) throws -> RestoreTransactionFixture {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: prefix)
    let sourceRootURL = rootURL.appendingPathComponent("Source", isDirectory: true)
    let targetRootURL = rootURL.appendingPathComponent("Target", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceRootURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: targetRootURL, withIntermediateDirectories: true)

    let profile = SiteProfile.defaultProfile
    var restoredDraft = ArticleDraft.empty(profile: profile)
    restoredDraft.title = "transaction-restored"
    let restoredSnapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [restoredDraft],
      releaseRecords: []
    )
    let backupURL = sourceRootURL.appendingPathComponent("workspace.psworkspacebackup")
    let service = WorkspaceBackupService()
    _ = try service.createBackup(
      at: backupURL,
      snapshot: restoredSnapshot,
      knowledgeRootURL: sourceRootURL.appendingPathComponent("KnowledgeLibrary"),
      applicationVersion: "test"
    )

    var originalDraft = ArticleDraft.empty(profile: profile)
    originalDraft.title = "transaction-original"
    let originalSnapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [originalDraft],
      releaseRecords: []
    )
    let persistenceURL = targetRootURL.appendingPathComponent("workbench.json")
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    _ = try persistence.save(originalSnapshot)
    let journalData = Data("original-draft-recovery-journal".utf8)
    try journalData.write(to: persistence.draftRecoveryJournalURL)

    let knowledgeURL = targetRootURL.appendingPathComponent(
      "KnowledgeLibrary",
      isDirectory: true
    )
    _ = try KnowledgeDatabase(fileURL: knowledgeURL.appendingPathComponent("library.sqlite"))
    let attachmentURL = targetRootURL.appendingPathComponent(
      "ManagedAttachments",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: attachmentURL, withIntermediateDirectories: true)
    let attachmentData = Data("original-managed-attachment".utf8)
    try attachmentData.write(to: attachmentURL.appendingPathComponent("original.txt"))

    _ = try service.stageRestore(
      from: backupURL,
      persistenceFileURL: persistenceURL,
      currentApplicationVersion: "test"
    )
    return RestoreTransactionFixture(
      rootURL: rootURL,
      targetRootURL: targetRootURL,
      persistenceURL: persistenceURL,
      knowledgeURL: knowledgeURL,
      rssURL: targetRootURL.appendingPathComponent("RSSReader/reader.sqlite"),
      attachmentURL: attachmentURL,
      journalURL: persistence.draftRecoveryJournalURL,
      journalData: journalData,
      attachmentData: attachmentData
    )
  }

  private func assertOriginalRestoreFixtureWasRecovered(
    _ fixture: RestoreTransactionFixture
  ) throws {
    let snapshot = try XCTUnwrap(WorkbenchPersistence(fileURL: fixture.persistenceURL).load())
    XCTAssertEqual(snapshot.drafts.first?.title, "transaction-original")
    XCTAssertEqual(try Data(contentsOf: fixture.journalURL), fixture.journalData)
    XCTAssertEqual(
      try Data(contentsOf: fixture.attachmentURL.appendingPathComponent("original.txt")),
      fixture.attachmentData
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: WorkspaceBackupService.pendingRestoreURL(for: fixture.persistenceURL).path
      )
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.targetRootURL
          .appendingPathComponent(WorkspaceBackupService.restoreTransactionFileName)
          .path
      )
    )
  }
}

private enum InjectedRestoreFailure: Error {
  case expected
}

private struct RestoreTransactionFixture {
  var rootURL: URL
  var targetRootURL: URL
  var persistenceURL: URL
  var knowledgeURL: URL
  var rssURL: URL
  var attachmentURL: URL
  var journalURL: URL
  var journalData: Data
  var attachmentData: Data
}
