import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkspaceBackupSchedulerTests: XCTestCase {
  func testLegacyDefaultPathDoesNotOverrideInjectedDataRootBackupDirectory() throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let legacyDefaultURL = WorkspaceBackupService.defaultAutomaticBackupDirectoryURL()
    try persist(
      WorkspaceBackupScheduleSettings(destinationPath: legacyDefaultURL.path),
      in: harness.defaults
    )

    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )

    XCTAssertEqual(scheduler.destinationFolderURL, harness.injectedBackupURL)
  }

  func testStoredDestinationPathTakesPriorityOverInjectedDataRootBackupDirectory() throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let selectedURL = harness.rootURL.appendingPathComponent("SelectedBackups")
    try persist(
      WorkspaceBackupScheduleSettings(destinationPath: selectedURL.path),
      in: harness.defaults
    )

    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )

    XCTAssertEqual(scheduler.destinationFolderURL, selectedURL.standardizedFileURL)
  }

  func testSetDestinationFolderStoresStandardizedPathAndPersists() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let customURL = harness.rootURL
      .appendingPathComponent("Nested", isDirectory: true)
      .appendingPathComponent("..", isDirectory: true)
      .appendingPathComponent("CustomBackups", isDirectory: true)
    let standardizedURL = customURL.standardizedFileURL

    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )
    try scheduler.setDestinationFolder(customURL)
    await scheduler.refreshRecentBackups()

    XCTAssertEqual(scheduler.destinationFolderURL.path, standardizedURL.path)
    XCTAssertEqual(scheduler.settings.destinationPath, standardizedURL.path)
    let persisted = try loadSettings(from: harness.defaults)
    XCTAssertEqual(persisted.destinationPath, standardizedURL.path)
  }

  func testAutomaticBackupRefreshBoundsOwnedPackagesWithoutRemovingManualPackages() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    try FileManager.default.createDirectory(
      at: harness.injectedBackupURL,
      withIntermediateDirectories: true
    )
    for index in 0..<(WorkspaceBackupScheduler.automaticRetentionCount + 2) {
      let url = harness.injectedBackupURL.appendingPathComponent(
        "\(WorkspaceBackupService.automaticBackupFilePrefix)20260804-\(String(format: "%06d", index)).psworkspacebackup",
        isDirectory: true
      )
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try Data("automatic-\(index)".utf8).write(to: url.appendingPathComponent("payload"))
    }
    let manualURL = harness.injectedBackupURL.appendingPathComponent(
      "manual-backup.psworkspacebackup",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: manualURL, withIntermediateDirectories: true)

    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )
    await scheduler.refreshRecentBackups()

    let remaining = try FileManager.default.contentsOfDirectory(
      at: harness.injectedBackupURL,
      includingPropertiesForKeys: nil,
      options: []
    )
    let automatic = remaining.filter {
      $0.lastPathComponent.hasPrefix(WorkspaceBackupService.automaticBackupFilePrefix)
    }
    XCTAssertEqual(automatic.count, WorkspaceBackupScheduler.automaticRetentionCount)
    XCTAssertTrue(FileManager.default.fileExists(atPath: manualURL.path))
  }

  func testRefreshPublishesStructuredSuccessStatus() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    try FileManager.default.createDirectory(
      at: harness.injectedBackupURL,
      withIntermediateDirectories: true
    )
    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )

    await scheduler.refreshRecentBackups()

    XCTAssertEqual(scheduler.statusLevel, .success)
    XCTAssertNotNil(scheduler.statusMessage)
  }

  func testRefreshFailurePublishesStructuredErrorStatus() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    try Data("not-a-directory".utf8).write(to: harness.injectedBackupURL)
    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )

    await scheduler.refreshRecentBackups()

    XCTAssertEqual(scheduler.statusLevel, .error)
    XCTAssertNotNil(scheduler.statusMessage)
  }

  private func makeHarness() throws -> WorkspaceBackupSchedulerHarness {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workspace-backup-scheduler-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    let suiteName = "WorkspaceBackupSchedulerTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let injectedBackupURL = rootURL.appendingPathComponent(
      WorkspaceBackupService.automaticBackupDirectoryName,
      isDirectory: true
    ).standardizedFileURL
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: rootURL.appendingPathComponent("Workbench/workbench.json")
      ),
      initialSnapshotSource: .preloaded(WorkbenchSnapshotLoadResult(snapshot: nil)),
      safeMode: true,
      freshWorkspaceSeedPolicy: .blank,
      knowledgeLibraryService: KnowledgeLibraryService(
        rootURL: rootURL.appendingPathComponent("KnowledgeLibrary")
      ),
      managedAttachmentFileStore: ManagedAttachmentFileStore(
        rootDirectoryURL: rootURL.appendingPathComponent("ManagedAttachments")
      ),
      rssReaderFileURL: rootURL.appendingPathComponent("RSSReader/reader.sqlite"),
      workspaceBackupDirectoryURL: injectedBackupURL
    )
    return WorkspaceBackupSchedulerHarness(
      rootURL: rootURL,
      suiteName: suiteName,
      defaults: defaults,
      injectedBackupURL: injectedBackupURL,
      store: store
    )
  }

  private func persist(
    _ settings: WorkspaceBackupScheduleSettings,
    in defaults: UserDefaults
  ) throws {
    defaults.set(
      try JSONEncoder().encode(settings),
      forKey: WorkspaceBackupScheduler.settingsKey
    )
  }

  private func loadSettings(
    from defaults: UserDefaults
  ) throws -> WorkspaceBackupScheduleSettings {
    let data = try XCTUnwrap(
      defaults.data(forKey: WorkspaceBackupScheduler.settingsKey)
    )
    return try JSONDecoder().decode(WorkspaceBackupScheduleSettings.self, from: data)
  }
}

private struct WorkspaceBackupSchedulerHarness {
  let rootURL: URL
  let suiteName: String
  let defaults: UserDefaults
  let injectedBackupURL: URL
  let store: WorkbenchStore

  func cleanup() {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: rootURL)
  }
}
