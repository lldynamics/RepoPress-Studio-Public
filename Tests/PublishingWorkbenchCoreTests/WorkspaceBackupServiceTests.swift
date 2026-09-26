import Foundation
import PublishingBackupCore
import PublishingDomainContracts
import XCTest

@testable import PublishingKnowledgeCore
@testable import PublishingWorkbenchCore

final class WorkspaceBackupServiceTests: XCTestCase {
  func testKnowledgeRestoreResetsSyncBaselineBeforeRemoteFetch() async throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "WorkspaceKnowledgeRestoreSync")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let knowledgeRootURL = rootURL.appendingPathComponent("KnowledgeLibrary", isDirectory: true)
    let sidecarURL = rootURL.appendingPathComponent("KnowledgeSync", isDirectory: true)
    let service = KnowledgeLibraryService(rootURL: knowledgeRootURL)
    let oldNote = try service.createNote(KnowledgeNote(title: "Old", markdown: "old"))
    let adapter = KnowledgeNoteCloudSyncAdapter(
      service: service, stateDirectoryURL: sidecarURL)
    try await adapter.savePersistentState(
      .init(
        engineState: Data([1]), boundAccountID: "account", initialFetchComplete: true,
        zoneEstablished: true))

    let backupURL = rootURL.appendingPathComponent("old-workspace.psworkspacebackup")
    _ = try WorkspaceBackupService().createBackup(
      at: backupURL,
      snapshot: WorkbenchSnapshot(
        profiles: [], activeProfileID: UUID(), drafts: [], releaseRecords: []),
      knowledgeRootURL: knowledgeRootURL,
      applicationVersion: "test",
      selectedCategories: [.knowledgeLibrary]
    )

    let oldChanges = try await adapter.localChanges()
    XCTAssertEqual(oldChanges.count, 1)
    await adapter.prepareForSend(oldChanges[0])
    try await adapter.markSent(
      id: oldNote.id, revision: oldChanges[0].revision, systemFields: Data([1]))

    let laterNote = try service.createNote(KnowledgeNote(title: "Later", markdown: "later"))
    let allChanges = try await adapter.localChanges()
    XCTAssertEqual(allChanges.count, 1)
    await adapter.prepareForSend(allChanges[0])
    try await adapter.markSent(
      id: laterNote.id, revision: allChanges[0].revision, systemFields: Data([2]))
    let remoteChanges = oldChanges + allChanges

    let persistenceURL = rootURL.appendingPathComponent("workbench.json")
    _ = try WorkspaceBackupService().stageRestore(
      from: backupURL, persistenceFileURL: persistenceURL)
    _ = try WorkspaceBackupService().applyPendingRestore(
      persistenceFileURL: persistenceURL,
      knowledgeRootURL: knowledgeRootURL,
      rssDatabaseURL: rootURL.appendingPathComponent("RSS/reader.sqlite"),
      attachmentRootURL: rootURL.appendingPathComponent("Attachments"),
      currentApplicationVersion: "test"
    )

    let restoredService = KnowledgeLibraryService(rootURL: knowledgeRootURL)
    let restoredAdapter = KnowledgeNoteCloudSyncAdapter(
      service: restoredService, stateDirectoryURL: sidecarURL)
    let restoredState = try await restoredAdapter.loadPersistentState()
    XCTAssertNil(restoredState.engineState)
    XCTAssertFalse(restoredState.initialFetchComplete)
    XCTAssertEqual(restoredState.boundAccountID, "account")
    XCTAssertTrue(restoredState.zoneEstablished)
    let beforeFetchChanges = try await restoredAdapter.localChanges()
    XCTAssertTrue(beforeFetchChanges.isEmpty)

    for change in remoteChanges {
      guard case .upsert(let remoteNote, let revision, _) = change else {
        return XCTFail("Expected note fixture")
      }
      _ = try await restoredAdapter.applyRemote(
        .note(remoteNote, sha256: revision, systemFields: Data([9])))
    }
    try await restoredAdapter.savePersistentState(
      .init(
        boundAccountID: restoredState.boundAccountID, initialFetchComplete: true,
        zoneEstablished: restoredState.zoneEstablished))
    XCTAssertEqual(try restoredService.note(documentID: laterNote.id)?.markdown, "later")
    let afterFetch = try await restoredAdapter.localChanges()
    XCTAssertFalse(
      afterFetch.contains { change in
        if case .tombstone(let id, _, _, _) = change { return id == laterNote.id }
        return false
      })
  }

  func testV4CategoryBackupStagesOnlySelectedCategoryAndRejectsFullRestore() throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "WorkspaceBackupCategory")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = SiteProfile.defaultProfile
    let snapshot = WorkbenchSnapshot(
      profiles: [profile], activeProfileID: profile.id, drafts: [], releaseRecords: []
    )
    let backupURL = rootURL.appendingPathComponent("partial.psworkspacebackup")
    let service = WorkspaceBackupService()
    let created = try service.createBackup(
      at: backupURL,
      snapshot: snapshot,
      knowledgeRootURL: rootURL.appendingPathComponent("KnowledgeLibrary"),
      applicationVersion: "test",
      selectedCategories: [.workbench]
    )
    let inspected = try service.inspectSelectiveRestore(at: backupURL)
    XCTAssertEqual(created.formatVersion, 4)
    XCTAssertEqual(inspected.availableCategories, [.workbench])
    XCTAssertEqual(inspected.categorySummaries.map(\.category), [.workbench])

    let stagedURL = rootURL.appendingPathComponent("staged.psworkspacebackup")
    let staged = try service.stageSelectiveRestore(
      from: backupURL, categories: [.workbench], to: stagedURL
    )
    XCTAssertEqual(staged.preview.selectedCategories, [.workbench])
    XCTAssertEqual(try service.inspectBackup(at: staged.stagedPackageURL).formatVersion, 4)
    let persistenceURL = rootURL.appendingPathComponent("Live/workbench.json")
    let rssRootURL = rootURL.appendingPathComponent("Live/RSSReader")
    let rssMarkerURL = rssRootURL.appendingPathComponent("preserved.txt")
    try FileManager.default.createDirectory(at: rssRootURL, withIntermediateDirectories: true)
    try Data("keep rss".utf8).write(to: rssMarkerURL)
    _ = try service.stageRestore(from: stagedURL, persistenceFileURL: persistenceURL)
    let outcome = try service.applyPendingRestore(
      persistenceFileURL: persistenceURL,
      knowledgeRootURL: rootURL.appendingPathComponent("Live/KnowledgeLibrary"),
      rssDatabaseURL: rssRootURL.appendingPathComponent(RSSReaderBackupService.databaseFileName),
      attachmentRootURL: rootURL.appendingPathComponent("Live/ManagedAttachments"),
      currentApplicationVersion: "test"
    )
    XCTAssertNotNil(outcome)
    XCTAssertTrue(FileManager.default.fileExists(atPath: rssMarkerURL.path),
      "restoring workbench data must leave unselected RSS data untouched")

    let manifestURL = stagedURL.appendingPathComponent(WorkspaceBackupService.manifestFileName)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var manifest = try decoder.decode(WorkspaceBackupManifest.self, from: Data(contentsOf: manifestURL))
    manifest.selectedCategories = [.knowledgeLibrary]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    XCTAssertThrowsError(try service.inspectBackup(at: stagedURL))
  }

  func testV4OperationHistoryRestoreLeavesWorkbenchAndRSSUntouched() throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "WorkspaceBackupHistoryOnly")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = SiteProfile.defaultProfile
    let originalSnapshot = WorkbenchSnapshot(
      profiles: [profile], activeProfileID: profile.id, drafts: [], releaseRecords: []
    )
    let persistenceURL = rootURL.appendingPathComponent("Live/workbench.json")
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    _ = try persistence.save(originalSnapshot)
    let originalWorkbenchData = try Data(contentsOf: persistenceURL)
    let ledger = WorkbenchOperationLedgerPersistence(fileURL: persistence.operationLedgerURL)
    let oldEvent = WorkbenchOperationEventRecord(kind: .siteImport, outcome: .failed)
    try ledger.save(WorkbenchOperationLedgerDocument(retentionPolicy: .forever, records: [oldEvent]))
    let originalRSSDirectory = rootURL.appendingPathComponent("Live/RSSReader")
    try FileManager.default.createDirectory(at: originalRSSDirectory, withIntermediateDirectories: true)
    let rssSentinel = originalRSSDirectory.appendingPathComponent("unchanged.txt")
    try Data("unchanged".utf8).write(to: rssSentinel)

    let newEvent = WorkbenchOperationEventRecord(kind: .workspaceBackupCreated, outcome: .succeeded)
    let packageURL = rootURL.appendingPathComponent("history.psworkspacebackup")
    let service = WorkspaceBackupService()
    _ = try service.createBackup(
      at: packageURL,
      snapshot: originalSnapshot,
      operationHistoryDocument: WorkbenchOperationLedgerDocument(
        retentionPolicy: .forever, records: [newEvent]
      ),
      knowledgeRootURL: rootURL.appendingPathComponent("KnowledgeLibrary"),
      applicationVersion: "test",
      selectedCategories: [.operationHistory]
    )
    _ = try service.stageRestore(from: packageURL, persistenceFileURL: persistenceURL)
    let result = try XCTUnwrap(service.applyPendingRestore(
      persistenceFileURL: persistenceURL,
      knowledgeRootURL: rootURL.appendingPathComponent("Live/KnowledgeLibrary"),
      rssDatabaseURL: originalRSSDirectory.appendingPathComponent("reader.sqlite"),
      attachmentRootURL: rootURL.appendingPathComponent("Live/ManagedAttachments"),
      currentApplicationVersion: "test"
    ))
    XCTAssertEqual(result.restoredPreview.components.count, WorkspaceBackupComponent.allCases.count)
    XCTAssertEqual(try Data(contentsOf: persistenceURL), originalWorkbenchData)
    XCTAssertTrue(FileManager.default.fileExists(atPath: rssSentinel.path))
    XCTAssertEqual(try ledger.loadWithRecovery().document.records.map(\.id), [newEvent.id])
  }

  func testCancellationAfterBackupCommitStillReturnsCommittedPreview() async throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "WorkspaceBackupCommit")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = SiteProfile.defaultProfile
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [],
      releaseRecords: []
    )
    let destinationURL = rootURL.appendingPathComponent("committed.psworkspacebackup")
    let commitGate = WorkspaceBackupCommitGate()
    let service = WorkspaceBackupService(
      restoreMutationHook: { _ in },
      backupCommitHook: {
        commitGate.signalCommitted()
        commitGate.waitUntilTestReleasesCommit()
      }
    )
    let worker = Task.detached {
      try service.createBackup(
        at: destinationURL,
        snapshot: snapshot,
        knowledgeRootURL: rootURL.appendingPathComponent("KnowledgeLibrary"),
        applicationVersion: "test"
      )
    }

    XCTAssertTrue(commitGate.waitForCommit(timeout: 2))
    worker.cancel()
    commitGate.releaseCommit()
    let result = await worker.result
    guard case .success(let preview) = result else {
      return XCTFail("committed backup must not be reclassified as cancellation")
    }
    XCTAssertEqual(preview.backupURL, destinationURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
    XCTAssertEqual(
      try temporaryEntries(in: rootURL, prefix: ".committed.psworkspacebackup.creating-"), [])
  }

  func testCancelledBackupCleansTemporaryPackageAndDoesNotReplaceDestination() async throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "WorkspaceBackupCancel")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source-image.png")
    try Data(repeating: 0xD2, count: 4 * 1_024 * 1_024).write(to: sourceURL)
    let snapshot = makeCancellationSnapshot(sourceURL: sourceURL)
    let destinationURL = rootURL.appendingPathComponent("existing.psworkspacebackup")
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    let sentinelURL = destinationURL.appendingPathComponent("sentinel.txt")
    try Data("preserve destination".utf8).write(to: sentinelURL)

    let copyGate = WorkspaceBackupCopyGate()
    let service = WorkspaceBackupService(
      fileManager: .default,
      restoreMutationHook: { _ in },
      fileCopyProgressHook: { _, copiedByteCount in
        if copiedByteCount > 0 {
          copyGate.signalCopyStarted()
          copyGate.waitUntilCancellationIsForwarded()
        }
      }
    )
    let worker = Task.detached {
      try service.createBackup(
        at: destinationURL,
        snapshot: snapshot,
        knowledgeRootURL: rootURL.appendingPathComponent("KnowledgeLibrary"),
        applicationVersion: "test"
      )
    }

    XCTAssertTrue(copyGate.waitForCopyStart(timeout: 2))
    let cancellationStartedAt = Date()
    worker.cancel()
    copyGate.allowCancellationToProceed()
    let result = await worker.result
    guard case .failure(let error) = result else {
      return XCTFail("cancelled backup unexpectedly succeeded")
    }
    XCTAssertTrue(error is CancellationError)
    XCTAssertLessThan(Date().timeIntervalSince(cancellationStartedAt), 1)
    XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("preserve destination".utf8))
    XCTAssertEqual(
      try temporaryEntries(in: rootURL, prefix: ".existing.psworkspacebackup.creating-"), [])
  }

  func testCancelledStageRestoreCleansTemporaryContentAndLeavesPendingDestination() async throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "WorkspaceStageCancel")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceFileURL = rootURL.appendingPathComponent("source-image.png")
    try Data(repeating: 0xE1, count: 4 * 1_024 * 1_024).write(to: sourceFileURL)
    let snapshot = makeCancellationSnapshot(sourceURL: sourceFileURL)
    let archiveURL = rootURL.appendingPathComponent("source.psworkspacebackup")
    _ = try WorkspaceBackupService().createBackup(
      at: archiveURL,
      snapshot: snapshot,
      knowledgeRootURL: rootURL.appendingPathComponent("SourceKnowledgeLibrary"),
      applicationVersion: "test"
    )
    let persistenceURL = rootURL.appendingPathComponent("workbench.json")
    let pendingURL = WorkspaceBackupService.pendingRestoreURL(for: persistenceURL)
    try FileManager.default.createDirectory(at: pendingURL, withIntermediateDirectories: true)
    let sentinelURL = pendingURL.appendingPathComponent("sentinel.txt")
    try Data("preserve pending".utf8).write(to: sentinelURL)

    let copyGate = WorkspaceBackupCopyGate()
    let service = WorkspaceBackupService(
      fileManager: .default,
      restoreMutationHook: { _ in },
      fileCopyProgressHook: { _, copiedByteCount in
        if copiedByteCount > 0 {
          copyGate.signalCopyStarted()
          copyGate.waitUntilCancellationIsForwarded()
        }
      }
    )
    let worker = Task.detached {
      try service.stageRestore(from: archiveURL, persistenceFileURL: persistenceURL)
    }

    XCTAssertTrue(copyGate.waitForCopyStart(timeout: 2))
    let cancellationStartedAt = Date()
    worker.cancel()
    copyGate.allowCancellationToProceed()
    let result = await worker.result
    guard case .failure(let error) = result else {
      return XCTFail("cancelled restore staging unexpectedly succeeded")
    }
    XCTAssertTrue(error is CancellationError)
    XCTAssertLessThan(Date().timeIntervalSince(cancellationStartedAt), 1)
    XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("preserve pending".utf8))
    XCTAssertEqual(try temporaryEntries(in: rootURL, prefix: ".WorkspaceBackupPendingRestore-"), [])
  }

  @MainActor
  func testCancelledStoreBackupRecordsCancelledOperation() async throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "WorkspaceStoreCancel")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let persistence = WorkbenchPersistence(
      fileURL: rootURL.appendingPathComponent("workbench.json"))
    let store = WorkbenchStore(
      persistence: persistence,
      knowledgeLibraryService: KnowledgeLibraryService(
        rootURL: rootURL.appendingPathComponent("KnowledgeLibrary")
      )
    )
    let destinationURL = rootURL.appendingPathComponent("cancelled.psworkspacebackup")
    let worker = Task { @MainActor in
      await store.createWorkspaceBackup(at: destinationURL, applicationVersion: "test")
    }
    worker.cancel()
    let preview = await worker.value
    XCTAssertNil(preview)
    _ = await store.operationHistory.flush()

    let event = try XCTUnwrap(
      store.operationHistory.records.first {
        $0.kind == .workspaceBackupCreated
      })
    XCTAssertEqual(event.outcome, .cancelled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
  }

  @MainActor
  func testStoreBackupFlushesOperationHistoryBeforeFreezingLedger() async throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "WorkspaceBackupFlushLedger"
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let persistence = WorkbenchPersistence(
      fileURL: rootURL.appendingPathComponent("workbench.json")
    )
    let store = WorkbenchStore(
      persistence: persistence,
      knowledgeLibraryService: KnowledgeLibraryService(
        rootURL: rootURL.appendingPathComponent("KnowledgeLibrary")
      )
    )
    let record = WorkbenchOperationEventRecord(
      kind: .workspaceRestorePrepared,
      outcome: .succeeded
    )
    XCTAssertTrue(store.recordOperationEvent(record))

    let archiveURL = rootURL.appendingPathComponent("workspace.psworkspacebackup")
    let preview = await store.createWorkspaceBackup(
      at: archiveURL,
      applicationVersion: "test"
    )

    XCTAssertNotNil(preview)
    let archivedDocument = try WorkbenchOperationLedgerPersistence.decodedDocument(
      from: Data(
        contentsOf: archiveURL.appendingPathComponent(
          WorkspaceBackupService.operationHistoryRelativePath
        )
      )
    )
    XCTAssertTrue(archivedDocument.records.contains { $0.id == record.id })
  }

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
    let sourceArticle = try XCTUnwrap(sourceDatabase.articles().first)
    let mediaRelativePath = "source-rss-article/cover.png"
    let mediaAsset = RSSMediaAsset(
      articleID: sourceArticle.id,
      remoteURL: try XCTUnwrap(URL(string: "https://cdn.example.com/cover.png")),
      relativePath: mediaRelativePath,
      contentType: "image/png",
      byteCount: 4
    )
    try sourceDatabase.upsertMediaAssets([mediaAsset])
    let sourceMediaURL = RSSReaderStore.mediaCacheDirectoryURL(for: sourceRSSURL)
      .appendingPathComponent(mediaRelativePath)
    try FileManager.default.createDirectory(
      at: sourceMediaURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceMediaURL)
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

    XCTAssertEqual(created.formatVersion, 2)
    let rssComponent = try XCTUnwrap(
      created.components.first { $0.component == .rssReader }
    )
    XCTAssertEqual(rssComponent.fileCount, 2)
    XCTAssertGreaterThan(rssComponent.byteCount, 0)
    let archivedRSSURL = archiveURL.appendingPathComponent(
      WorkspaceBackupService.rssDatabaseRelativePath
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: archivedRSSURL.path))
    let archivedMediaURL = archiveURL.appendingPathComponent(
      "\(WorkspaceBackupService.rssMediaRelativePrefix)/\(mediaRelativePath)"
    )
    XCTAssertEqual(try Data(contentsOf: archivedMediaURL), Data([0x89, 0x50, 0x4E, 0x47]))
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
    let restoredMediaURL = RSSReaderStore.mediaCacheDirectoryURL(for: targetRSSURL)
      .appendingPathComponent(mediaRelativePath)
    XCTAssertEqual(try Data(contentsOf: restoredMediaURL), Data([0x89, 0x50, 0x4E, 0x47]))
  }

  func testV3BackupRestoresOperationHistoryWithoutMixingTargetLedger() throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "WorkspaceBackupOperationHistoryV3"
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
    let sourceRecord = WorkbenchOperationEventRecord(
      id: UUID(),
      kind: .knowledgeImport,
      outcome: .succeeded,
      occurredAt: Date(timeIntervalSince1970: 2_000)
    )
    let sourceHistory = WorkbenchOperationLedgerDocument(
      retentionPolicy: .forever,
      records: [sourceRecord]
    )
    let archiveURL = sourceRootURL.appendingPathComponent("workspace.psworkspacebackup")
    let service = WorkspaceBackupService()

    let created = try service.createBackup(
      at: archiveURL,
      snapshot: snapshot,
      operationHistoryDocument: sourceHistory,
      knowledgeRootURL: sourceRootURL.appendingPathComponent("KnowledgeLibrary"),
      applicationVersion: "test"
    )

    XCTAssertEqual(created.formatVersion, 3)
    XCTAssertEqual(
      created.components.first { $0.component == .operationHistory }?.fileCount,
      1
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: archiveURL.appendingPathComponent(
          WorkspaceBackupService.operationHistoryRelativePath
        ).path
      )
    )

    let targetPersistenceURL = targetRootURL.appendingPathComponent("workbench.json")
    let targetPersistence = WorkbenchPersistence(fileURL: targetPersistenceURL)
    _ = try targetPersistence.save(snapshot)
    let targetLedger = WorkbenchOperationLedgerPersistence(
      fileURL: targetPersistence.operationLedgerURL
    )
    let targetRecord = WorkbenchOperationEventRecord(
      id: UUID(),
      kind: .siteImport,
      outcome: .failed,
      occurredAt: Date(timeIntervalSince1970: 3_000)
    )
    try targetLedger.save(
      WorkbenchOperationLedgerDocument(retentionPolicy: .forever, records: [targetRecord])
    )

    _ = try service.stageRestore(
      from: archiveURL,
      persistenceFileURL: targetPersistenceURL
    )
    let outcome = WorkspaceBackupService.applyPendingRestoreIfNeeded(
      persistenceFileURL: targetPersistenceURL,
      knowledgeRootURL: targetRootURL.appendingPathComponent("KnowledgeLibrary"),
      attachmentRootURL: targetRootURL.appendingPathComponent("ManagedAttachments")
    )

    guard case .restored(let result) = outcome else {
      return XCTFail("workspace v3 restore did not complete: \(outcome)")
    }
    let restoredHistory = try targetLedger.loadWithRecovery().document
    XCTAssertEqual(restoredHistory.records.map(\.id), [sourceRecord.id])
    XCTAssertFalse(restoredHistory.records.contains { $0.id == targetRecord.id })
    XCTAssertEqual(
      try Data(contentsOf: targetLedger.fileURL),
      try Data(contentsOf: targetLedger.lastKnownGoodURL)
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: result.recoveryURL.appendingPathComponent("operation-log.json").path
      )
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: result.recoveryURL.appendingPathComponent(
          "operation-log-last-known-good.json"
        ).path
      )
    )
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
    let targetPersistence = WorkbenchPersistence(fileURL: targetPersistenceURL)
    _ = try targetPersistence.save(snapshot)
    let targetLedger = WorkbenchOperationLedgerPersistence(
      fileURL: targetPersistence.operationLedgerURL
    )
    let preservedLedgerRecord = WorkbenchOperationEventRecord(
      kind: .siteImport, outcome: .succeeded
    )
    try targetLedger.save(
      WorkbenchOperationLedgerDocument(retentionPolicy: .forever, records: [preservedLedgerRecord])
    )
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
    XCTAssertEqual(try targetLedger.loadWithRecovery().document.records.map(\.id),
      [preservedLedgerRecord.id])
    XCTAssertTrue(FileManager.default.fileExists(atPath: targetLedger.fileURL.path))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: result.recoveryURL.appendingPathComponent("operation-log.json").path
    ))
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
    try KnowledgeNoteCloudRestoreBoundary.markRestoredLibrary(at: fixture.knowledgeURL)
    let previousRestoreID = try KnowledgeNoteCloudRestoreBoundary.restoreID(
      at: fixture.knowledgeURL)
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
    let installedRestoreID = try KnowledgeNoteCloudRestoreBoundary.restoreID(
      at: fixture.knowledgeURL)
    XCTAssertNotNil(installedRestoreID)
    XCTAssertNotEqual(installedRestoreID, previousRestoreID)

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
    XCTAssertEqual(
      try KnowledgeNoteCloudRestoreBoundary.restoreID(at: fixture.knowledgeURL), previousRestoreID)
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

  func testPrepareArticleRestorePreservesSelectedContentAndCreatesIndependentAttachmentCopy()
    throws
  {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "WorkspaceArticleRestore")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceAttachmentURL = rootURL.appendingPathComponent("source.png")
    let attachmentBytes = Data("independent attachment bytes".utf8)
    try attachmentBytes.write(to: sourceAttachmentURL)

    let sourceProfile = SiteProfile.defaultProfile
    let targetProfileID = UUID()
    let coveredAttachment = DraftAttachment(
      originalFilename: "source.png",
      relativePublishPath: "/images/source.png",
      repositoryPath: "static/images/source.png",
      altText: "保留替代文本",
      caption: "保留说明",
      byteSize: Int64(attachmentBytes.count),
      sourceFilePath: sourceAttachmentURL.path,
      repositorySHA: "source-sha",
      remoteObjectKey: "remote/key",
      remoteURL: "https://example.invalid/source.png",
      remoteETag: "remote-etag"
    )
    let unresolvedAttachment = DraftAttachment(
      originalFilename: "missing.pdf",
      relativePublishPath: "/files/missing.pdf",
      repositoryPath: "static/files/missing.pdf",
      altText: "仍显示附件元数据",
      caption: "源文件缺失",
      byteSize: 42,
      sourceFilePath: nil,
      repositorySHA: "missing-sha",
      remoteObjectKey: "remote/missing",
      remoteURL: "https://example.invalid/missing.pdf",
      remoteETag: "missing-etag"
    )
    let sourceDraft = ArticleDraft(
      siteProfileID: sourceProfile.id,
      title: "仅恢复这一篇",
      date: Date(timeIntervalSince1970: 1_700_000_000),
      slug: "selected-article",
      tags: ["tag"],
      categories: ["category"],
      authors: ["author"],
      aliases: ["old-route"],
      pendingSlugRedirectPaths: ["/old-route/"],
      permalink: "/forced-route/",
      draft: false,
      visibility: .private,
      summary: "保留摘要",
      coverAttachmentID: coveredAttachment.id,
      bodyMarkdown: "![本地路径](/images/source.png)\n\n正文保持不变。",
      attachments: [coveredAttachment, unresolvedAttachment],
      status: .published,
      repositoryPath: "content/selected-article.md",
      repositorySHA: "published-sha",
      repositoryImportFingerprint: "import-fingerprint",
      softwareGuideID: "guide-id",
      softwareGuideTemplateVersion: 7
    )
    let unselectedDraft = ArticleDraft(
      siteProfileID: sourceProfile.id,
      title: "不应恢复",
      bodyMarkdown: "Unselected"
    )
    let archiveURL = try createArticleRestoreBackup(
      at: rootURL.appendingPathComponent("source.psworkspacebackup"),
      profile: sourceProfile,
      drafts: [sourceDraft, unselectedDraft],
      knowledgeRootURL: rootURL.appendingPathComponent("KnowledgeLibrary")
    )
    try FileManager.default.removeItem(at: sourceAttachmentURL)

    let service = WorkspaceBackupService()
    let preview = try service.inspectArticlesForRestore(at: archiveURL)
    XCTAssertEqual(preview.articles.map(\.id), [sourceDraft.id, unselectedDraft.id])
    XCTAssertEqual(preview.articles.first?.unresolvedAttachmentCount, 1)

    let attachmentRootURL = rootURL.appendingPathComponent("ManagedAttachments", isDirectory: true)
    let prepared = try service.prepareArticleRestore(
      preview: preview,
      selectedDraftIDs: [sourceDraft.id],
      editingProfileID: targetProfileID,
      attachmentRootURL: attachmentRootURL
    )
    defer {
      try? FileManager.default.removeItem(at: prepared.stagingURL)
      try? FileManager.default.removeItem(at: prepared.destinationURL)
    }
    XCTAssertEqual(prepared.drafts.count, 1)
    let restored = try XCTUnwrap(prepared.drafts.first)
    XCTAssertNotEqual(restored.id, sourceDraft.id)
    XCTAssertEqual(restored.siteProfileID, targetProfileID)
    XCTAssertEqual(restored.scope, .general)
    XCTAssertEqual(restored.status, .draft)
    XCTAssertTrue(restored.draft)
    XCTAssertEqual(restored.title, sourceDraft.title)
    XCTAssertEqual(restored.bodyMarkdown, sourceDraft.bodyMarkdown)
    XCTAssertEqual(restored.visibility, .private)
    XCTAssertEqual(restored.summary, sourceDraft.summary)
    XCTAssertEqual(restored.aliases, [])
    XCTAssertNil(restored.permalink)
    XCTAssertNil(restored.repositoryPath)
    XCTAssertNil(restored.repositorySHA)
    XCTAssertNil(restored.repositoryImportFingerprint)
    XCTAssertNil(restored.repositoryBinding)
    XCTAssertNil(restored.softwareGuideID)
    XCTAssertNil(restored.softwareGuideTemplateVersion)

    let restoredCovered = try XCTUnwrap(restored.attachments.first)
    let restoredUnresolved = try XCTUnwrap(restored.attachments.last)
    XCTAssertNotEqual(restoredCovered.id, coveredAttachment.id)
    XCTAssertEqual(restored.coverAttachmentID, restoredCovered.id)
    XCTAssertEqual(restoredCovered.relativePublishPath, coveredAttachment.relativePublishPath)
    XCTAssertEqual(restoredCovered.repositoryPath, coveredAttachment.repositoryPath)
    XCTAssertEqual(restoredCovered.altText, coveredAttachment.altText)
    XCTAssertEqual(restoredCovered.caption, coveredAttachment.caption)
    XCTAssertNil(restoredCovered.repositorySHA)
    XCTAssertNil(restoredCovered.remoteObjectKey)
    XCTAssertNil(restoredCovered.remoteURL)
    XCTAssertNil(restoredCovered.remoteETag)
    XCTAssertNil(restoredUnresolved.sourceFilePath)
    XCTAssertEqual(restoredUnresolved.altText, unresolvedAttachment.altText)
    XCTAssertEqual(restoredUnresolved.caption, unresolvedAttachment.caption)
    XCTAssertNil(restoredUnresolved.repositorySHA)
    XCTAssertNil(restoredUnresolved.remoteObjectKey)
    XCTAssertNil(restoredUnresolved.remoteURL)
    XCTAssertNil(restoredUnresolved.remoteETag)

    try FileManager.default.createDirectory(
      at: attachmentRootURL, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: prepared.stagingURL, to: prepared.destinationURL)
    let copiedURL = URL(fileURLWithPath: try XCTUnwrap(restoredCovered.sourceFilePath))
    XCTAssertTrue(copiedURL.path.hasPrefix(prepared.destinationURL.path))
    XCTAssertEqual(try Data(contentsOf: copiedURL), attachmentBytes)
  }

  func testPrepareArticleRestoreSharesOneCopiedFileForRepeatedArchiveAttachment() throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "WorkspaceArticleRestoreShared")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceAttachmentURL = rootURL.appendingPathComponent("shared.mov")
    let attachmentBytes = Data("shared attachment".utf8)
    try attachmentBytes.write(to: sourceAttachmentURL)
    let profile = SiteProfile.defaultProfile
    let first = ArticleDraft(
      siteProfileID: profile.id,
      title: "第一篇",
      attachments: [
        DraftAttachment(
          originalFilename: "shared.mov",
          relativePublishPath: "/video/shared.mov",
          repositoryPath: "static/video/shared.mov",
          sourceFilePath: sourceAttachmentURL.path
        )
      ]
    )
    let second = ArticleDraft(
      siteProfileID: profile.id,
      title: "第二篇",
      attachments: [
        DraftAttachment(
          originalFilename: "shared.mov",
          relativePublishPath: "/video/shared.mov",
          repositoryPath: "static/video/shared.mov",
          sourceFilePath: sourceAttachmentURL.path
        )
      ]
    )
    let archiveURL = try createArticleRestoreBackup(
      at: rootURL.appendingPathComponent("source.psworkspacebackup"),
      profile: profile,
      drafts: [first, second],
      knowledgeRootURL: rootURL.appendingPathComponent("KnowledgeLibrary")
    )
    let service = WorkspaceBackupService()
    let prepared = try service.prepareArticleRestore(
      preview: try service.inspectArticlesForRestore(at: archiveURL),
      selectedDraftIDs: [first.id, second.id],
      editingProfileID: UUID(),
      attachmentRootURL: rootURL.appendingPathComponent("ManagedAttachments")
    )
    defer {
      try? FileManager.default.removeItem(at: prepared.stagingURL)
      try? FileManager.default.removeItem(at: prepared.destinationURL)
    }

    let firstAttachment = try XCTUnwrap(prepared.drafts.first?.attachments.first)
    let secondAttachment = try XCTUnwrap(prepared.drafts.last?.attachments.first)
    XCTAssertNotEqual(firstAttachment.id, secondAttachment.id)
    XCTAssertEqual(firstAttachment.sourceFilePath, secondAttachment.sourceFilePath)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: prepared.stagingURL.path).count,
      1
    )
    try FileManager.default.createDirectory(
      at: prepared.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: prepared.stagingURL, to: prepared.destinationURL)
    let destinationURL = URL(fileURLWithPath: try XCTUnwrap(firstAttachment.sourceFilePath))
    XCTAssertEqual(try Data(contentsOf: destinationURL), attachmentBytes)
  }

  func testPrepareArticleRestoreKeepsGeneralDraftLibraryFolder() throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "WorkspaceArticleRestoreGeneralFolder")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = SiteProfile.defaultProfile
    let source = ArticleDraft(
      siteProfileID: profile.id,
      scope: .general,
      generalDraftFolderName: "Research",
      title: "Foldered general draft"
    )
    let archiveURL = try createArticleRestoreBackup(
      at: rootURL.appendingPathComponent("source.psworkspacebackup"),
      profile: profile,
      drafts: [source],
      knowledgeRootURL: rootURL.appendingPathComponent("KnowledgeLibrary")
    )
    let service = WorkspaceBackupService()
    let prepared = try service.prepareArticleRestore(
      preview: try service.inspectArticlesForRestore(at: archiveURL),
      selectedDraftIDs: [source.id],
      editingProfileID: UUID(),
      attachmentRootURL: rootURL.appendingPathComponent("ManagedAttachments")
    )
    defer {
      try? FileManager.default.removeItem(at: prepared.stagingURL)
      try? FileManager.default.removeItem(at: prepared.destinationURL)
    }

    XCTAssertEqual(prepared.drafts.first?.generalDraftFolderName, "Research")
    XCTAssertNil(prepared.drafts.first?.repositoryPath)
  }

  func testPrepareArticleRestoreRejectsEmptyUnknownAndChangedSelections() throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "WorkspaceArticleRestoreSelection")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(siteProfileID: profile.id, title: "可选文章")
    let archiveURL = try createArticleRestoreBackup(
      at: rootURL.appendingPathComponent("source.psworkspacebackup"),
      profile: profile,
      drafts: [draft],
      knowledgeRootURL: rootURL.appendingPathComponent("KnowledgeLibrary")
    )
    let service = WorkspaceBackupService()
    let preview = try service.inspectArticlesForRestore(at: archiveURL)
    let attachmentRootURL = rootURL.appendingPathComponent("ManagedAttachments")

    assertArticleRestoreError(.invalidSelection) {
      _ = try service.prepareArticleRestore(
        preview: preview,
        selectedDraftIDs: [],
        editingProfileID: UUID(),
        attachmentRootURL: attachmentRootURL
      )
    }
    assertArticleRestoreError(.invalidSelection) {
      _ = try service.prepareArticleRestore(
        preview: preview,
        selectedDraftIDs: [UUID()],
        editingProfileID: UUID(),
        attachmentRootURL: attachmentRootURL
      )
    }

    let manifestURL = archiveURL.appendingPathComponent(WorkspaceBackupService.manifestFileName)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var manifest = try decoder.decode(
      WorkspaceBackupManifest.self, from: Data(contentsOf: manifestURL))
    manifest.createdAt = manifest.createdAt.addingTimeInterval(1)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    assertArticleRestoreError(.backupChanged) {
      _ = try service.prepareArticleRestore(
        preview: preview,
        selectedDraftIDs: [draft.id],
        editingProfileID: UUID(),
        attachmentRootURL: attachmentRootURL
      )
    }
  }

  func testPrepareArticleRestoreRejectsTamperedAttachmentArchive() throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "WorkspaceArticleRestoreTamper")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceAttachmentURL = rootURL.appendingPathComponent("source.bin")
    try Data("original".utf8).write(to: sourceAttachmentURL)
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "校验附件",
      attachments: [
        DraftAttachment(
          originalFilename: "source.bin",
          relativePublishPath: "/files/source.bin",
          repositoryPath: "static/files/source.bin",
          sourceFilePath: sourceAttachmentURL.path
        )
      ]
    )
    let archiveURL = try createArticleRestoreBackup(
      at: rootURL.appendingPathComponent("source.psworkspacebackup"),
      profile: profile,
      drafts: [draft],
      knowledgeRootURL: rootURL.appendingPathComponent("KnowledgeLibrary")
    )
    let service = WorkspaceBackupService()
    let preview = try service.inspectArticlesForRestore(at: archiveURL)
    let manifest = try decodedWorkspaceBackupManifest(at: archiveURL)
    let attachmentPath = try XCTUnwrap(
      manifest.files.first {
        $0.component == .draftAttachments
      }?.relativePath)
    try Data("tampered".utf8).write(to: archiveURL.appendingPathComponent(attachmentPath))

    XCTAssertThrowsError(
      try service.prepareArticleRestore(
        preview: preview,
        selectedDraftIDs: [draft.id],
        editingProfileID: UUID(),
        attachmentRootURL: rootURL.appendingPathComponent("ManagedAttachments")
      )
    ) { error in
      guard case WorkspaceBackupError.checksumMismatch = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testCancelledArticleRestoreRemovesStagingWithoutChangingBackup() async throws {
    let root = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "ArticleRestoreCancellation")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("large.bin")
    try Data(repeating: 42, count: 2 * 1_024 * 1_024).write(to: source)
    let snapshot = makeCancellationSnapshot(sourceURL: source)
    let archive = root.appendingPathComponent("backup.psworkspacebackup")
    let service = WorkspaceBackupService()
    _ = try service.createBackup(
      at: archive, snapshot: snapshot,
      knowledgeRootURL: root.appendingPathComponent("KnowledgeLibrary"), applicationVersion: "test"
    )
    let preview = try service.inspectArticlesForRestore(at: archive)
    let gate = WorkspaceBackupCopyGate()
    let cancellableService = WorkspaceBackupService(
      fileManager: .default, restoreMutationHook: { _ in },
      fileCopyProgressHook: { _, _ in
        gate.signalCopyStarted()
        gate.waitUntilCancellationIsForwarded()
      }
    )
    let worker = Task.detached {
      try cancellableService.prepareArticleRestore(
        preview: preview, selectedDraftIDs: Set(preview.articles.map(\.id)),
        editingProfileID: UUID(),
        attachmentRootURL: root.appendingPathComponent("ManagedAttachments")
      )
    }
    XCTAssertTrue(gate.waitForCopyStart(timeout: 5))
    worker.cancel()
    gate.allowCancellationToProceed()
    switch await worker.result {
    case .success: XCTFail("cancelled preparation unexpectedly succeeded")
    case .failure(let error): XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(try temporaryEntries(in: root, prefix: ".article-restore-"), [])
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("ManagedAttachments").path)
    )
    XCTAssertEqual(try service.inspectArticlesForRestore(at: archive).manifest, preview.manifest)
  }

  func testBackupCopyRejectsGrowingSourceAndRemovesPartialDestination() throws {
    let root = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "BackupGrowingSource")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.bin")
    let destination = root.appendingPathComponent("copy.bin")
    try Data(repeating: 1, count: 1_048_576).write(to: source)
    let service = WorkspaceBackupService(
      fileManager: .default, restoreMutationHook: { _ in },
      fileCopyProgressHook: { _, _ in
        let handle = try? FileHandle(forWritingTo: source)
        defer { try? handle?.close() }
        _ = try? handle?.seekToEnd()
        try? handle?.write(contentsOf: Data([2]))
      }
    )
    XCTAssertThrowsError(
      try service.copyRegularFile(
        from: source, to: destination, relativePath: "attachments/source.bin",
        component: .draftAttachments
      ))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  private func createArticleRestoreBackup(
    at archiveURL: URL,
    profile: SiteProfile,
    drafts: [ArticleDraft],
    knowledgeRootURL: URL
  ) throws -> URL {
    _ = try WorkspaceBackupService().createBackup(
      at: archiveURL,
      snapshot: WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: drafts,
        releaseRecords: []
      ),
      knowledgeRootURL: knowledgeRootURL,
      applicationVersion: "test"
    )
    return archiveURL
  }

  private func decodedWorkspaceBackupManifest(at archiveURL: URL) throws -> WorkspaceBackupManifest
  {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
      WorkspaceBackupManifest.self,
      from: Data(
        contentsOf: archiveURL.appendingPathComponent(WorkspaceBackupService.manifestFileName))
    )
  }

  private func assertArticleRestoreError(
    _ expected: WorkspaceBackupArticleRestoreError,
    operation: () throws -> Void
  ) {
    XCTAssertThrowsError(try operation()) { error in
      guard let actual = error as? WorkspaceBackupArticleRestoreError else {
        return XCTFail("unexpected error: \(error)")
      }
      switch (expected, actual) {
      case (.invalidSelection, .invalidSelection),
        (.backupChanged, .backupChanged),
        (.unavailable, .unavailable),
        (.persistenceFailed, .persistenceFailed):
        break
      default:
        XCTFail("unexpected article restore error: \(actual)")
      }
    }
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
    let operationLedger = WorkbenchOperationLedgerPersistence(
      fileURL: persistence.operationLedgerURL
    )
    try operationLedger.save(
      WorkbenchOperationLedgerDocument(
        retentionPolicy: .forever,
        records: [
          WorkbenchOperationEventRecord(kind: .siteImport, outcome: .succeeded)
        ]
      )
    )
    let operationLedgerData = try Data(contentsOf: operationLedger.fileURL)
    let operationLedgerLastKnownGoodData = try Data(contentsOf: operationLedger.lastKnownGoodURL)

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
      operationLedgerURL: operationLedger.fileURL,
      operationLedgerData: operationLedgerData,
      operationLedgerLastKnownGoodURL: operationLedger.lastKnownGoodURL,
      operationLedgerLastKnownGoodData: operationLedgerLastKnownGoodData,
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
      try Data(contentsOf: fixture.operationLedgerURL),
      fixture.operationLedgerData
    )
    XCTAssertEqual(
      try Data(contentsOf: fixture.operationLedgerLastKnownGoodURL),
      fixture.operationLedgerLastKnownGoodData
    )
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

  private func makeCancellationSnapshot(sourceURL: URL) -> WorkbenchSnapshot {
    let profile = SiteProfile.defaultProfile
    var draft = ArticleDraft.empty(profile: profile)
    draft.attachments = [
      DraftAttachment(
        originalFilename: sourceURL.lastPathComponent,
        relativePublishPath: "/images/source-image.png",
        repositoryPath: "static/images/source-image.png",
        sourceFilePath: sourceURL.path
      )
    ]
    return WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [draft],
      releaseRecords: []
    )
  }

  private func temporaryEntries(in directoryURL: URL, prefix: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
      .filter { $0.hasPrefix(prefix) }
  }
}

