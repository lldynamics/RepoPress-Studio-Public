import Foundation
import PublishingBackupCore
import PublishingCoreSupport
import PublishingKnowledgeCore
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchRestoreStartupSafetyTests: XCTestCase {
  func testSafeModeDoesNotInstallPendingRestore() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try Data(contentsOf: fixture.paths.persistence.fileURL)
    let preparation = WorkbenchLaunchPreparation.prepare(
      paths: fixture.paths, safeMode: true,
      applyWorkspaceRestore: { _ in
        XCTFail("Safe mode must not install a pending restore")
        return .none
      }
    )
    guard case .ready = preparation else { return XCTFail("Original workspace should be readable") }
    XCTAssertEqual(try Data(contentsOf: fixture.paths.persistence.fileURL), before)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: WorkspaceBackupService.pendingRestoreURL(
          for: fixture.paths.persistence.fileURL
        ).path))
  }

  func testUnreadableTransactionLocationBlocksBeforeLoadingSnapshot() throws {
    let fixture = try makeFixture(stageRestore: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let parent = fixture.paths.persistence.fileURL.deletingLastPathComponent()
    let before = try Data(contentsOf: fixture.paths.persistence.fileURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: parent.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    }
    XCTAssertThrowsError(
      try WorkspaceBackupService.hasUnfinishedRestoreTransaction(
        persistenceFileURL: fixture.paths.persistence.fileURL
      ))
    let preparation = WorkbenchLaunchPreparation.prepare(
      paths: fixture.paths, safeMode: true,
      applyWorkspaceRestore: { _ in .none }
    )
    guard case .blocked = preparation else { return XCTFail("Unverifiable transaction must block") }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    XCTAssertEqual(try Data(contentsOf: fixture.paths.persistence.fileURL), before)
  }

  func testFreshRestoreAndRollbackFailureNeverCreatesWritableStores() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let paths = fixture.paths
    let originalBytes = try Data(contentsOf: paths.persistence.fileURL)
    let service = WorkspaceBackupService { checkpoint in
      guard checkpoint == .newDataInstalled else { return }
      let service = WorkspaceBackupService()
      let journal = service.restoreTransactionURL(for: paths.persistence.fileURL)
      let transaction = try JSONDecoder().decode(
        WorkspaceBackupService.RestoreTransaction.self, from: Data(contentsOf: journal)
      )
      let recoveryRoot = service.restoreRecoveryRootURL(
        transactionID: transaction.transactionID,
        parentURL: paths.persistence.fileURL.deletingLastPathComponent()
      )
      // Inject an unexpected recovery item. Rollback must reject it before
      // touching the still-readable newly installed workbench snapshot.
      let blocker = service.restoreItemPaths(
        for: .pendingKnowledgeRestore,
        runtimePaths: .init(
          persistenceFileURL: paths.persistence.fileURL,
          knowledgeRootURL: paths.knowledgeLibraryService.rootURL,
          rssDatabaseURL: paths.rssReaderFileURL,
          attachmentRootURL: paths.managedAttachmentFileStore.rootDirectoryURL
        ),
        recoveryRoot: recoveryRoot
      ).recoveryURL
      try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
      throw CocoaError(.fileWriteUnknown)
    }
    let coordinator = makeCoordinator(fixture: fixture) { paths in
      do {
        guard
          let result = try service.applyPendingRestore(
            persistenceFileURL: paths.persistence.fileURL,
            knowledgeRootURL: paths.knowledgeLibraryService.rootURL,
            rssDatabaseURL: paths.rssReaderFileURL,
            attachmentRootURL: paths.managedAttachmentFileStore.rootDirectoryURL,
            currentApplicationVersion: "test"
          )
        else { return .none }
        return .restored(result)
      } catch { return .failed(error.localizedDescription) }
    }

    await coordinator.start()

    XCTAssertEqual(coordinator.phase, .needsDataRoot)
    XCTAssertNil(coordinator.store)
    XCTAssertNil(coordinator.rssStore)
    XCTAssertEqual(coordinator.dataRootMessageSeverity, .error)
    XCTAssertNotNil(coordinator.dataRootMessage)
    XCTAssertTrue(
      try WorkspaceBackupService.hasUnfinishedRestoreTransaction(
        persistenceFileURL: paths.persistence.fileURL
      ))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.rssReaderFileURL.path))
    XCTAssertNotEqual(try Data(contentsOf: paths.persistence.fileURL), originalBytes)
    XCTAssertEqual(try paths.persistence.load()?.drafts.first?.title, "restored")
  }

  func testInvalidJournalBlocksEvenWithReadableSnapshot() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let persistence = fixture.paths.persistence
    let journal = WorkspaceBackupService().restoreTransactionURL(for: persistence.fileURL)
    try Data("invalid transaction".utf8).write(to: journal)
    let before = try Data(contentsOf: persistence.fileURL)
    let coordinator = makeCoordinator(fixture: fixture)

    await coordinator.start()

    XCTAssertEqual(coordinator.phase, .needsDataRoot)
    XCTAssertNil(coordinator.store)
    XCTAssertNil(coordinator.rssStore)
    XCTAssertEqual(try Data(contentsOf: persistence.fileURL), before)
    XCTAssertEqual(try Data(contentsOf: journal), Data("invalid transaction".utf8))
  }

  func testMissingJournalAllowsOrdinaryStartup() async throws {
    let fixture = try makeFixture(stageRestore: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertFalse(
      try WorkspaceBackupService.hasUnfinishedRestoreTransaction(
        persistenceFileURL: fixture.paths.persistence.fileURL
      ))
    let coordinator = makeCoordinator(fixture: fixture)
    await coordinator.start()
    XCTAssertEqual(coordinator.phase, .ready)
    XCTAssertNotNil(coordinator.store)
    XCTAssertNotNil(coordinator.rssStore)
  }

  private struct Fixture {
    let root: URL
    let paths: WorkbenchRuntimePaths
    let recovery: WorkbenchSessionRecovery
  }

  private func makeFixture(stageRestore: Bool = true) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "restore-startup-safety-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "RestoreStartupSafety.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let target = root.appendingPathComponent("Target", isDirectory: true)
    let paths = WorkbenchRuntimePaths(
      persistence: WorkbenchPersistence(fileURL: target.appendingPathComponent("workbench.json")),
      knowledgeLibraryService: KnowledgeLibraryService(
        rootURL: target.appendingPathComponent("KnowledgeLibrary")),
      rssReaderFileURL: target.appendingPathComponent("RSSReader/reader.sqlite"),
      managedAttachmentFileStore: ManagedAttachmentFileStore(
        rootDirectoryURL: target.appendingPathComponent("ManagedAttachments")),
      workspaceBackupDirectoryURL: target.appendingPathComponent("Backups")
    )
    let profile = SiteProfile.defaultProfile
    var snapshot = WorkbenchSnapshot(
      profiles: [profile], activeProfileID: profile.id,
      drafts: [ArticleDraft(siteProfileID: profile.id, title: "original")], releaseRecords: []
    )
    _ = try paths.persistence.save(snapshot)
    if stageRestore {
      snapshot.drafts[0].title = "restored"
      let backup = root.appendingPathComponent("source.psworkspacebackup")
      let service = WorkspaceBackupService()
      _ = try service.createBackup(
        at: backup, snapshot: snapshot,
        knowledgeRootURL: root.appendingPathComponent("SourceKnowledge"), applicationVersion: "test"
      )
      _ = try service.stageRestore(
        from: backup, persistenceFileURL: paths.persistence.fileURL,
        currentApplicationVersion: "test"
      )
    }
    return Fixture(
      root: root, paths: paths,
      recovery: WorkbenchSessionRecovery(defaults: defaults, keyPrefix: "session"))
  }

  private func makeCoordinator(
    fixture: Fixture,
    applyRestore:
      @escaping @Sendable (WorkbenchRuntimePaths) -> WorkspaceBackupRestoreStartupOutcome =
      WorkbenchLaunchPreparation.applyWorkspaceRestore
  ) -> WorkbenchLaunchCoordinator {
    let paths = fixture.paths
    return WorkbenchLaunchCoordinator(
      persistence: paths.persistence, knowledgeLibraryService: paths.knowledgeLibraryService,
      rssReaderFileURL: paths.rssReaderFileURL,
      managedAttachmentFileStore: paths.managedAttachmentFileStore,
      workspaceBackupDirectoryURL: paths.workspaceBackupDirectoryURL,
      sessionRecovery: fixture.recovery, applyWorkspaceRestore: applyRestore
    )
  }
}
