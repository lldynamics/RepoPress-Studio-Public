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

  func testInvalidBookmarkDoesNotFallBackToStoredPathAheadOfInjectedDataRoot() throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let obsoletePath = harness.rootURL.appendingPathComponent("ObsoleteBackups")
    try persist(
      WorkspaceBackupScheduleSettings(
        destinationPath: obsoletePath.path,
        destinationBookmarkData: Data("invalid-bookmark".utf8)
      ),
      in: harness.defaults
    )
    let codec = WorkbenchDataRootBookmarkCodec(
      create: { _ in Data("unused".utf8) },
      resolve: { _ in throw CocoaError(.fileReadCorruptFile) }
    )

    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL,
      bookmarkCodec: codec
    )

    XCTAssertEqual(scheduler.destinationFolderURL, harness.injectedBackupURL)
  }

  func testStaleBookmarkIsRefreshedAndKeepsExplicitDestination() throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let customURL = harness.rootURL.appendingPathComponent("CustomBackups")
      .standardizedFileURL
    let staleData = Data("stale-bookmark".utf8)
    let refreshedData = Data("refreshed-bookmark".utf8)
    try persist(
      WorkspaceBackupScheduleSettings(
        destinationPath: harness.rootURL.appendingPathComponent("OldPath").path,
        destinationBookmarkData: staleData
      ),
      in: harness.defaults
    )
    let codec = WorkbenchDataRootBookmarkCodec(
      create: { _ in refreshedData },
      resolve: { _ in
        WorkbenchDataRootDecodedBookmark(url: customURL, isStale: true)
      }
    )

    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL,
      bookmarkCodec: codec
    )

    XCTAssertEqual(scheduler.destinationFolderURL, customURL)
    XCTAssertEqual(scheduler.settings.destinationBookmarkData, refreshedData)
    XCTAssertEqual(scheduler.settings.destinationPath, customURL.path)
    let persisted = try loadSettings(from: harness.defaults)
    XCTAssertEqual(persisted.destinationBookmarkData, refreshedData)
    XCTAssertEqual(persisted.destinationPath, customURL.path)
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