private final class WorkspaceBackupCopyGate: Sendable {
  private let copyStarted = DispatchSemaphore(value: 0)
  private let cancellationForwarded = DispatchSemaphore(value: 0)

  func signalCopyStarted() {
    copyStarted.signal()
  }

  func waitForCopyStart(timeout: TimeInterval) -> Bool {
    copyStarted.wait(timeout: .now() + timeout) == .success
  }

  func waitUntilCancellationIsForwarded() {
    cancellationForwarded.wait()
  }

  func allowCancellationToProceed() {
    cancellationForwarded.signal()
  }
}

private final class WorkspaceBackupCommitGate: Sendable {
  private let committed = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)

  func signalCommitted() { committed.signal() }
  func waitForCommit(timeout: TimeInterval) -> Bool {
    committed.wait(timeout: .now() + timeout) == .success
  }
  func waitUntilTestReleasesCommit() { release.wait() }
  func releaseCommit() { release.signal() }
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
  var operationLedgerURL: URL
  var operationLedgerData: Data
  var operationLedgerLastKnownGoodURL: URL
  var operationLedgerLastKnownGoodData: Data
  var attachmentData: Data
}


final class WorkspaceExchangeCodecTests: XCTestCase {
  private func fixture() throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/portable-workspace-v1.json")
    return try Data(contentsOf: url)
  }

  func testDecodesGoldenFixtureAndMatchesCanonicalHash() throws {
    let data = try fixture()
    let package = try WorkspaceExchangeCodec.decode(data)
    XCTAssertEqual(package.manifest.payloadSHA256, "58bb2856281f5f4fab30858bd7c451a34d8f8655809f3851741d9ec62e12f3d7")
    XCTAssertEqual(package.manifest.itemCounts, .init(profiles: 1, drafts: 1, attachments: 1))
    XCTAssertEqual(package.payload.drafts.first?.attachments.first?.relativePublishPath, "images/cover.png")
  }

  func testRejectsUnknownKeysNullAndTampering() throws {
    let original = try fixture()
    var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
    unknown["unexpected"] = true
    XCTAssertThrowsError(try WorkspaceExchangeCodec.decode(JSONSerialization.data(withJSONObject: unknown)))

    var withNull = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
    var payload = try XCTUnwrap(withNull["payload"] as? [String: Any])
    var drafts = try XCTUnwrap(payload["drafts"] as? [[String: Any]])
    drafts[0]["coverAttachmentID"] = NSNull()
    payload["drafts"] = drafts
    withNull["payload"] = payload
    XCTAssertThrowsError(try WorkspaceExchangeCodec.decode(JSONSerialization.data(withJSONObject: withNull)))

    let tampered = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "一像素示例图", with: "篡改")
    XCTAssertThrowsError(try WorkspaceExchangeCodec.decode(Data(tampered.utf8)))
  }

  func testRoundTripProducesValidPackage() throws {
    let decoded = try WorkspaceExchangeCodec.decode(fixture())
    let encoded = try WorkspaceExchangeCodec.encode(decoded.payload, createdAt: decoded.manifest.createdAt)
    let roundTrip = try WorkspaceExchangeCodec.decode(encoded)
    XCTAssertEqual(roundTrip.payload, decoded.payload)
    XCTAssertEqual(roundTrip.manifest.payloadSHA256, decoded.manifest.payloadSHA256)
  }

  func testImportPreparationAssignsNewIDsAndStagesAttachmentBytes() throws {
    let package = try WorkspaceExchangeCodec.decode(fixture())
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkspaceExchangeCodecTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    let attachmentStore = ManagedAttachmentFileStore(rootDirectoryURL: temporaryRoot.appendingPathComponent("managed"))
    let destinationProfileID = UUID()
    let sourceProfileID = try XCTUnwrap(package.payload.profiles.first?.id)
    let imported = try WorkspaceExchangeTransferService.prepareImport(
      package: package,
      profileMappings: [sourceProfileID: .existing(destinationProfileID)],
      activeProfileID: destinationProfileID,
      attachmentStore: attachmentStore,
      temporaryDirectory: temporaryRoot
    )
    let sourceDraft = try XCTUnwrap(package.payload.drafts.first)
    let importedDraft = try XCTUnwrap(imported.drafts.first)
    let sourceAttachment = try XCTUnwrap(sourceDraft.attachments.first)
    let importedAttachment = try XCTUnwrap(importedDraft.attachments.first)
    XCTAssertNotEqual(importedDraft.id, sourceDraft.id)
    XCTAssertNotEqual(importedAttachment.id, sourceAttachment.id)
    XCTAssertEqual(importedDraft.scope, .site(destinationProfileID))
    XCTAssertEqual(importedAttachment.relativePublishPath, sourceAttachment.relativePublishPath)
    let localPath = try XCTUnwrap(importedAttachment.sourceFilePath)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: localPath)), sourceAttachment.bytes)
  }

  func testRejectsCaseInsensitiveDuplicateAttachmentPublishPaths() throws {
    let decoded = try WorkspaceExchangeCodec.decode(fixture())
    var payload = decoded.payload
    var draft = try XCTUnwrap(payload.drafts.first)
    var duplicate = try XCTUnwrap(draft.attachments.first)
    duplicate.id = UUID()
    duplicate.role = "inline"
    duplicate.relativePublishPath = duplicate.relativePublishPath.uppercased()
    draft.attachments.append(duplicate)
    payload.drafts[0] = draft
    XCTAssertThrowsError(try WorkspaceExchangeCodec.encode(payload))
  }

  func testRejectsNonCanonicalISO8601Dates() throws {
    let data = try fixture()
    var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var manifest = try XCTUnwrap(root["manifest"] as? [String: Any])
    manifest["createdAt"] = "2026-9-23T04:00:00Z"
    root["manifest"] = manifest
    XCTAssertThrowsError(try WorkspaceExchangeCodec.decode(JSONSerialization.data(withJSONObject: root)))
  }

  @MainActor
  func testWorkbenchStoreImportPersistsNewDraftAndAttachment() async throws {
    let data = try fixture()
    let package = try WorkspaceExchangeCodec.decode(data)
    let sourceProfileID = try XCTUnwrap(package.payload.profiles.first?.id)
    let sourceDraft = try XCTUnwrap(package.payload.drafts.first)
    let sourceAttachment = try XCTUnwrap(sourceDraft.attachments.first)
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "WorkspaceExchangeStoreImport")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let persistenceURL = rootURL.appendingPathComponent("workbench.json")
    let attachmentRoot = rootURL.appendingPathComponent("ManagedAttachments", isDirectory: true)
    let attachmentStore = ManagedAttachmentFileStore(rootDirectoryURL: attachmentRoot)

    do {
      let store = WorkbenchStore(
        persistence: WorkbenchPersistence(fileURL: persistenceURL),
        knowledgeLibraryService: KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("KnowledgeLibrary")),
        managedAttachmentFileStore: attachmentStore
      )
      let preview = try await store.previewWorkspaceExchange(data: data)
      let importedCount = try await store.importWorkspaceExchange(
        preview,
        profileMappings: [sourceProfileID: .importAsNewProfile]
      )
      XCTAssertEqual(importedCount, 1)
      let importedDraft = try XCTUnwrap(store.drafts.first { $0.title == sourceDraft.title })
      XCTAssertNotEqual(importedDraft.id, sourceDraft.id)
      XCTAssertEqual(importedDraft.bodyMarkdown, sourceDraft.bodyMarkdown)
      let importedAttachment = try XCTUnwrap(importedDraft.attachments.first)
      XCTAssertNotEqual(importedAttachment.id, sourceAttachment.id)
      XCTAssertEqual(importedAttachment.relativePublishPath, sourceAttachment.relativePublishPath)
      let localPath = try XCTUnwrap(importedAttachment.sourceFilePath)
      XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: localPath)), sourceAttachment.bytes)
    }

    let reopenedStore = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      knowledgeLibraryService: KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("KnowledgeLibrary")),
      managedAttachmentFileStore: attachmentStore
    )
    let reopenedDraft = try XCTUnwrap(reopenedStore.drafts.first { $0.title == sourceDraft.title })
    XCTAssertEqual(reopenedDraft.bodyMarkdown, sourceDraft.bodyMarkdown)
    let reopenedAttachment = try XCTUnwrap(reopenedDraft.attachments.first)
    let reopenedPath = try XCTUnwrap(reopenedAttachment.sourceFilePath)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: reopenedPath)), sourceAttachment.bytes)
  }
}

