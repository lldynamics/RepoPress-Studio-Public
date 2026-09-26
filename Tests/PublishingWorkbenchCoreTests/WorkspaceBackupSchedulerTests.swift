import Foundation
import PublishingBackupCore
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkspaceBackupSchedulerTests: XCTestCase {
  func testContentFingerprintIgnoresAutomaticBackupEventsAndNestedManifestTime() throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let scheduler = WorkspaceBackupScheduler(
      store: harness.store, defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )
    let service = WorkspaceBackupService()
    let profile = SiteProfile.defaultProfile
    let snapshot = WorkbenchSnapshot(
      profiles: [profile], activeProfileID: profile.id, drafts: [], releaseRecords: []
    )
    let knowledgeRootURL = harness.rootURL.appendingPathComponent("KnowledgeLibrary")
    let userEvent = WorkbenchOperationEventRecord(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
      kind: .siteImport, outcome: .succeeded, actor: .user,
      occurredAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    let automaticEvent = WorkbenchOperationEventRecord(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
      kind: .workspaceBackupCreated, outcome: .succeeded, actor: .background,
      occurredAt: Date(timeIntervalSince1970: 1_700_000_002)
    )
    let manualEvent = WorkbenchOperationEventRecord(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
      kind: .knowledgeImport, outcome: .succeeded, actor: .user,
      occurredAt: Date(timeIntervalSince1970: 1_700_000_003)
    )
    let documents = [
      WorkbenchOperationLedgerDocument(retentionPolicy: .forever, records: [userEvent]),
      WorkbenchOperationLedgerDocument(
        retentionPolicy: .forever, records: [userEvent, automaticEvent]
      ),
      WorkbenchOperationLedgerDocument(
        retentionPolicy: .forever, records: [userEvent, automaticEvent, manualEvent]
      ),
    ]
    let packages = documents.enumerated().map { index, _ in
      harness.rootURL.appendingPathComponent("backup-\(index).psworkspacebackup")
    }
    for (index, item) in zip(packages, documents).enumerated() {
      let (url, document) = item
      if index > 0 {
        // The nested manifest timestamp is serialized at whole-second precision.
        Thread.sleep(forTimeInterval: 1.1)
      }
      _ = try service.createBackup(
        at: url, snapshot: snapshot,
        operationHistoryDocument: document,
        knowledgeRootURL: knowledgeRootURL,
        applicationVersion: "test",
        selectedCategories: [.workbench, .knowledgeLibrary, .operationHistory]
      )
    }
    let knowledgeManifestPath = "\(WorkspaceBackupService.knowledgePackageName)/manifest.json"
    let firstNestedManifest = try Data(contentsOf: packages[0].appendingPathComponent(knowledgeManifestPath))
    let secondNestedManifest = try Data(contentsOf: packages[1].appendingPathComponent(knowledgeManifestPath))
    XCTAssertNotEqual(firstNestedManifest, secondNestedManifest,
      "nested knowledge manifests should differ by creation time")
    XCTAssertEqual(
      scheduler.manifestContentFingerprint(at: packages[0]),
      scheduler.manifestContentFingerprint(at: packages[1])
    )
    XCTAssertNotEqual(
      scheduler.manifestContentFingerprint(at: packages[1]),
      scheduler.manifestContentFingerprint(at: packages[2]),
      "a real user operation must still produce a new fingerprint"
    )
  }

  func testRealStoreBackupsWithKnowledgeAndHistoryHaveStableFingerprint() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    // Compare two idle snapshots only after startup has opened and migrated
    // the library; an initialization write is a real content change.
    await harness.store.knowledge.reload()
    let scheduler = WorkspaceBackupScheduler(
      store: harness.store, defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )
    let selectedCategories: Set<WorkspaceBackupCategory> = [
      .knowledgeLibrary, .operationHistory,
    ]
    let firstURL = harness.rootURL.appendingPathComponent("real-first.psworkspacebackup")
    let secondURL = harness.rootURL.appendingPathComponent("real-second.psworkspacebackup")

    let firstPreview = await harness.store.createWorkspaceBackup(
      at: firstURL, applicationVersion: "test", actor: .background,
      selectedCategories: selectedCategories
    )
    XCTAssertNotNil(firstPreview)
    // Knowledge backup manifests use whole-second timestamps. Cross that
    // boundary so this exercises normalization against real service output.
    try await Task.sleep(for: .milliseconds(1_100))
    let secondPreview = await harness.store.createWorkspaceBackup(
      at: secondURL, applicationVersion: "test", actor: .background,
      selectedCategories: selectedCategories
    )
    XCTAssertNotNil(secondPreview)

    let firstFingerprint = scheduler.manifestContentFingerprint(at: firstURL)
    let secondFingerprint = scheduler.manifestContentFingerprint(at: secondURL)
    let diagnostic = firstFingerprint == secondFingerprint ? "" : [
      "first fingerprint: \(firstFingerprint ?? "nil")",
      "second fingerprint: \(secondFingerprint ?? "nil")",
      "first manifest records (path|bytes|sha256): \(manifestRecordDiagnostics(at: firstURL))",
      "second manifest records (path|bytes|sha256): \(manifestRecordDiagnostics(at: secondURL))",
    ].joined(separator: "\n")
    XCTAssertEqual(
      firstFingerprint,
      secondFingerprint,
      "real unchanged KnowledgeLibrary and operation history should not retrigger snapshots. \(diagnostic)"
    )
  }

  private func manifestRecordDiagnostics(at packageURL: URL) -> String {
    let manifestURL = packageURL.appendingPathComponent(WorkspaceBackupService.manifestFileName)
    guard let data = try? Data(contentsOf: manifestURL) else { return "<manifest unavailable>" }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let manifest = try? decoder.decode(WorkspaceBackupManifest.self, from: data) else {
      return "<manifest invalid>"
    }
    return manifest.files.sorted { $0.relativePath < $1.relativePath }.map { record in
      "\(record.relativePath)|\(record.byteCount)|\(record.sha256)"
    }.joined(separator: "; ")
  }

  func testCloudUploadConfirmationRequiresEveryDeclaredFile() {
    XCTAssertEqual(
      WorkspaceBackupScheduler.confirmedCloudUploadStatus(
        isUbiquitousPackage: true, declaredFileUploadStates: [true, true, true]
      ),
      .uploadConfirmed
    )
    XCTAssertEqual(
      WorkspaceBackupScheduler.confirmedCloudUploadStatus(
        isUbiquitousPackage: true, declaredFileUploadStates: [true, false]
      ),
      .waitingForUpload
    )
    XCTAssertEqual(
      WorkspaceBackupScheduler.confirmedCloudUploadStatus(
        isUbiquitousPackage: true, declaredFileUploadStates: [true, nil]
      ),
      .waitingForUpload
    )
    XCTAssertEqual(
      WorkspaceBackupScheduler.confirmedCloudUploadStatus(
        isUbiquitousPackage: false, declaredFileUploadStates: [nil]
      ),
      .iCloudFileUnrecognized
    )
  }

  func testNoBackupDoesNotReportLocalCompletion() throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let scheduler = makeScheduler(harness)

    XCTAssertEqual(scheduler.cloudUploadStatus, .noBackup)
    scheduler.refreshCloudUploadStatus()
    XCTAssertEqual(scheduler.cloudUploadStatus, .noBackup)
  }

  func testLocalBackupReportsCompletedStatusAfterRefresh() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let scheduler = makeScheduler(harness)

    await scheduler.runBackupNow()
    XCTAssertNotNil(scheduler.settings.lastBackupPath)
    XCTAssertEqual(scheduler.cloudUploadStatus, .localCopyComplete)
    scheduler.refreshCloudUploadStatus()
    XCTAssertEqual(scheduler.cloudUploadStatus, .localCopyComplete)
  }

  func testMissingOrNonDirectoryBackupDoesNotReportLocalCompletion() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let scheduler = makeScheduler(harness)
    await scheduler.runBackupNow()
    let path = try XCTUnwrap(scheduler.settings.lastBackupPath)
    let packageURL = URL(fileURLWithPath: path)

    try FileManager.default.removeItem(at: packageURL)
    scheduler.refreshCloudUploadStatus()
    XCTAssertEqual(scheduler.cloudUploadStatus, .noBackup)

    try Data("not a backup package".utf8).write(to: packageURL)
    scheduler.refreshCloudUploadStatus()
    XCTAssertEqual(scheduler.cloudUploadStatus, .backupUnavailable)

    try FileManager.default.removeItem(at: packageURL)
    try FileManager.default.removeItem(at: packageURL.deletingLastPathComponent())
    scheduler.refreshCloudUploadStatus()
    XCTAssertEqual(scheduler.cloudUploadStatus, .backupUnavailable)
  }

  func testDamagedLocalManifestDoesNotReportLocalCompletion() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let scheduler = makeScheduler(harness)
    await scheduler.runBackupNow()
    let path = try XCTUnwrap(scheduler.settings.lastBackupPath)
    let manifestURL = URL(fileURLWithPath: path).appendingPathComponent(
      WorkspaceBackupService.manifestFileName)

    try Data("{ damaged manifest".utf8).write(to: manifestURL)
    scheduler.refreshCloudUploadStatus()
    XCTAssertEqual(scheduler.cloudUploadStatus, .manifestCorrupt)

    try FileManager.default.removeItem(at: manifestURL)
    scheduler.refreshCloudUploadStatus()
    XCTAssertEqual(scheduler.cloudUploadStatus, .manifestCorrupt)
  }

  func testICloudDestinationWithoutUbiquitousPackageIsUnconfirmed() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let localScheduler = makeScheduler(harness)
    await localScheduler.runBackupNow()
    XCTAssertNotNil(localScheduler.settings.lastBackupPath)

    var settings = try loadSettings(from: harness.defaults)
    settings.destinationPath = harness.injectedBackupURL.path
    settings.destinationIsICloud = true
    try persist(settings, in: harness.defaults)
    let cloudScheduler = WorkspaceBackupScheduler(
      store: harness.store, defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )

    cloudScheduler.refreshCloudUploadStatus()
    XCTAssertEqual(cloudScheduler.cloudUploadStatus, .iCloudFileUnrecognized)
  }

  func testChangingToICloudDestinationDoesNotRelabelPreviousLocalBackup() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let localScheduler = makeScheduler(harness)
    await localScheduler.runBackupNow()
    XCTAssertNotNil(localScheduler.settings.lastBackupPath)

    var settings = try loadSettings(from: harness.defaults)
    settings.destinationPath = harness.rootURL.appendingPathComponent("NewICloudTarget").path
    settings.destinationIsICloud = true
    try persist(settings, in: harness.defaults)
    let switchedScheduler = WorkspaceBackupScheduler(
      store: harness.store, defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )

    switchedScheduler.refreshCloudUploadStatus()
    XCTAssertEqual(switchedScheduler.cloudUploadStatus, .localCopyComplete)
  }

  func testCorruptICloudManifestReportsDamageInsteadOfWaiting() throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let packageURL = harness.injectedBackupURL.appendingPathComponent(
      "damaged.psworkspacebackup", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try persist(
      WorkspaceBackupScheduleSettings(
        destinationPath: harness.injectedBackupURL.path,
        lastBackupPath: packageURL.path,
        destinationIsICloud: true
      ),
      in: harness.defaults
    )
    let scheduler = WorkspaceBackupScheduler(
      store: harness.store, defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )

    scheduler.refreshCloudUploadStatus()
    XCTAssertEqual(scheduler.cloudUploadStatus, .waitingForUpload)

    try Data("{ damaged manifest".utf8).write(
      to: packageURL.appendingPathComponent(WorkspaceBackupService.manifestFileName))
    scheduler.refreshCloudUploadStatus()
    XCTAssertEqual(scheduler.cloudUploadStatus, .manifestCorrupt)
  }

  func testOversizedICloudManifestReportsDamageEvenWhenJSONIsValid() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let localScheduler = makeScheduler(harness)
    await localScheduler.runBackupNow()
    let path = try XCTUnwrap(localScheduler.settings.lastBackupPath)
    let manifestURL = URL(fileURLWithPath: path).appendingPathComponent(
      WorkspaceBackupService.manifestFileName)
    var manifestData = try Data(contentsOf: manifestURL)
    let maximumByteCount = WorkspaceBackupService.Limits().maximumManifestByteCount
    XCTAssertLessThan(manifestData.count, maximumByteCount)
    manifestData.append(Data(repeating: 0x20, count: maximumByteCount + 1 - manifestData.count))
    try manifestData.write(to: manifestURL)

    var settings = try loadSettings(from: harness.defaults)
    settings.destinationPath = harness.injectedBackupURL.path
    settings.destinationIsICloud = true
    try persist(settings, in: harness.defaults)
    let scheduler = WorkspaceBackupScheduler(
      store: harness.store, defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )

    scheduler.refreshCloudUploadStatus()
    XCTAssertEqual(scheduler.cloudUploadStatus, .manifestCorrupt)
  }

  func testNonRegularICloudManifestReportsDamageInsteadOfWaiting() throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let packageURL = harness.injectedBackupURL.appendingPathComponent(
      "nonregular.psworkspacebackup", isDirectory: true)
    let manifestURL = packageURL.appendingPathComponent(WorkspaceBackupService.manifestFileName)
    try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: true)
    try persist(
      WorkspaceBackupScheduleSettings(
        destinationPath: harness.injectedBackupURL.path,
        lastBackupPath: packageURL.path,
        destinationIsICloud: true
      ), in: harness.defaults)
    let scheduler = WorkspaceBackupScheduler(
      store: harness.store, defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL)

    scheduler.refreshCloudUploadStatus()
    XCTAssertEqual(scheduler.cloudUploadStatus, .manifestCorrupt)

    try FileManager.default.removeItem(at: manifestURL)
    try FileManager.default.createSymbolicLink(
      at: manifestURL, withDestinationURL: packageURL.appendingPathComponent("missing.json"))
    scheduler.refreshCloudUploadStatus()
    XCTAssertEqual(scheduler.cloudUploadStatus, .manifestCorrupt)
  }

  func testBackupURLSelectionSkipsExistingPackagePath() throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let existingURL = harness.rootURL.appendingPathComponent("collision.psworkspacebackup")
    try FileManager.default.createDirectory(at: existingURL, withIntermediateDirectories: true)
    let markerURL = existingURL.appendingPathComponent("keep.txt")
    try Data("existing snapshot".utf8).write(to: markerURL)

    var names = ["collision.psworkspacebackup", "fresh.psworkspacebackup"]
    let selectedURL = WorkspaceBackupScheduler.nextAvailableBackupURL(
      in: harness.rootURL, fileManager: .default
    ) {
      names.removeFirst()
    }

    XCTAssertEqual(selectedURL.lastPathComponent, "fresh.psworkspacebackup")
    XCTAssertEqual(try Data(contentsOf: markerURL), Data("existing snapshot".utf8))
  }

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

  func testAutomaticBackupRefreshDoesNotRemoveAutomaticOrManualPackages() async throws {
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
    XCTAssertEqual(automatic.count, WorkspaceBackupScheduler.automaticRetentionCount + 2)
    XCTAssertTrue(FileManager.default.fileExists(atPath: manualURL.path))
  }

  func testSelectedDiskOptInPreservesSnapshotsDuringRefreshAndManualBackup() async throws {
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
    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )
    try scheduler.setDestinationFolder(harness.injectedBackupURL)
    XCTAssertTrue(scheduler.setPreserveAutomaticBackupHistoryOnSelectedDisk(true))
    scheduler.setSelectedCategories([.operationHistory])

    await scheduler.refreshRecentBackups()
    XCTAssertEqual(try automaticBackupCount(in: harness.injectedBackupURL),
      WorkspaceBackupScheduler.automaticRetentionCount + 2)

    await scheduler.runBackupNow()
    XCTAssertEqual(scheduler.statusLevel, .success, scheduler.statusMessage ?? "missing backup status")
    XCTAssertEqual(try automaticBackupCount(in: harness.injectedBackupURL),
      WorkspaceBackupScheduler.automaticRetentionCount + 3)

    XCTAssertTrue(scheduler.setPreserveAutomaticBackupHistoryOnSelectedDisk(false))
    await scheduler.refreshRecentBackups()
    XCTAssertEqual(try automaticBackupCount(in: harness.injectedBackupURL),
      WorkspaceBackupScheduler.automaticRetentionCount + 3,
      "switching back to bounded retention must not prune during refresh")
    await scheduler.runBackupNow()
    XCTAssertEqual(try automaticBackupCount(in: harness.injectedBackupURL),
      WorkspaceBackupScheduler.automaticRetentionCount,
      "the next successful backup applies the bounded retention policy")
  }

  func testSelectedDiskRecentInventoryValidatesOnlyLatestTwelveSnapshots() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    try FileManager.default.createDirectory(
      at: harness.injectedBackupURL,
      withIntermediateDirectories: true
    )
    for index in 0..<14 {
      let packageURL = harness.injectedBackupURL.appendingPathComponent(
        "\(WorkspaceBackupService.automaticBackupFilePrefix)20260923-\(String(format: "%06d", index)).psworkspacebackup",
        isDirectory: true
      )
      try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
      try Data("snapshot-\(index)".utf8).write(to: packageURL.appendingPathComponent("payload"))
    }

    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )
    try scheduler.setDestinationFolder(harness.injectedBackupURL)
    XCTAssertTrue(scheduler.setPreserveAutomaticBackupHistoryOnSelectedDisk(true))
    try await Task.sleep(for: .milliseconds(300))
    await scheduler.refreshRecentBackups()

    XCTAssertEqual(scheduler.destinationFolderURL, harness.injectedBackupURL)
    XCTAssertEqual(scheduler.statusLevel, .warning, scheduler.statusMessage ?? "missing inventory status")
    XCTAssertLessThanOrEqual(scheduler.recentBackups.count, WorkspaceBackupScheduler.selectedDiskRecentInventoryLimit)
    XCTAssertEqual(scheduler.invalidRecentBackupCount, WorkspaceBackupScheduler.selectedDiskRecentInventoryLimit)
    XCTAssertEqual(try automaticBackupCount(in: harness.injectedBackupURL), 14)
  }

  func testChangingDestinationEnablesRetentionAndICloudClearsIt() throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )
    try scheduler.setDestinationFolder(harness.injectedBackupURL)
    XCTAssertTrue(scheduler.setPreserveAutomaticBackupHistoryOnSelectedDisk(true))

    try scheduler.setDestinationFolder(harness.rootURL.appendingPathComponent("OtherDisk"))
    XCTAssertTrue(scheduler.settings.preserveAutomaticBackupHistoryOnSelectedDisk)
    scheduler.setICloudDestinationFolder(harness.rootURL.appendingPathComponent("iCloud"))
    XCTAssertTrue(scheduler.settings.destinationIsICloud)
    XCTAssertFalse(scheduler.canPreserveAutomaticBackupHistoryOnSelectedDisk)
    XCTAssertFalse(scheduler.setPreserveAutomaticBackupHistoryOnSelectedDisk(true))
  }

  func testCloudFileProviderDestinationDoesNotEnableLocalDiskRetention() throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let homeURL = harness.rootURL.appendingPathComponent("FakeHome", isDirectory: true)
    let cloudURL = homeURL.appendingPathComponent("Library/CloudStorage/GoogleDrive-user/Backups", isDirectory: true)
    let siblingURL = homeURL.appendingPathComponent("Library/CloudStorageBackup", isDirectory: true)
    XCTAssertTrue(WorkspaceBackupScheduler.isCloudFileProviderURL(cloudURL, homeURL: homeURL))
    XCTAssertFalse(WorkspaceBackupScheduler.isCloudFileProviderURL(siblingURL, homeURL: homeURL))

    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )
    let actualCloudURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/CloudStorage/GoogleDrive-test/Backups", isDirectory: true)
    try scheduler.setDestinationFolder(actualCloudURL)

    XCTAssertFalse(scheduler.settings.destinationIsICloud,
      "Google Drive must not be represented as iCloud")
    XCTAssertFalse(scheduler.settings.preserveAutomaticBackupHistoryOnSelectedDisk)
    XCTAssertTrue(scheduler.settings.deferAutomaticBackupPruningUntilNextBackup)
    XCTAssertFalse(scheduler.canPreserveAutomaticBackupHistoryOnSelectedDisk)
    XCTAssertFalse(scheduler.setPreserveAutomaticBackupHistoryOnSelectedDisk(true))
  }

  func testUnmountedSelectedVolumeCannotFallBackToSystemDisk() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let path = URL(fileURLWithPath: "/Volumes/CodexMissing-\(UUID().uuidString)/Backups", isDirectory: true)
    try persist(
      WorkspaceBackupScheduleSettings(destinationPath: path.path),
      in: harness.defaults
    )
    let scheduler = WorkspaceBackupScheduler(store: harness.store, defaults: harness.defaults)
    XCTAssertThrowsError(try scheduler.setDestinationFolder(path))
    await scheduler.refreshRecentBackups()
    await scheduler.runBackupNow()

    XCTAssertEqual(scheduler.statusLevel, .error)
    XCTAssertTrue(scheduler.statusMessage?.contains("未挂载") == true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
  }

  func testRunBackupNowRecordsUserActorForTerminalBackupEvent() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )

    await scheduler.runBackupNow()

    let operationEvent = try XCTUnwrap(harness.store.operationHistory.records.first)
    XCTAssertEqual(harness.store.operationHistory.records.count, 1)
    XCTAssertEqual(operationEvent.kind, .workspaceBackupCreated)
    XCTAssertEqual(operationEvent.actor, .user)
  }

  func testOffStartDoesNotScanUntilExplicitRefresh() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    try FileManager.default.createDirectory(
      at: harness.injectedBackupURL, withIntermediateDirectories: true)
    for index in 0..<(WorkspaceBackupScheduler.automaticRetentionCount + 2) {
      let url = harness.injectedBackupURL.appendingPathComponent(
        "\(WorkspaceBackupService.automaticBackupFilePrefix)off-start-\(index).psworkspacebackup",
        isDirectory: true
      )
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try Data("automatic-\(index)".utf8).write(to: url.appendingPathComponent("payload"))
    }
    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )

    scheduler.start()
    try await Task.sleep(for: .milliseconds(450))
    XCTAssertEqual(
      try automaticBackupCount(in: harness.injectedBackupURL),
      WorkspaceBackupScheduler.automaticRetentionCount + 2)
    XCTAssertTrue(scheduler.recentBackups.isEmpty)

    await scheduler.refreshRecentBackups()
    XCTAssertEqual(
      try automaticBackupCount(in: harness.injectedBackupURL),
      WorkspaceBackupScheduler.automaticRetentionCount + 2)
  }

  func testImmediateStopCancelsQueuedStartupInventory() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    try FileManager.default.createDirectory(
      at: harness.injectedBackupURL,
      withIntermediateDirectories: true
    )
    for index in 0..<(WorkspaceBackupScheduler.automaticRetentionCount + 2) {
      let url = harness.injectedBackupURL.appendingPathComponent(
        "\(WorkspaceBackupService.automaticBackupFilePrefix)stop-start-\(index).psworkspacebackup",
        isDirectory: true
      )
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try Data("automatic-\(index)".utf8).write(to: url.appendingPathComponent("payload"))
    }
    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )
    scheduler.setFrequency(.daily)

    scheduler.start()
    scheduler.stop()
    try await Task.sleep(for: .milliseconds(450))

    XCTAssertEqual(
      try automaticBackupCount(in: harness.injectedBackupURL),
      WorkspaceBackupScheduler.automaticRetentionCount + 2
    )
    XCTAssertTrue(scheduler.recentBackups.isEmpty)
  }

  func testNewerRefreshWinsOverCancelledOlderRefresh() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let oldFolder = harness.rootURL.appendingPathComponent("old", isDirectory: true)
    let freshFolder = harness.rootURL.appendingPathComponent("fresh", isDirectory: true)
    try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: freshFolder, withIntermediateDirectories: true)
    for index in 0..<WorkspaceBackupScheduler.automaticRetentionCount {
      let packageURL = oldFolder.appendingPathComponent(
        "\(WorkspaceBackupService.automaticBackupFilePrefix)old-\(index).psworkspacebackup",
        isDirectory: true
      )
      try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
      try Data(repeating: 0, count: 1_024 * 1_024)
        .write(to: packageURL.appendingPathComponent("manifest.json"))
    }
    let scheduler = WorkspaceBackupScheduler(
      store: harness.store,
      defaults: harness.defaults,
      defaultDestinationFolderURL: oldFolder
    )

    let olderRefresh = Task { @MainActor in await scheduler.refreshRecentBackups() }
    await Task.yield()
    try scheduler.setDestinationFolder(freshFolder)
    await olderRefresh.value
    try await Task.sleep(for: .milliseconds(300))

    XCTAssertEqual(scheduler.destinationFolderURL, freshFolder.standardizedFileURL)
    XCTAssertEqual(scheduler.statusLevel, .success)
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

  func testRefreshPreservesTheOnlyExpiredBackupWhenAutomationIsOff() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let scheduler = makeScheduler(harness)
    await scheduler.performBackup(isAutomatic: true)
    let path = try XCTUnwrap(scheduler.settings.lastBackupPath)
    try FileManager.default.setAttributes(
      [
        .modificationDate: Date().addingTimeInterval(-100 * 24 * 60 * 60)
      ], ofItemAtPath: path)

    XCTAssertEqual(scheduler.settings.frequency, .off)
    await scheduler.refreshRecentBackups()

    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    XCTAssertEqual(scheduler.recentBackups.count, 1)
    _ = try WorkspaceBackupService().inspectBackup(at: URL(fileURLWithPath: path))
  }

  func testMissingBackupIsRecreatedEvenWhenContentIsUnchanged() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let scheduler = makeScheduler(harness)
    await scheduler.performBackup(isAutomatic: true)
    let firstPath = try XCTUnwrap(scheduler.settings.lastBackupPath)
    let fingerprint = scheduler.settings.lastContentFingerprint
    try FileManager.default.removeItem(atPath: firstPath)

    await scheduler.performBackup(isAutomatic: true)

    let replacementPath = try XCTUnwrap(scheduler.settings.lastBackupPath)
    XCTAssertNotEqual(firstPath, replacementPath)
    XCTAssertEqual(scheduler.settings.lastContentFingerprint, fingerprint)
    XCTAssertEqual(try automaticBackupCount(in: harness.injectedBackupURL), 1)
    _ = try WorkspaceBackupService().inspectBackup(at: URL(fileURLWithPath: replacementPath))
  }

  func testCorruptBackupDoesNotSuppressAnUnchangedReplacement() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let scheduler = makeScheduler(harness)
    await scheduler.performBackup(isAutomatic: true)
    let oldURL = URL(fileURLWithPath: try XCTUnwrap(scheduler.settings.lastBackupPath))
    try Data("corrupt".utf8).write(
      to: oldURL.appendingPathComponent(
        WorkspaceBackupService.operationHistoryRelativePath))

    await scheduler.performBackup(isAutomatic: true)

    let replacementURL = URL(fileURLWithPath: try XCTUnwrap(scheduler.settings.lastBackupPath))
    XCTAssertNotEqual(replacementURL, oldURL)
    _ = try WorkspaceBackupService().inspectBackup(at: replacementURL)
  }

  func testChangedDestinationReceivesAnUnchangedBackup() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let scheduler = makeScheduler(harness)
    await scheduler.performBackup(isAutomatic: true)
    let firstPath = try XCTUnwrap(scheduler.settings.lastBackupPath)
    let secondFolder = harness.rootURL.appendingPathComponent("SecondDestination")
    try scheduler.setDestinationFolder(secondFolder)
    XCTAssertTrue(scheduler.setPreserveAutomaticBackupHistoryOnSelectedDisk(false))

    await scheduler.performBackup(isAutomatic: true)

    let path = try XCTUnwrap(scheduler.settings.lastBackupPath)
    XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent().path, secondFolder.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstPath))
    _ = try WorkspaceBackupService().inspectBackup(at: URL(fileURLWithPath: path))
  }

  func testICloudRetentionWaitsForUploadConfirmationAndThenKeepsVerifiedCopy() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let scheduler = makeScheduler(harness)
    scheduler.setICloudDestinationFolder(harness.injectedBackupURL)
    try FileManager.default.createDirectory(
      at: harness.injectedBackupURL, withIntermediateDirectories: true)
    for index in 0..<13 {
      let old = harness.injectedBackupURL.appendingPathComponent(
        "\(WorkspaceBackupService.automaticBackupFilePrefix)old-\(index).psworkspacebackup")
      try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [
          .modificationDate: Date().addingTimeInterval(-100 * 24 * 60 * 60)
        ], ofItemAtPath: old.path)
    }
    scheduler.cloudUploadStatusReader = { _ in .waitingForUpload }
    await scheduler.performBackup(isAutomatic: true)
    let waitingPath = try XCTUnwrap(scheduler.settings.lastBackupPath)
    XCTAssertEqual(try automaticBackupCount(in: harness.injectedBackupURL), 14)

    await scheduler.performBackup(isAutomatic: true)
    XCTAssertEqual(scheduler.settings.lastBackupPath, waitingPath)
    XCTAssertEqual(try automaticBackupCount(in: harness.injectedBackupURL), 14)

    scheduler.cloudUploadStatusReader = { _ in .uploadFailed("quota exceeded") }
    await scheduler.performBackup(isAutomatic: true)
    XCTAssertEqual(scheduler.settings.lastBackupPath, waitingPath)
    XCTAssertEqual(try automaticBackupCount(in: harness.injectedBackupURL), 14)
    await scheduler.refreshRecentBackups()
    XCTAssertEqual(scheduler.cloudUploadStatus, .uploadFailed("quota exceeded"))
    XCTAssertEqual(try automaticBackupCount(in: harness.injectedBackupURL), 14)

    scheduler.cloudUploadStatusReader = { _ in .uploadConfirmed }
    await scheduler.performBackup(isAutomatic: true)
    XCTAssertEqual(
      scheduler.settings.lastBackupPath, waitingPath,
      "a confirmed intact copy should deduplicate and allow deferred retention")
    XCTAssertEqual(try automaticBackupCount(in: harness.injectedBackupURL), 1)
    _ = try WorkspaceBackupService().inspectBackup(at: URL(fileURLWithPath: waitingPath))
  }

  func testUploadErrorsTakePrecedenceOverUploadedFlags() {
    XCTAssertEqual(
      WorkspaceBackupScheduler.confirmedCloudUploadStatus(
        isUbiquitousPackage: true, declaredFileUploadStates: [true, true],
        uploadErrorDescriptions: ["quota exceeded"]
      ), .uploadFailed("quota exceeded"))
  }

  func testBackupSettingsCannotChangeDuringBackup() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let scheduler = makeScheduler(harness)
    let initialFrequency = scheduler.settings.frequency
    scheduler.cloudUploadStatusReader = { [weak scheduler] _ in
      guard let scheduler else { return .localCopyComplete }
      scheduler.setFrequency(initialFrequency == .off ? .daily : .off)
      scheduler.setICloudDestinationFolder(harness.rootURL.appendingPathComponent("Other"))
      scheduler.setSelectedCategories([.workbench])
      return .localCopyComplete
    }
    await scheduler.performBackup(isAutomatic: true)
    XCTAssertEqual(scheduler.destinationFolderURL, harness.injectedBackupURL)
    XCTAssertEqual(scheduler.selectedCategories, [.operationHistory])
    XCTAssertEqual(scheduler.settings.frequency, initialFrequency)
  }

  private func makeScheduler(_ harness: WorkspaceBackupSchedulerHarness) -> WorkspaceBackupScheduler
  {
    let scheduler = WorkspaceBackupScheduler(
      store: harness.store, defaults: harness.defaults,
      defaultDestinationFolderURL: harness.injectedBackupURL
    )
    scheduler.setSelectedCategories([.operationHistory])
    return scheduler
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

  private func automaticBackupCount(in folderURL: URL) throws -> Int {
    try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(WorkspaceBackupService.automaticBackupFilePrefix) }
      .count
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
