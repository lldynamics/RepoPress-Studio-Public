import Foundation
import PublishingCoreSupport
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingKnowledgeCore
@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchLaunchCoordinatorTests: XCTestCase {
  func testMissingPathStopsBeforeRuntimeCreation() async throws {
    let harness = try makeHarness(rootURL: nil)
    defer { harness.cleanup() }
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      pathStore: harness.pathStore,
      sessionRecovery: harness.sessionRecovery
    )

    XCTAssertNil(coordinator.store)
    XCTAssertNil(coordinator.rssStore)

    await coordinator.start()

    XCTAssertEqual(coordinator.phase, .needsDataRoot)
    XCTAssertNil(coordinator.store)
    XCTAssertNil(coordinator.rssStore)
  }

  func testRememberedRootResolvesPathOffMainActor() async throws {
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
      rootURL: rootURL
    )
    defer { harness.cleanup() }
    try harness.pathStore.rememberRoot(rootURL, dataID: manifest.dataID)
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      pathStore: harness.pathStore,
      sessionRecovery: harness.sessionRecovery
    )

    await coordinator.start()

    XCTAssertEqual(coordinator.phase, .ready)
    XCTAssertEqual(coordinator.dataRootPath, rootURL.path)
    XCTAssertEqual(harness.probeRecorder.mainThreadFlags, [false])
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
    )
    defer { harness.cleanup() }
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      pathStore: harness.pathStore,
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
      try harness.pathStore.storedRecord()?.path,
      rootURL.path
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: parentURL.appendingPathComponent("RepoPress Data 2").path
      )
    )

    harness.sessionRecovery.markCleanExit()
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let restartedCoordinator = WorkbenchLaunchCoordinator(
      pathStore: harness.pathStore,
      sessionRecovery: harness.sessionRecovery
    )
    await restartedCoordinator.start()

    XCTAssertEqual(restartedCoordinator.phase, .ready)
    XCTAssertEqual(restartedCoordinator.dataRootPath, rootURL.path)
    XCTAssertNotNil(restartedCoordinator.store)
    XCTAssertNotNil(restartedCoordinator.rssStore)
  }

  func testRecommendedRootCreatesAndPersistsASeparateRootWithoutReusingExistingData() async throws {
    let parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "launch-recommended-data-root-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: parentURL) }
    try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: false)
    let existingRootURL = parentURL.appendingPathComponent("RepoPress Data", isDirectory: true)
    let existingManifest = try WorkbenchDataRootManifestStore().initializeNewRoot(
      at: existingRootURL,
      appVersion: "test"
    )
    let harness = try makeHarness(rootURL: nil)
    defer { harness.cleanup() }
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      pathStore: harness.pathStore,
      sessionRecovery: harness.sessionRecovery
    )

    await coordinator.createRecommendedDataRoot(in: parentURL)

    let expectedRootURL = parentURL.appendingPathComponent("RepoPress Data 2", isDirectory: true)
    XCTAssertEqual(coordinator.phase, .ready)
    XCTAssertEqual(coordinator.dataRootPath, expectedRootURL.path)
    XCTAssertEqual(try harness.pathStore.storedRecord()?.path, expectedRootURL.path)
    XCTAssertEqual(
      WorkbenchDataRootInspector().probe(at: existingRootURL),
      .existing(existingManifest)
    )
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
    )
    defer { harness.cleanup() }
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      pathStore: harness.pathStore,
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
    )
    defer { harness.cleanup() }
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      pathStore: harness.pathStore,
      sessionRecovery: harness.sessionRecovery
    )

    await coordinator.start()
    await coordinator.restoreExistingDataRoot(at: parentURL)

    XCTAssertEqual(coordinator.phase, .ready)
    XCTAssertEqual(coordinator.dataRootPath, rootURL.path)
    XCTAssertEqual(
      try harness.pathStore.storedRecord()?.path,
      rootURL.path
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
    try harness.pathStore.rememberRoot(rootURL, dataID: manifest.dataID)
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      pathStore: harness.pathStore,
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
    try harness.pathStore.rememberRoot(rootURL, dataID: manifest.dataID)
    harness.sessionRecovery.requestSafeModeOnNextLaunch()
    let coordinator = WorkbenchLaunchCoordinator(
      pathStore: harness.pathStore,
      sessionRecovery: harness.sessionRecovery
    )

    await coordinator.start()

    XCTAssertEqual(coordinator.phase, .needsDataRoot)
    XCTAssertNil(coordinator.store)
    XCTAssertNil(coordinator.rssStore)
    XCTAssertNotNil(coordinator.dataRootMessage)
  }

  func testModuleVisibilityPausesRSSAndRestoresTheExistingRefreshPreference() throws {
    let harness = try makeHarness(rootURL: nil)
    defer { harness.cleanup() }
    let coordinator = WorkbenchLaunchCoordinator(
      pathStore: harness.pathStore,
      sessionRecovery: harness.sessionRecovery
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "module-refresh-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let reader = RSSReaderStore(fileURL: directory.appendingPathComponent("reader.sqlite"))
    defer { reader.stopBackgroundRefresh() }
    harness.defaults.set(true, forKey: RSSReaderUserPreferences.backgroundRefreshEnabledKey)
    harness.defaults.set(60, forKey: RSSReaderUserPreferences.backgroundRefreshIntervalMinutesKey)

    coordinator.startBackgroundRefreshIfNeeded(for: reader, defaults: harness.defaults)
    XCTAssertTrue(reader.isBackgroundRefreshRunning)
    harness.defaults.set(false, forKey: WorkspaceModuleVisibility.rssEnabledKey)
    coordinator.startBackgroundRefreshIfNeeded(for: reader, defaults: harness.defaults)
    XCTAssertFalse(reader.isBackgroundRefreshRunning)
    XCTAssertTrue(RSSReaderUserPreferences.backgroundRefreshEnabled(defaults: harness.defaults))

    harness.defaults.set(true, forKey: WorkspaceModuleVisibility.rssEnabledKey)
    coordinator.startBackgroundRefreshIfNeeded(for: reader, defaults: harness.defaults)
    XCTAssertTrue(reader.isBackgroundRefreshRunning)
    XCTAssertEqual(reader.configuredBackgroundRefreshInterval, 3600)

    harness.defaults.set(false, forKey: RSSReaderUserPreferences.backgroundRefreshEnabledKey)
    coordinator.startBackgroundRefreshIfNeeded(for: reader, defaults: harness.defaults)
    XCTAssertFalse(reader.isBackgroundRefreshRunning)
  }

  private func makeHarness(
    rootURL: URL?
  ) throws -> LaunchCoordinatorHarness {
    let suiteName = "WorkbenchLaunchCoordinatorTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let probeRecorder = PathProbeRecorder()
    let pathStore = WorkbenchDataRootPathStore(
      defaults: defaults,
      storageKey: "selected-root",
      probe: { url in
        probeRecorder.record(isMainThread: Thread.isMainThread)
        return WorkbenchDataRootInspector().probe(at: url)
      }
    )
    return LaunchCoordinatorHarness(
      defaults: defaults,
      suiteName: suiteName,
      pathStore: pathStore,
      probeRecorder: probeRecorder,
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
  let pathStore: WorkbenchDataRootPathStore
  let probeRecorder: PathProbeRecorder
  let sessionRecovery: WorkbenchSessionRecovery

  func cleanup() {
    defaults.removePersistentDomain(forName: suiteName)
  }
}

private final class PathProbeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedMainThreadFlags: [Bool] = []

  var mainThreadFlags: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return storedMainThreadFlags
  }

  func record(isMainThread: Bool) {
    lock.lock()
    storedMainThreadFlags.append(isMainThread)
    lock.unlock()
  }
}