final class WorkspaceExchangePathConflictTests: XCTestCase {
  private let articleDate = Date(timeIntervalSince1970: 1_700_000_000)

  func testSameSlugOnAnotherSiteDoesNotWarn() throws {
    let siteA = SiteProfile(name: "A")
    let siteB = SiteProfile(name: "B")
    let sourceID = UUID()
    let incoming = portableDraft(sourceProfileID: sourceID, slug: "shared")
    let existing = ArticleDraft(
      siteProfileID: siteA.id, title: "Existing", date: articleDate, slug: "shared")

    let conflicts = try WorkspaceExchangePathConflictService.conflicts(
      package: package(profiles: [portableProfile(id: sourceID)], drafts: [incoming]),
      profileMappings: [sourceID: .existing(siteB.id)],
      existingProfiles: [siteA, siteB],
      existingDrafts: [existing]
    )

    XCTAssertTrue(conflicts.isEmpty)
  }

  func testMappedPublishPathConflictCanBeResolvedWithNewSlug() throws {
    let target = SiteProfile(name: "Target")
    let sourceID = UUID()
    let incoming = portableDraft(sourceProfileID: sourceID, slug: "shared")
    let existing = ArticleDraft(
      siteProfileID: target.id, title: "Existing", date: articleDate, slug: "shared")
    let exchange = package(profiles: [portableProfile(id: sourceID)], drafts: [incoming])
    let mapping: [UUID: WorkspaceExchangeProfileMapping] = [sourceID: .existing(target.id)]

    let conflicts = try WorkspaceExchangePathConflictService.conflicts(
      package: exchange,
      profileMappings: mapping,
      existingProfiles: [target],
      existingDrafts: [existing]
    )
    XCTAssertEqual(conflicts.map(\.sourceDraftID), [incoming.id])
    XCTAssertEqual(conflicts.first?.path, target.markdownPath(for: existing))

    let resolved = try WorkspaceExchangePathConflictService.conflicts(
      package: exchange,
      profileMappings: mapping,
      slugOverrides: [incoming.id: "shared-imported"],
      existingProfiles: [target],
      existingDrafts: [existing]
    )
    XCTAssertTrue(resolved.isEmpty)
  }

