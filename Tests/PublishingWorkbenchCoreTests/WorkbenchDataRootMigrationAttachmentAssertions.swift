import Foundation
import PublishingDomainContracts
import Testing

@testable import PublishingWorkbenchCore

extension WorkbenchDataRootMigrationTests {
  func verifyWorkbenchCompanionCopy(
    sourceLayout: WorkbenchDataRootLayout,
    destinationLayout: WorkbenchDataRootLayout
  ) throws {
    let source = WorkbenchPersistence(fileURL: sourceLayout.workbenchFileURL)
    let destination = WorkbenchPersistence(fileURL: destinationLayout.workbenchFileURL)
    let sourceSnapshot = try requiredSnapshot(at: source.fileURL)
    let destinationSnapshot = try requiredSnapshot(at: destination.fileURL)
    #expect(destinationSnapshot.drafts.first?.title == "Legacy workbench")
    try verifyAttachmentPaths(
      in: sourceSnapshot,
      sourceLayout: sourceLayout,
      destinationLayout: destinationLayout,
      expectsRelocation: false
    )
    try verifyAttachmentPaths(
      in: destinationSnapshot,
      sourceLayout: sourceLayout,
      destinationLayout: destinationLayout,
      expectsRelocation: true
    )
    try verifyLastKnownGoodAttachmentPaths(
      source: source,
      destination: destination,
      sourceLayout: sourceLayout,
      destinationLayout: destinationLayout
    )
    try verifyOperationLedgerCopy(
      source: source,
      destination: destination,
      sourceLayout: sourceLayout,
      destinationLayout: destinationLayout
    )

    let recoveryRecords = try DraftRecoveryJournal(
      fileURL: destination.draftRecoveryJournalURL
    ).load()
    #expect(recoveryRecords.first?.recoveredBodyMarkdown == "Recovered unsaved body")
    try verifyRecoveryArchiveSnapshots(
      sourceLayout: sourceLayout,
      destinationLayout: destinationLayout
    )
    #expect(try regularFileMap(in: destination.retiredFeatureArchiveDirectoryURL)
      == regularFileMap(in: source.retiredFeatureArchiveDirectoryURL))
    #expect(try regularFileMap(in: destination.imageOptimizationDirectoryURL)
      == regularFileMap(in: source.imageOptimizationDirectoryURL))
    #expect(try quarantineFileMap(in: destinationLayout.rootURL)
      == quarantineFileMap(in: sourceLayout.rootURL))
  }

  func verifyOperationLedgerCopy(
    source: WorkbenchPersistence,
    destination: WorkbenchPersistence,
    sourceLayout: WorkbenchDataRootLayout,
    destinationLayout: WorkbenchDataRootLayout
  ) throws {
    let sourceLedger = WorkbenchOperationLedgerPersistence(
      fileURL: source.operationLedgerURL
    )
    let destinationLedger = WorkbenchOperationLedgerPersistence(
      fileURL: destination.operationLedgerURL
    )
    #expect(
      try Data(contentsOf: destinationLedger.fileURL)
        == Data(contentsOf: sourceLedger.fileURL))
    #expect(
      try Data(contentsOf: destinationLedger.lastKnownGoodURL)
        == Data(contentsOf: sourceLedger.lastKnownGoodURL))

    let quarantineName = "workbench.operation-log.unreadable-fixture.json"
    #expect(
      try Data(contentsOf: destinationLayout.rootURL.appendingPathComponent(quarantineName))
        == Data(contentsOf: sourceLayout.rootURL.appendingPathComponent(quarantineName))
    )
  }

  func verifyLastKnownGoodAttachmentPaths(
    source: WorkbenchPersistence,
    destination: WorkbenchPersistence,
    sourceLayout: WorkbenchDataRootLayout,
    destinationLayout: WorkbenchDataRootLayout
  ) throws {
    let sourceSnapshot = try requiredSnapshot(at: source.lastKnownGoodURL)
    let destinationSnapshot = try requiredSnapshot(at: destination.lastKnownGoodURL)
    try verifyAttachmentPaths(
      in: sourceSnapshot,
      sourceLayout: sourceLayout,
      destinationLayout: destinationLayout,
      expectsRelocation: false
    )
    try verifyAttachmentPaths(
      in: destinationSnapshot,
      sourceLayout: sourceLayout,
      destinationLayout: destinationLayout,
      expectsRelocation: true
    )
  }

  func verifyAttachmentPaths(
    in snapshot: WorkbenchSnapshot,
    sourceLayout: WorkbenchDataRootLayout,
    destinationLayout: WorkbenchDataRootLayout,
    expectsRelocation: Bool
  ) throws {
    let liveLayout = expectsRelocation ? destinationLayout : sourceLayout
    let livePersistence = WorkbenchPersistence(fileURL: liveLayout.workbenchFileURL)
    let managedPath = liveLayout.managedAttachmentsURL
      .appendingPathComponent("article-id/managed.png")
      .path
    let optimizedPath = livePersistence.imageOptimizationDirectoryURL
      .appendingPathComponent(".image-batch-preserved/optimized.jpg")
      .path
    let externalPath = sourceLayout.rootURL.deletingLastPathComponent()
      .appendingPathComponent("external-user-file.png")
      .path
    let unknownRootPath = sourceLayout.rootURL
      .appendingPathComponent("LegacyExports/user-selected.png")
      .path

    try verifyActiveAttachmentPaths(
      in: snapshot,
      managedPath: managedPath,
      externalPath: externalPath,
      unknownRootPath: unknownRootPath
    )
    try verifyHistoricalAttachmentPaths(
      in: snapshot,
      managedPath: managedPath,
      optimizedPath: optimizedPath,
      externalPath: externalPath,
      unknownRootPath: unknownRootPath
    )
    if expectsRelocation {
      #expect(FileManager.default.fileExists(atPath: managedPath))
      #expect(FileManager.default.fileExists(atPath: optimizedPath))
    }
  }

  func verifyActiveAttachmentPaths(
    in snapshot: WorkbenchSnapshot,
    managedPath: String,
    externalPath: String,
    unknownRootPath: String
  ) throws {
    let activeDraft = try requiredDraft(from: snapshot)
    #expect(try requiredAttachment("managed-active.png", in: activeDraft).sourceFilePath
      == managedPath)
    #expect(try requiredAttachment("external-active.png", in: activeDraft).sourceFilePath
      == externalPath)
    #expect(try requiredAttachment("unknown-root-active.png", in: activeDraft).sourceFilePath
      == unknownRootPath)
  }

  func verifyHistoricalAttachmentPaths(
    in snapshot: WorkbenchSnapshot,
    managedPath: String,
    optimizedPath: String,
    externalPath: String,
    unknownRootPath: String
  ) throws {
    guard let versionDraft = snapshot.draftVersions.first?.draft else {
      throw FixtureError.missingDraftVersion
    }
    #expect(try requiredAttachment("managed-active.png", in: versionDraft).sourceFilePath
      == managedPath)
    #expect(try requiredAttachment("optimized-version.jpg", in: versionDraft).sourceFilePath
      == optimizedPath)
    #expect(try requiredAttachment("external-active.png", in: versionDraft).sourceFilePath
      == externalPath)
    #expect(try requiredAttachment("unknown-root-active.png", in: versionDraft).sourceFilePath
      == unknownRootPath)

    guard let recycledDraft = snapshot.recycledDrafts.first?.draft else {
      throw FixtureError.missingRecycledDraft
    }
    #expect(try requiredAttachment("optimized-recycled.jpg", in: recycledDraft).sourceFilePath
      == optimizedPath)
  }

  func verifyRecoveryArchiveSnapshots(
    sourceLayout: WorkbenchDataRootLayout,
    destinationLayout: WorkbenchDataRootLayout
  ) throws {
    let sourceRootURL = WorkbenchPersistence(
      fileURL: sourceLayout.workbenchFileURL
    ).recoveryArchiveDirectoryURL
    let destinationRootURL = WorkbenchPersistence(
      fileURL: destinationLayout.workbenchFileURL
    ).recoveryArchiveDirectoryURL
    let sourceFiles = try regularFileMap(in: sourceRootURL)
    let destinationFiles = try regularFileMap(in: destinationRootURL)
    #expect(Set(sourceFiles.keys) == Set(destinationFiles.keys))
    #expect(destinationFiles["CorruptFixture/workbench.json"]
      == sourceFiles["CorruptFixture/workbench.json"])

    let snapshotNames = Set(["workbench.json", "workbench.last-known-good.json"])
    var validSnapshotCount = 0
    for relativePath in sourceFiles.keys
    where snapshotNames.contains((relativePath as NSString).lastPathComponent) {
      guard (try? requiredSnapshot(at: sourceRootURL.appendingPathComponent(relativePath))) != nil
      else { continue }
      let destinationSnapshot = try requiredSnapshot(
        at: destinationRootURL.appendingPathComponent(relativePath))
      try verifyAttachmentPaths(
        in: destinationSnapshot,
        sourceLayout: sourceLayout,
        destinationLayout: destinationLayout,
        expectsRelocation: true
      )
      validSnapshotCount += 1
    }
    #expect(validSnapshotCount >= 2)
  }

  func requiredAttachment(
    _ filename: String,
    in draft: ArticleDraft
  ) throws -> DraftAttachment {
    guard let attachment = draft.attachments.first(where: {
      $0.originalFilename == filename
    }) else {
      throw FixtureError.missingAttachment
    }
    return attachment
  }

  func requiredSnapshot(at url: URL) throws -> WorkbenchSnapshot {
    try WorkbenchPersistence(fileURL: url).loadStoredSnapshot(at: url)
  }
}