@MainActor
final class SharedInboxIsolationTests: XCTestCase {
  func testNormalRunRetainsInboxAccess() {
    XCTAssertTrue(
      SharedInboxAccessPolicy.allowsAccess(
        environment: [:], isScreenshotBuild: false, isTestProcess: false
      )
    )
  }

  func testScreenshotBuildAndTestHostNeverAccessSharedInbox() {
    XCTAssertFalse(
      SharedInboxAccessPolicy.allowsAccess(
        environment: [:], isScreenshotBuild: true, isTestProcess: false
      )
    )
    XCTAssertFalse(
      SharedInboxAccessPolicy.allowsAccess(
        environment: [:], isScreenshotBuild: false, isTestProcess: true
      )
    )
    XCTAssertFalse(SharedInboxAccessPolicy.isEnabled)
    XCTAssertFalse(ExternalKnowledgeImportCoordinator.shared.isSharedInboxEnabled)
  }

  func testDemoUITestPreviewAndPerformanceFlagsDisableAccess() {
    let isolatedEnvironments: [[String: String]] = [
      ["PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO": "1"],
      ["PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO": "true"],
      ["PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO": "YES"],
      ["PERSONAL_SITE_PUBLISHER_SCREENSHOT_UI_TEST": "1"],
      ["XCODE_RUNNING_FOR_PREVIEWS": "1"],
      ["XCTestConfigurationFilePath": "/temporary/test.xctestconfiguration"],
      ["XCTestBundlePath": "/temporary/test.xctest"],
      ["XCTestSessionIdentifier": "isolated-test"],
      ["CFFIXED_USER_HOME": "/temporary/isolated-home"],
      ["PERSONAL_SITE_PUBLISHER_SCREENSHOT_PERSISTENCE_ROOT": "/temporary/demo"],
      ["PERSONAL_SITE_PUBLISHER_SCREENSHOT_KNOWLEDGE_ROOT": "/temporary/library"],
      ["PERSONAL_SITE_PUBLISHER_PERFORMANCE_PERSISTENCE_ROOT": "/temporary/performance"],
      ["PERSONAL_SITE_PUBLISHER_PERFORMANCE_FIXTURE": "markdown-scroll"],
      ["PERSONAL_SITE_PUBLISHER_PERFORMANCE_FIXTURE": " Markdown-Rich-Scroll "],
    ]
    for environment in isolatedEnvironments {
      XCTAssertFalse(
        SharedInboxAccessPolicy.allowsAccess(
          environment: environment, isScreenshotBuild: false, isTestProcess: false
        ),
        "Unexpected shared inbox access: \(environment)"
      )
    }
  }