  func testTwoImportedDraftsAtSamePathBothRequireResolution() throws {
    let sourceID = UUID()
    let first = portableDraft(sourceProfileID: sourceID, slug: "duplicate")
    let second = portableDraft(sourceProfileID: sourceID, slug: "duplicate")
    let exchange = package(profiles: [portableProfile(id: sourceID)], drafts: [first, second])

    let conflicts = try WorkspaceExchangePathConflictService.conflicts(
      package: exchange,
      profileMappings: [sourceID: .importAsNewProfile],
      existingProfiles: [],
      existingDrafts: []
    )
    XCTAssertEqual(Set(conflicts.map(\.sourceDraftID)), Set([first.id, second.id]))

    let resolved = try WorkspaceExchangePathConflictService.conflicts(
      package: exchange,
      profileMappings: [sourceID: .importAsNewProfile],
      slugOverrides: [second.id: "duplicate-imported"],
      existingProfiles: [],
      existingDrafts: []
    )
    XCTAssertTrue(resolved.isEmpty)
  }

  func testInvalidOverrideCannotBypassTargetSlugRule() throws {
    let target = SiteProfile(name: "Target")
    let sourceID = UUID()
    let incoming = portableDraft(sourceProfileID: sourceID, slug: "shared")

    XCTAssertThrowsError(
      try WorkspaceExchangePathConflictService.conflicts(
        package: package(profiles: [portableProfile(id: sourceID)], drafts: [incoming]),
        profileMappings: [sourceID: .existing(target.id)],
        slugOverrides: [incoming.id: "../escape"],
        existingProfiles: [target],
        existingDrafts: []
      )
    ) { error in
      guard case WorkspaceExchangeError.invalidSlug = error else {
        return XCTFail("Expected invalidSlug, got \(error)")
      }
    }
  }

