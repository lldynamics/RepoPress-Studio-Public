import Foundation
import PublishingDomainContracts
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchSafeTerminationTests: XCTestCase {
  func testExternalConflictTerminatesWithLocalRecoveryAndRestoresPendingDraft() async throws {
    let fixture = try await makeFixture(prefix: "safe-termination-conflict")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let draft = try await fixture.addDraft(slug: "conflict", body: "Original body")
    let documentURL = try fixture.documentURL(for: draft)
    let externalDocument = "---\ntitle: conflict\nslug: conflict\n---\n\nExternal body\n"
    try externalDocument.write(to: documentURL, atomically: true, encoding: .utf8)

    var localDraft = try XCTUnwrap(fixture.store.drafts.first { $0.id == draft.id })
    localDraft.bodyMarkdown = "Local body that must survive exit"
    fixture.store.updateDraft(localDraft)

    let result = await fixture.store.prepareForSafeTermination()

    XCTAssertEqual(result, .savedLocally(pendingProjectFileCount: 1))
    XCTAssertTrue(fixture.store.validatePreparedSafeTermination())
    XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), externalDocument)
    XCTAssertFalse(fixture.store.flushPendingChanges())
    XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), externalDocument)

    let restarted = makeSafeExitTestStore(persistence: fixture.persistence)
    await restarted.waitForPendingSave()
    XCTAssertEqual(
      restarted.drafts.first(where: { $0.id == draft.id })?.bodyMarkdown,
      "Local body that must survive exit"
    )
    XCTAssertEqual(restarted.siteDraftFileSaveFailureGroups.count, 1)
    let repeatedExit = await restarted.prepareForSafeTermination()
    XCTAssertEqual(repeatedExit, .savedLocally(pendingProjectFileCount: 1))
    XCTAssertTrue(restarted.validatePreparedSafeTermination())
    XCTAssertEqual(
      try String(contentsOf: documentURL, encoding: .utf8),
      externalDocument
    )
  }

  func testPrimarySnapshotFailurePreventsSafeTermination() async throws {
    let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "safe-termination-primary-failure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: baseURL) }
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    let blockedParent = baseURL.appendingPathComponent("blocked-parent")
    try Data("not a directory".utf8).write(to: blockedParent)
    let persistence = WorkbenchPersistence(
      fileURL: blockedParent.appendingPathComponent("workbench.json"))
    let store = makeSafeExitTestStore(persistence: persistence)
    store.createDraft()

    let result = await store.prepareForSafeTermination()

    guard case .failed = result else {
      return XCTFail("Primary snapshot failure must prevent termination: \(result)")
    }
  }

  func testFormatFifteenDefaultsDeferredProjectWritesAndSixteenRoundTripsThem() throws {
    var profile = SiteProfile.defaultProfile
    profile.name = "Schema test"
    var draft = ArticleDraft.empty(profile: profile)
    draft.slug = "pending"
    draft.recordProjectFile(profile: profile, repositoryPath: "content/posts/pending.md", renderedContentDigest: "abc")
    let failure = SiteDraftFileSaveFailure(
      draftID: draft.id,
      profile: profile,
      repositoryPath: "content/posts/pending.md",
      error: SiteDraftFileStoreError.projectFileChangedExternally("content/posts/pending.md")
    )
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [draft],
      releaseRecords: [],
      deferredProjectFileWrites: [failure]
    )

    let roundTripped = try JSONDecoder.workbench.decode(
      WorkbenchSnapshot.self, from: JSONEncoder.workbench.encode(snapshot))
    XCTAssertEqual(roundTripped.formatVersion, WorkbenchSnapshot.currentFormatVersion)
    XCTAssertEqual(roundTripped.deferredProjectFileWrites, [failure])

    var legacyObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder.workbench.encode(snapshot)) as? [String: Any])
    legacyObject["formatVersion"] = 15
    legacyObject.removeValue(forKey: "deferredProjectFileWrites")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    let migrated = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: legacyData)
    XCTAssertEqual(migrated.formatVersion, WorkbenchSnapshot.currentFormatVersion)
    XCTAssertTrue(migrated.deferredProjectFileWrites.isEmpty)
  }

  func testFinalQuitProofRejectsAnEditMadeDuringConfirmation() async throws {
    let fixture = try await makeFixture(prefix: "safe-termination-final-edit")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let draft = try await fixture.addDraft(slug: "late-edit", body: "Saved body")
    let result = await fixture.store.prepareForSafeTermination()
    XCTAssertEqual(result, .saved)
    XCTAssertTrue(fixture.store.validatePreparedSafeTermination())
    let buffer = fixture.store.draftBodyEditorBuffer(for: draft.id)
    _ = fixture.store.stageDraftBody("Typed while confirming", for: draft.id, baseRevision: buffer.revision)
    XCTAssertFalse(fixture.store.validatePreparedSafeTermination())
    let repeated = await fixture.store.prepareForSafeTermination()
    XCTAssertEqual(repeated, .saved)
    XCTAssertTrue(fixture.store.validatePreparedSafeTermination())
    let saved = try XCTUnwrap(fixture.persistence.load())
    XCTAssertEqual(saved.drafts.first { $0.id == draft.id }?.bodyMarkdown, "Typed while confirming")
  }

  func testFinalQuitProofHandlesMultiDraftSessionsAndProfileMaps() async throws {
    let fixture = try await makeFixture(prefix: "safe-termination-multi-session")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let firstProfileID = fixture.store.activeProfileID
    let firstDraft = try await fixture.addDraft(slug: "first", body: "First saved body")

    let secondProfile = fixture.store.createProfile(named: "Second safe-exit profile")
    fixture.store.updateActiveProfile {
      $0.localRepositoryRootPath = fixture.repositoryURL.path
      $0.markdownPathPattern = "content/posts/{slug}.md"
    }
    let secondDraft = try await fixture.addDraft(slug: "second", body: "Second saved body")

    fixture.store.updateRepositoryAutoSyncSettings(
      RepositoryAutoSyncSettings(
        isEnabled: false,
        intervalMinutes: 20,
        fetchBeforeScan: false,
        autoImportRemoteArticles: true
      ),
      for: firstProfileID
    )
    fixture.store.updateRepositoryAutoSyncSettings(
      RepositoryAutoSyncSettings(
        isEnabled: false,
        intervalMinutes: 45,
        fetchBeforeScan: true,
        autoImportRemoteArticles: false
      ),
      for: secondProfile.id
    )
    fixture.store.updateDeploymentPollingSettings(
      DeploymentPollingSettings(isEnabled: false, intervalMinutes: 20),
      for: firstProfileID
    )
    fixture.store.updateDeploymentPollingSettings(
      DeploymentPollingSettings(isEnabled: false, intervalMinutes: 45),
      for: secondProfile.id
    )
    fixture.store.updateMarkdownEditorSessionState(
      MarkdownEditorSessionState(
        selectedRange: NSRange(location: 1, length: 3),
        editorScrollProgress: 0.25,
        isFindReplacePresented: true,
        findQuery: "first",
        replacementText: "primary"
      ),
      for: firstDraft.id,
      bodyUTF16Count: firstDraft.bodyMarkdown.utf16.count
    )
    fixture.store.updateMarkdownEditorSessionState(
      MarkdownEditorSessionState(
        selectedRange: NSRange(location: 2, length: 2),
        editorScrollProgress: 0.75,
        isFindReplacePresented: true,
        findQuery: "second",
        replacementText: "secondary",
        isFindCaseSensitive: true
      ),
      for: secondDraft.id,
      bodyUTF16Count: secondDraft.bodyMarkdown.utf16.count
    )
    await fixture.store.waitForPendingSave()

    _ = await fixture.store.prepareForSafeTermination()
    let prepared = try XCTUnwrap(fixture.persistence.load())
    XCTAssertEqual(Set(prepared.drafts.map(\.id)), Set([firstDraft.id, secondDraft.id]))
    XCTAssertEqual(
      Set(prepared.markdownEditorSessionStates.keys),
      Set([firstDraft.id, secondDraft.id])
    )
    XCTAssertEqual(
      Set(prepared.repositoryAutoSyncSettingsByProfileID.keys),
      Set([firstProfileID, secondProfile.id])
    )
    XCTAssertEqual(
      Set(prepared.deploymentPollingSettingsByProfileID.keys),
      Set([firstProfileID, secondProfile.id])
    )
    XCTAssertTrue(fixture.store.validatePreparedSafeTermination())
    _ = await fixture.store.prepareForSafeTermination()
    XCTAssertTrue(fixture.store.validatePreparedSafeTermination())

    fixture.store.updateMarkdownEditorSessionState(
      MarkdownEditorSessionState(
        selectedRange: NSRange(location: 0, length: 0),
        editorScrollProgress: 1,
        isFindReplacePresented: true,
        findQuery: "changed while confirming",
        replacementText: "secondary",
        isFindCaseSensitive: true
      ),
      for: secondDraft.id,
      bodyUTF16Count: secondDraft.bodyMarkdown.utf16.count
    )
    XCTAssertFalse(fixture.store.validatePreparedSafeTermination())

    _ = await fixture.store.prepareForSafeTermination()
    XCTAssertTrue(fixture.store.validatePreparedSafeTermination())
    let buffer = fixture.store.draftBodyEditorBuffer(for: firstDraft.id)
    _ = fixture.store.stageDraftBody(
      "First body changed while confirming",
      for: firstDraft.id,
      baseRevision: buffer.revision
    )
    XCTAssertFalse(fixture.store.validatePreparedSafeTermination())
  }

  func testFinalQuitProofAcceptsUUIDMapReorderingButRejectsChangedDiskBody() async throws {
    let fixture = try await makeFixture(prefix: "safe-termination-json-order")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    for index in 0..<3 {
      if index > 0 { fixture.store.createDraft() }
      let draft = try await fixture.addDraft(slug: "order-\(index)", body: "Saved body \(index)")
      fixture.store.updateMarkdownEditorSessionState(
        MarkdownEditorSessionState(findQuery: "query-\(index)"),
        for: draft.id, bodyUTF16Count: draft.bodyMarkdown.utf16.count
      )
    }
    _ = await fixture.store.prepareForSafeTermination()
    XCTAssertTrue(fixture.store.validatePreparedSafeTermination())
    let manifest = try JSONDecoder().decode(
      WorkbenchRecordManifest.self,
      from: Data(contentsOf: fixture.persistence.fileURL))
    let database = try WorkbenchRecordDatabase(
      url: fixture.persistence.recordStoreDirectoryURL
        .appendingPathComponent(manifest.storeID.uuidString).appendingPathComponent(
          "records.sqlite"))
    var rows = try database.records()
    let envelopeIndex = try XCTUnwrap(rows.firstIndex { $0.collection == "workspace" })
    let original = rows[envelopeIndex].data
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
    let pairs = try XCTUnwrap(object["markdownEditorSessionStates"] as? [Any])
    XCTAssertEqual(pairs.count, 6)
    object["markdownEditorSessionStates"] = stride(from: pairs.count - 2, through: 0, by: -2)
      .flatMap { [pairs[$0], pairs[$0 + 1]] }
    let reordered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    XCTAssertNotEqual(original, reordered)
    let envelope = rows[envelopeIndex]
    rows[envelopeIndex] = WorkbenchStorageRecord(
      collection: envelope.collection,
      id: envelope.id, position: envelope.position, data: reordered)
    _ = try database.replace(with: rows)
    XCTAssertTrue(fixture.store.validatePreparedSafeTermination())

    let externalWriter = WorkbenchPersistence(fileURL: fixture.persistence.fileURL)
    var changed = try XCTUnwrap(externalWriter.load())
    changed.drafts[0].bodyMarkdown = "Disk content changed during confirmation"
    _ = try externalWriter.save(changed)
    XCTAssertFalse(fixture.store.validatePreparedSafeTermination())
  }


  func testMissingProjectStillAllowsExitAfterSavingLocalDraft() async throws {
    let fixture = try await makeFixture(prefix: "safe-termination-missing-project")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let draft = try await fixture.addDraft(slug: "missing", body: "Original")
    fixture.store.updateActiveProfile { $0.localRepositoryRootPath = fixture.baseURL.appendingPathComponent("missing").path }
    var changed = draft
    changed.bodyMarkdown = "Waiting for the disk"
    fixture.store.updateDraft(changed)
    let result = await fixture.store.prepareForSafeTermination()
    XCTAssertEqual(result, .savedLocally(pendingProjectFileCount: 1))
    XCTAssertTrue(fixture.store.validatePreparedSafeTermination())
  }

  func testRecoveryExportPreservesCurrentBodyWhenPrimarySnapshotCannotBeWritten() async throws {
    let fixture = try await makeFixture(prefix: "safe-termination-export")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    fixture.store.createDraft()
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    let buffer = fixture.store.draftBodyEditorBuffer(for: draft.id)
    _ = fixture.store.stageDraftBody("Recovery package current body", for: draft.id, baseRevision: buffer.revision)
    await fixture.store.waitForPendingSave()
    try FileManager.default.removeItem(at: fixture.persistence.fileURL)
    try FileManager.default.createDirectory(at: fixture.persistence.fileURL, withIntermediateDirectories: true)
    guard case .failed = await fixture.store.prepareForSafeTermination() else {
      return XCTFail("A directory at the primary snapshot path must prevent normal exit")
    }
    let destination = fixture.baseURL.appendingPathComponent("Emergency.psworkspacebackup")
    let exported = try await fixture.store.exportSafeTerminationRecovery(at: destination)
    XCTAssertEqual(exported, destination)
    XCTAssertTrue(fixture.store.validatePreparedSafeTermination())
    let preview = try WorkspaceBackupService().inspectBackup(at: exported)
    XCTAssertEqual(preview.unresolvedAttachmentCount, 0)
    let recovered = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from:
      Data(contentsOf: exported.appendingPathComponent(WorkspaceBackupService.workbenchRelativePath)))
    XCTAssertEqual(recovered.drafts.first { $0.id == draft.id }?.bodyMarkdown, "Recovery package current body")
  }

  func testLedgerWriteFailureBlocksNormalExitButRecoveryPackageRetainsEvent() async throws {
    let fixture = try await makeFixture(prefix: "safe-termination-ledger-failure")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    _ = await fixture.store.flushOperationLogPersistence()
    let ledgerURL = fixture.persistence.operationLedgerURL
    if FileManager.default.fileExists(atPath: ledgerURL.path) { try FileManager.default.removeItem(at: ledgerURL) }
    try FileManager.default.createDirectory(at: ledgerURL, withIntermediateDirectories: true)
    let event = WorkbenchOperationEventRecord(kind: .workspaceBackupCreated, outcome: .failed, actor: .user)
    _ = fixture.store.recordOperationEvent(event)
    guard case .failed = await fixture.store.prepareForSafeTermination() else {
      return XCTFail("A failed ledger write must block normal exit")
    }
    XCTAssertFalse(fixture.store.validatePreparedSafeTermination())
    let exported = try await fixture.store.exportSafeTerminationRecovery(
      at: fixture.baseURL.appendingPathComponent("LedgerRecovery.psworkspacebackup"))
    let ledger = try WorkbenchOperationLedgerPersistence.decodedDocument(from:
      Data(contentsOf: exported.appendingPathComponent(WorkspaceBackupService.operationHistoryRelativePath)))
    XCTAssertTrue(ledger.records.contains { $0.id == event.id })
    XCTAssertTrue(fixture.store.validatePreparedSafeTermination())
  }

  func testJournalWriteFailureCannotBeMistakenForSuccessfulExit() async throws {
    let fixture = try await makeFixture(prefix: "safe-termination-journal-failure")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let draft = try XCTUnwrap(fixture.store.selectedDraft)
    let journalURL = fixture.persistence.draftRecoveryJournalURL
    if FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL) }
    try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)
    let buffer = fixture.store.draftBodyEditorBuffer(for: draft.id)
    _ = fixture.store.stageDraftBody("Unpersisted journal text", for: draft.id, baseRevision: buffer.revision)
    guard case .failed = await fixture.store.prepareForSafeTermination() else {
      return XCTFail("A failed recovery journal write must block normal exit")
    }
    XCTAssertFalse(fixture.store.validatePreparedSafeTermination())
    XCTAssertEqual(fixture.store.drafts.first { $0.id == draft.id }?.bodyMarkdown, "Unpersisted journal text")
  }

  func testRecoveryPackageWithUnresolvedAttachmentDoesNotPermitExit() async throws {
    let fixture = try await makeFixture(prefix: "safe-termination-missing-attachment")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    var draft = try XCTUnwrap(fixture.store.selectedDraft)
    draft.attachments = [DraftAttachment(originalFilename: "missing.pdf", relativePublishPath: "/missing.pdf", repositoryPath: "static/missing.pdf")]
    fixture.store.updateDraft(draft)
    do {
      _ = try await fixture.store.exportSafeTerminationRecovery(at: fixture.baseURL.appendingPathComponent("Incomplete.psworkspacebackup"))
      XCTFail("Missing attachments must prevent a verified recovery exit")
    } catch {
      XCTAssertFalse(fixture.store.validatePreparedSafeTermination())
    }
  }

  @MainActor
  private struct Fixture {
    let baseURL: URL
    let repositoryURL: URL
    let persistence: WorkbenchPersistence
    let store: WorkbenchStore

    func documentURL(for draft: ArticleDraft) throws -> URL {
      repositoryURL.appendingPathComponent(try XCTUnwrap(draft.repositoryPath))
    }

    func addDraft(slug: String, body: String) async throws -> ArticleDraft {
      if store.selectedDraft == nil { store.createDraft() }
      var draft = try XCTUnwrap(store.selectedDraft)
      draft.slug = slug
      draft.title = slug
      draft.bodyMarkdown = body
      store.updateDraft(draft)
      let didWrite = await store.writeSiteDraftToProject(draftID: draft.id)
      XCTAssertTrue(didWrite)
      await store.waitForPendingSiteDraftFileWrites()
      return try XCTUnwrap(store.drafts.first { $0.id == draft.id })
    }
  }

  private func makeFixture(prefix: String) async throws -> Fixture {
    let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(prefix)-\(UUID().uuidString)")
    let repositoryURL = baseURL.appendingPathComponent("repository")
    try FileManager.default.createDirectory(
      at: repositoryURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let persistence = WorkbenchPersistence(
      fileURL: baseURL.appendingPathComponent("app-data/workbench.json"))
    let store = makeSafeExitTestStore(persistence: persistence)
    store.updateActiveProfile {
      $0.localRepositoryRootPath = repositoryURL.path
      $0.markdownPathPattern = "content/posts/{slug}.md"
    }
    await store.waitForPendingSave()
    return Fixture(
      baseURL: baseURL,
      repositoryURL: repositoryURL,
      persistence: persistence,
      store: store
    )
  }
}

@MainActor
func makeSafeExitTestStore(persistence: WorkbenchPersistence) -> WorkbenchStore {
  WorkbenchStore(
    persistence: persistence,
    safeMode: true,
    freshWorkspaceSeedPolicy: .blank,
    keychainTokenStore: KeychainTokenStore(
      service: "RepoPress.Tests.SafeExit.\(UUID().uuidString)", accountPrefix: "test", inMemory: true),
    repositoryTokenStore: KeychainTokenStore(service: "RepoPress.Tests.SafeExit.Repository", accountPrefix: "test", inMemory: true),
    deploymentTokenStore: KeychainTokenStore(service: "RepoPress.Tests.SafeExit.Deployment", accountPrefix: "test", inMemory: true),
    siteAnalyticsTokenStore: KeychainTokenStore(service: "RepoPress.Tests.SafeExit.Analytics", accountPrefix: "test", inMemory: true),
    aiDataSharingConsentStore: AIDataSharingConsentStore(
      defaults: UserDefaults(suiteName: "RepoPress.Tests.SafeExit.\(UUID().uuidString)")!))
}