  func testDisabledCoordinatorNeverResolvesContainerOrConsumesStagedNote() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    var containerLookupCount = 0
    let coordinator = ExternalKnowledgeImportCoordinator(
      isSharedInboxEnabled: false,
      inboxContainerURL: {
        containerLookupCount += 1
        return fixture.rootURL
      }
    )

    coordinator.install(store: fixture.store)
    // Covers retries and activation/notification scheduling after installation.
    coordinator.scheduleInboxDrain()
    coordinator.scheduleInboxDrain()
    await coordinator.drainTask?.value

    XCTAssertEqual(containerLookupCount, 0)
    XCTAssertNil(coordinator.drainTask)
    XCTAssertNil(coordinator.inboxError)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.entryURL.path))
    let importedNote = await fixture.store.knowledge.note(documentID: fixture.noteID)
    XCTAssertNil(importedNote)
  }

  func testNormalCoordinatorRemovesStagedNoteOnlyAfterSuccessfulImport() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let coordinator = ExternalKnowledgeImportCoordinator(
      isSharedInboxEnabled: true, inboxContainerURL: { fixture.rootURL }
    )
    coordinator.install(store: fixture.store)
    await coordinator.drainTask?.value

    let importedNote = await fixture.store.knowledge.note(documentID: fixture.noteID)
    XCTAssertEqual(importedNote?.markdown, "A note staged in an isolated inbox.")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.entryURL.path))
    XCTAssertNil(coordinator.inboxError)
  }

  func testFailedImportLeavesStagedBytesForRetry() async throws {
    let fixture = try makeFixture(text: "")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let coordinator = ExternalKnowledgeImportCoordinator(
      isSharedInboxEnabled: true, inboxContainerURL: { fixture.rootURL }
    )
    coordinator.install(store: fixture.store)
    await coordinator.drainTask?.value

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.entryURL.path))
    XCTAssertNotNil(coordinator.inboxError)
    let importedNote = await fixture.store.knowledge.note(documentID: fixture.noteID)
    XCTAssertNil(importedNote)
  }

  private func makeFixture(text: String = "A note staged in an isolated inbox.") throws -> Fixture {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SharedInboxIsolationTests-\(UUID().uuidString)", isDirectory: true
    )
    let noteID = UUID()
    let entryURL = rootURL.appendingPathComponent("Inbox/\(noteID.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
    let manifest: [String: Any] = [
      "version": 1, "kind": "note", "title": "Isolated inbox note", "text": text,
    ]
    try JSONSerialization.data(withJSONObject: manifest).write(
      to: entryURL.appendingPathComponent("manifest.json"), options: .atomic
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: rootURL.appendingPathComponent("workbench.json")),
      safeMode: true,
      knowledgeLibraryService: KnowledgeLibraryService(
        rootURL: rootURL.appendingPathComponent("KnowledgeLibrary", isDirectory: true)
      ),
      managedAttachmentFileStore: ManagedAttachmentFileStore(
        rootDirectoryURL: rootURL.appendingPathComponent("ManagedAttachments", isDirectory: true)
      ),
      rssReaderFileURL: rootURL.appendingPathComponent("RSSReader/reader.sqlite"),
      workspaceBackupDirectoryURL: rootURL.appendingPathComponent("Backups", isDirectory: true)
    )
    return Fixture(rootURL: rootURL, entryURL: entryURL, noteID: noteID, store: store)
  }

  private struct Fixture {
    let rootURL: URL
    let entryURL: URL
    let noteID: UUID
    let store: WorkbenchStore
  }
}
