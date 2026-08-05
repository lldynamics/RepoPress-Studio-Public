import Foundation
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchLaunchCoordinatorTests: XCTestCase {
  func testMissingBookmarkStopsBeforeRuntimeCreation() async throws {
    let harness = try makeHarness(rootURL: nil)
    defer { harness.cleanup() }
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      bookmarkStore: harness.bookmarkStore,
      sessionRecovery: harness.sessionRecovery
    )

    XCTAssertNil(coordinator.store)
    XCTAssertNil(coordinator.rssStore)

    await coordinator.start()

    XCTAssertEqual(coordinator.phase, .needsDataRoot)
    XCTAssertNil(coordinator.store)
    XCTAssertNil(coordinator.rssStore)
  }

  func testRememberedRootResolvesBookmarkOffMainActor() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "launch-off-main-data-root-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    let manifest = try WorkbenchDataRootManifestStore().initializeNewRoot(
      at: rootURL,
      appVersion: "test"
    )
    let harness = try makeHarness(
      rootURL: rootURL,
      resolveMustBeOffMainActor: true
    )
    defer { harness.cleanup() }
    try harness.bookmarkStore.rememberSelectedRoot(rootURL, dataID: manifest.dataID)
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      bookmarkStore: harness.bookmarkStore,
      sessionRecovery: harness.sessionRecovery
    )

    await coordinator.start()

    XCTAssertEqual(coordinator.phase, .ready)
    XCTAssertEqual(coordinator.dataRootPath, rootURL.path)
  }

  func testCreatingFreshRootFromSelectedParentEntersReadyAndReopens() async throws {
    let parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "launch-create-data-root-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: parentURL) }
    try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: false)
    let rootURL = parentURL.appendingPathComponent("RepoPress Data", isDirectory: true)
    let harness = try makeHarness(
      rootURL: rootURL,
      bookmarkResolvedURL: parentURL
    )
    defer { harness.cleanup() }
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      bookmarkStore: harness.bookmarkStore,
      sessionRecovery: harness.sessionRecovery
    )

    await coordinator.start()
    XCTAssertEqual(coordinator.phase, .needsDataRoot)

    await coordinator.createNewDataRoot(in: parentURL)

    XCTAssertEqual(coordinator.phase, .ready)
    XCTAssertEqual(coordinator.dataRootPath, rootURL.path)
    XCTAssertNotNil(coordinator.store)
    XCTAssertNotNil(coordinator.rssStore)
    XCTAssertEqual(
      try harness.bookmarkStore.storedRecord()?.relativeRootPath,
      "RepoPress Data"
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: parentURL.appendingPathComponent("RepoPress Data 2").path
      )
    )

    harness.sessionRecovery.markCleanExit()
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let restartedCoordinator = WorkbenchLaunchCoordinator(
      bookmarkStore: harness.bookmarkStore,
      sessionRecovery: harness.sessionRecovery
    )
    await restartedCoordinator.start()

    XCTAssertEqual(restartedCoordinator.phase, .ready)
    XCTAssertEqual(restartedCoordinator.dataRootPath, rootURL.path)
    XCTAssertNotNil(restartedCoordinator.store)
    XCTAssertNotNil(restartedCoordinator.rssStore)
  }

  func testCreatingFreshRootReusesEmptyFolderLeftByExternalVolumeFailure() async throws {
    let parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "launch-retry-external-root-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: parentURL) }
    try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: false)
    let rootURL = parentURL.appendingPathComponent("RepoPress Data", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    try Data().write(to: rootURL.appendingPathComponent("._failed-stage"))
    let harness = try makeHarness(
      rootURL: rootURL,
      bookmarkResolvedURL: parentURL
    )
    defer { harness.cleanup() }
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      bookmarkStore: harness.bookmarkStore,
      sessionRecovery: harness.sessionRecovery
    )

    await coordinator.start()
    await coordinator.createNewDataRoot(in: parentURL)

    XCTAssertEqual(coordinator.phase, .ready)
    XCTAssertEqual(coordinator.dataRootPath, rootURL.path)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: parentURL.appendingPathComponent("RepoPress Data 2").path
      )
    )
  }

  func testMigrationDestinationSkipsEmptyFolderLeftByExternalVolumeFailure() throws {
    let parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "launch-migration-external-root-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: parentURL) }
    try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: false)
    let failedRootURL = parentURL.appendingPathComponent("RepoPress Data", isDirectory: true)
    try FileManager.default.createDirectory(at: failedRootURL, withIntermediateDirectories: false)
    try Data().write(to: failedRootURL.appendingPathComponent("._failed-stage"))

    let destinationURL = WorkbenchLaunchCoordinator.availableDataRootURL(
      in: parentURL,
      reuseEmptyExistingRoot: false
    )

    XCTAssertEqual(destinationURL.lastPathComponent, "RepoPress Data 2")
    XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
  }

  func testRestoreAcceptsContainingExternalDriveFolder() async throws {
    let parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "launch-restore-containing-folder-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: parentURL) }
    try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: false)
    let rootURL = parentURL.appendingPathComponent("RepoPress Data", isDirectory: true)
    _ = try WorkbenchDataRootManifestStore().initializeNewRoot(
      at: rootURL,
      appVersion: "test"
    )
    let harness = try makeHarness(
      rootURL: rootURL,
      bookmarkResolvedURL: parentURL
    )
    defer { harness.cleanup() }
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      bookmarkStore: harness.bookmarkStore,
      sessionRecovery: harness.sessionRecovery
    )

    await coordinator.start()
    await coordinator.restoreExistingDataRoot(at: parentURL)

    XCTAssertEqual(coordinator.phase, .ready)
    XCTAssertEqual(coordinator.dataRootPath, rootURL.path)
    XCTAssertEqual(
      try harness.bookmarkStore.storedRecord()?.relativeRootPath,
      "RepoPress Data"
    )
  }

  func testRememberedRootInjectsEveryDurableRuntimePathAndStartsNormally() async throws {
    let parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "launch-data-root-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: parentURL) }
    try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: false)
    let rootURL = parentURL.appendingPathComponent("RepoPress Data", isDirectory: true)
    let manifest = try WorkbenchDataRootManifestStore().initializeNewRoot(
      at: rootURL,
      appVersion: "test"
    )
    let harness = try makeHarness(rootURL: rootURL)
    defer { harness.cleanup() }
    try harness.bookmarkStore.rememberSelectedRoot(rootURL, dataID: manifest.dataID)
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      bookmarkStore: harness.bookmarkStore,
      sessionRecovery: harness.sessionRecovery
    )

    await coordinator.start()

    let layout = WorkbenchDataRootLayout(rootURL: rootURL)
    let store = try XCTUnwrap(coordinator.store)
    XCTAssertEqual(coordinator.phase, .ready)
    XCTAssertFalse(store.isSafeMode)
    XCTAssertEqual(coordinator.dataRootPath, rootURL.path)
    XCTAssertEqual(coordinator.rssStore?.fileURL, layout.rssReaderDatabaseURL)
    XCTAssertEqual(store.rssReaderFileURL, layout.rssReaderDatabaseURL)
    XCTAssertEqual(
      store.managedAttachmentFileStore.rootDirectoryURL,
      layout.managedAttachmentsURL
    )
    XCTAssertEqual(store.persistenceStore.persistence.fileURL, layout.workbenchFileURL)
    XCTAssertEqual(
      store.workspaceBackupDirectoryURL,
      rootURL.appendingPathComponent(
        WorkspaceBackupService.automaticBackupDirectoryName,
        isDirectory: true
      )
    )
  }

  func testFailedWorkspaceRestoreDoesNotApplyStandaloneKnowledgeRestore() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "launch-failed-workspace-restore-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)

    let sourceKnowledgeURL = rootURL.appendingPathComponent("SourceKnowledge", isDirectory: true)
    let targetKnowledgeURL = rootURL.appendingPathComponent("KnowledgeLibrary", isDirectory: true)
    let knowledgeBackupURL = rootURL.appendingPathComponent(
      "knowledge.pslibrarybackup",
      isDirectory: true
    )
    let sourceKnowledge = KnowledgeLibraryService(rootURL: sourceKnowledgeURL)
    _ = try sourceKnowledge.createFolder(name: "待恢复资料")
    _ = try await sourceKnowledge.createBackup(
      at: knowledgeBackupURL,
      applicationVersion: "test"
    )
    let targetKnowledge = KnowledgeLibraryService(rootURL: targetKnowledgeURL)
    _ = try await targetKnowledge.stageRestore(from: knowledgeBackupURL)
    let pendingKnowledgeURL = KnowledgeLibraryBackupService.pendingRestoreURL(
      for: targetKnowledgeURL
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingKnowledgeURL.path))

    let persistence = WorkbenchPersistence(
      fileURL: rootURL.appendingPathComponent("Workbench/workbench.json")
    )
    let pendingWorkspaceURL = WorkspaceBackupService.pendingRestoreURL(
      for: persistence.fileURL
    )
    try FileManager.default.createDirectory(
      at: pendingWorkspaceURL,
      withIntermediateDirectories: true
    )
    try Data("invalid workspace restore".utf8).write(
      to: pendingWorkspaceURL.appendingPathComponent("manifest.json"),
      options: .atomic
    )

    let suiteName = "WorkbenchLaunchCoordinatorTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let sessionRecovery = WorkbenchSessionRecovery(
      defaults: defaults,
      keyPrefix: "launch-session"
    )
    let coordinator = WorkbenchLaunchCoordinator(
      persistence: persistence,
      knowledgeLibraryService: targetKnowledge,
      rssReaderFileURL: rootURL.appendingPathComponent("RSSReader/reader.sqlite"),
      managedAttachmentFileStore: ManagedAttachmentFileStore(
        rootDirectoryURL: rootURL.appendingPathComponent("ManagedAttachments")
      ),
      workspaceBackupDirectoryURL: rootURL.appendingPathComponent("WorkspaceBackups"),
      sessionRecovery: sessionRecovery
    )

    await coordinator.start()

    XCTAssertEqual(coordinator.phase, .ready)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: pendingKnowledgeURL.path),
      "工作区恢复失败后应保留独立资料库恢复包，留待后续处理。"
    )
  }

  func testCancelledStartCanBeRetried() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "launch-cancelled-start-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    let suiteName = "WorkbenchLaunchCoordinatorTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let sessionRecovery = WorkbenchSessionRecovery(
      defaults: defaults,
      keyPrefix: "launch-session"
    )
    sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      persistence: WorkbenchPersistence(
        fileURL: rootURL.appendingPathComponent("Workbench/workbench.json")
      ),
      knowledgeLibraryService: KnowledgeLibraryService(
        rootURL: rootURL.appendingPathComponent("KnowledgeLibrary")
      ),
      rssReaderFileURL: rootURL.appendingPathComponent("RSSReader/reader.sqlite"),
      managedAttachmentFileStore: ManagedAttachmentFileStore(
        rootDirectoryURL: rootURL.appendingPathComponent("ManagedAttachments")
      ),
      workspaceBackupDirectoryURL: rootURL.appendingPathComponent("WorkspaceBackups"),
      sessionRecovery: sessionRecovery
    )

    let cancelledStart = Task { await coordinator.start() }
    cancelledStart.cancel()
    await cancelledStart.value
    XCTAssertNil(coordinator.store)

    await coordinator.start()

    XCTAssertEqual(coordinator.phase, .ready)
    XCTAssertNotNil(coordinator.store)
  }

  func testInterruptedRestoreMarkerMustRecoverBeforeHealthyRootCanOpen() async throws {
    let parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "launch-interrupted-restore-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: parentURL) }
    try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: false)
    let rootURL = parentURL.appendingPathComponent("RepoPress Data", isDirectory: true)
    let manifest = try WorkbenchDataRootManifestStore().initializeNewRoot(
      at: rootURL,
      appVersion: "test"
    )
    // The ordinary root probe still succeeds here. Launch must nevertheless
    // inspect the transaction marker before opening any durable service.
    try Data("invalid transaction".utf8).write(
      to: rootURL.appendingPathComponent(
        WorkspaceBackupService.restoreTransactionFileName,
        isDirectory: false
      )
    )

    let harness = try makeHarness(rootURL: rootURL)
    defer { harness.cleanup() }
    try harness.bookmarkStore.rememberSelectedRoot(rootURL, dataID: manifest.dataID)
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      bookmarkStore: harness.bookmarkStore,
      sessionRecovery: harness.sessionRecovery
    )

    await coordinator.start()

    XCTAssertEqual(coordinator.phase, .needsDataRoot)
    XCTAssertNil(coordinator.store)
    XCTAssertNil(coordinator.rssStore)
    XCTAssertNotNil(coordinator.dataRootMessage)
  }

  private func makeHarness(
    rootURL: URL?,
    bookmarkResolvedURL: URL? = nil,
    resolveMustBeOffMainActor: Bool = false
  ) throws -> LaunchCoordinatorHarness {
    let suiteName = "WorkbenchLaunchCoordinatorTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let bookmarkStore = WorkbenchDataRootBookmarkStore(
      defaults: defaults,
      storageKey: "selected-root",
      codec: WorkbenchDataRootBookmarkCodec(
        create: { _ in Data("bookmark".utf8) },
        resolve: { _ in
          if resolveMustBeOffMainActor, Thread.isMainThread {
            throw NSError(
              domain: "WorkbenchLaunchCoordinatorTests",
              code: 1,
              userInfo: [NSLocalizedDescriptionKey: "bookmark resolution ran on the main thread"]
            )
          }
          guard let resolvedURL = bookmarkResolvedURL ?? rootURL else {
            throw CocoaError(.fileNoSuchFile)
          }
          return WorkbenchDataRootDecodedBookmark(url: resolvedURL, isStale: false)
        }
      ),
      securityScope: WorkbenchDataRootSecurityScope(
        start: { _ in true },
        stop: { _ in }
      )
    )
    return LaunchCoordinatorHarness(
      defaults: defaults,
      suiteName: suiteName,
      bookmarkStore: bookmarkStore,
      sessionRecovery: WorkbenchSessionRecovery(
        defaults: defaults,
        keyPrefix: "launch-session"
      )
    )
  }
}

private struct LaunchCoordinatorHarness {
  let defaults: UserDefaults
  let suiteName: String
  let bookmarkStore: WorkbenchDataRootBookmarkStore
  let sessionRecovery: WorkbenchSessionRecovery

  func cleanup() {
    defaults.removePersistentDomain(forName: suiteName)
  }
}