  @MainActor
  func testImportRechecksCurrentDraftsAfterPreview() async throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "WorkspaceExchangePathRecheck")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: rootURL.appendingPathComponent("workbench.json"))
    )
    let target = try XCTUnwrap(store.profiles.first)
    let sourceID = UUID()
    let incoming = portableDraft(sourceProfileID: sourceID, slug: "shared")
    let exchange = package(profiles: [portableProfile(id: sourceID)], drafts: [incoming])
    let data = try WorkspaceExchangeCodec.encode(exchange.payload, createdAt: articleDate)
    let preview = try await store.previewWorkspaceExchange(data: data)

    let existing = ArticleDraft(
      siteProfileID: target.id, title: "Created after preview", date: articleDate, slug: "shared")
    store.publishingStore.drafts.append(existing)
    let draftIDsBeforeImport = Set(store.drafts.map(\.id))

    do {
      _ = try await store.importWorkspaceExchange(
        preview,
        profileMappings: [sourceID: .existing(target.id)]
      )
      XCTFail("Import must reject a path occupied after preview")
    } catch WorkspaceExchangeError.duplicatePublishPath(let path) {
      XCTAssertEqual(path, target.markdownPath(for: existing))
    }
    XCTAssertEqual(Set(store.drafts.map(\.id)), draftIDsBeforeImport)
  }

  private func package(
    profiles: [WorkspaceExchangeProfile],
    drafts: [WorkspaceExchangeDraft]
  ) -> WorkspaceExchangePackage {
    let payload = WorkspaceExchangePayload(profiles: profiles, drafts: drafts)
    return WorkspaceExchangePackage(
      manifest: WorkspaceExchangeManifest(
        createdAt: articleDate,
        payloadSHA256: "",
        itemCounts: WorkspaceExchangeCodec.itemCounts(for: payload)
      ),
      payload: payload
    )
  }

  private func portableProfile(id: UUID) -> WorkspaceExchangeProfile {
    WorkspaceExchangeProfile(
      id: id,
      name: "Source",
      siteKind: "zola",
      repoOwner: "owner",
      repoName: "repo",
      branch: "main"
    )
  }

  private func portableDraft(sourceProfileID: UUID, slug: String) -> WorkspaceExchangeDraft {
    WorkspaceExchangeDraft(
      id: UUID(),
      scope: "site",
      sourceProfileID: sourceProfileID,
      title: "Incoming",
      date: articleDate,
      slug: slug,
      tags: [],
      categories: [],
      authors: [],
      visibility: "public",
      summary: "",
      bodyMarkdown: "Body",
      createdAt: articleDate,
      updatedAt: articleDate,
      attachments: []
    )
  }
}
