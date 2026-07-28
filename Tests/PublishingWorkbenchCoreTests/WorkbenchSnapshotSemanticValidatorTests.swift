import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class WorkbenchSnapshotSemanticValidatorTests: XCTestCase {
  func testRejectsDuplicateProfileID() {
    var snapshot = makeSnapshot()
    snapshot.profiles.append(snapshot.profiles[0])

    XCTAssertThrowsError(try WorkbenchSnapshotSemanticValidator.validate(snapshot)) { error in
      guard case WorkbenchSnapshotSemanticValidationError.duplicateProfileID = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRejectsMissingActiveProfile() {
    var snapshot = makeSnapshot()
    snapshot.activeProfileID = UUID()

    XCTAssertThrowsError(try WorkbenchSnapshotSemanticValidator.validate(snapshot)) { error in
      guard case WorkbenchSnapshotSemanticValidationError.activeProfileMissing = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRejectsDuplicateDraftID() {
    var snapshot = makeSnapshot()
    snapshot.drafts.append(snapshot.drafts[0])

    XCTAssertThrowsError(try WorkbenchSnapshotSemanticValidator.validate(snapshot)) { error in
      guard case WorkbenchSnapshotSemanticValidationError.duplicateDraftID = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRejectsDraftPresentInWorkspaceAndRecycleBin() {
    var snapshot = makeSnapshot()
    snapshot.recycledDrafts = [RecycledDraft(draft: snapshot.drafts[0])]

    XCTAssertThrowsError(try WorkbenchSnapshotSemanticValidator.validate(snapshot)) { error in
      guard case WorkbenchSnapshotSemanticValidationError.activeAndRecycledDraftOverlap = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRejectsDraftReferencingMissingProfile() {
    var snapshot = makeSnapshot()
    snapshot.drafts[0] = ArticleDraft(
      siteProfileID: UUID(),
      title: "Missing profile"
    )

    XCTAssertThrowsError(try WorkbenchSnapshotSemanticValidator.validate(snapshot)) { error in
      guard case WorkbenchSnapshotSemanticValidationError.draftProfileMissing = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRejectsVersionWhoseDeclaredDraftIDDiffersFromEmbeddedDraft() {
    var snapshot = makeSnapshot()
    let service = DraftLifecycleService()
    var version = service.recordingVersion(
      of: snapshot.drafts[0],
      reason: .automatic,
      in: []
    )[0]
    version.draftID = UUID()
    snapshot.draftVersions = [version]

    XCTAssertThrowsError(try WorkbenchSnapshotSemanticValidator.validate(snapshot)) { error in
      guard case WorkbenchSnapshotSemanticValidationError.versionDraftIDMismatch = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRejectsEditorSessionReferencingMissingDraft() {
    var snapshot = makeSnapshot()
    snapshot.markdownEditorSessionStates[UUID()] = .empty

    XCTAssertThrowsError(try WorkbenchSnapshotSemanticValidator.validate(snapshot)) { error in
      guard case WorkbenchSnapshotSemanticValidationError.editorSessionDraftMissing = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRejectsRecycledDraftReferencingMissingProfile() {
    var snapshot = makeSnapshot()
    let recycledDraft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Missing recycled profile"
    )
    snapshot.recycledDrafts = [RecycledDraft(draft: recycledDraft)]

    XCTAssertThrowsError(try WorkbenchSnapshotSemanticValidator.validate(snapshot)) { error in
      guard case WorkbenchSnapshotSemanticValidationError.draftProfileMissing = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRecoveryEntryPointRejectsSemanticallyInvalidSnapshot() throws {
    let rootURL = try makeFixture()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let persistence = WorkbenchPersistence(
      fileURL: rootURL.appendingPathComponent("workbench.json")
    )
    var invalidSnapshot = makeSnapshot()
    invalidSnapshot.profiles.append(invalidSnapshot.profiles[0])
    let recoveryURL = rootURL.appendingPathComponent("invalid-recovery.json")
    try JSONEncoder.workbench.encode(invalidSnapshot).write(to: recoveryURL)

    XCTAssertThrowsError(
      try persistence.installRecoverySnapshot(from: recoveryURL)
    ) { error in
      guard case WorkbenchPersistenceError.invalidRecoverySnapshot = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testStagingFailureDoesNotArchiveOrModifyExistingSnapshots() throws {
    let fixture = try recoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    var didArchive = false
    let operations = WorkbenchRecoveryFileOperations(
      writeAtomically: { _, destinationURL in
        if destinationURL.path.contains(".workbench-recovery-") {
          throw InjectedRecoveryFailure.write
        }
      },
      archiveExistingSnapshots: {
        didArchive = true
        return try fixture.persistence.archiveUnrecoverableSnapshotFiles()
      }
    )

    XCTAssertThrowsError(
      try fixture.persistence.installRecoverySnapshot(
        from: fixture.recoveryURL,
        fileOperations: operations
      )
    ) { error in
      guard case WorkbenchRecoveryTransactionError.stagingFailed = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertFalse(didArchive)
    XCTAssertEqual(try Data(contentsOf: fixture.primaryURL), fixture.originalPrimaryData)
    XCTAssertEqual(
      try Data(contentsOf: fixture.persistence.lastKnownGoodURL),
      fixture.originalBackupData
    )
  }

  func testArchiveFailureDoesNotModifyExistingSnapshots() throws {
    let fixture = try recoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let operations = WorkbenchRecoveryFileOperations(
      writeAtomically: liveAtomicWrite,
      archiveExistingSnapshots: {
        throw InjectedRecoveryFailure.archive
      }
    )

    XCTAssertThrowsError(
      try fixture.persistence.installRecoverySnapshot(
        from: fixture.recoveryURL,
        fileOperations: operations
      )
    ) { error in
      guard case WorkbenchRecoveryTransactionError.archiveFailed = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: fixture.primaryURL), fixture.originalPrimaryData)
    XCTAssertEqual(
      try Data(contentsOf: fixture.persistence.lastKnownGoodURL),
      fixture.originalBackupData
    )
  }

  func testBackupInstallFailureLeavesPrimarySnapshotUntouched() throws {
    let fixture = try recoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let operations = WorkbenchRecoveryFileOperations(
      writeAtomically: { data, destinationURL in
        if destinationURL == fixture.persistence.lastKnownGoodURL {
          throw InjectedRecoveryFailure.write
        }
        try self.liveAtomicWrite(data, destinationURL)
      },
      archiveExistingSnapshots: {
        try fixture.persistence.archiveUnrecoverableSnapshotFiles()
      }
    )

    XCTAssertThrowsError(
      try fixture.persistence.installRecoverySnapshot(
        from: fixture.recoveryURL,
        fileOperations: operations
      )
    ) { error in
      guard case WorkbenchRecoveryTransactionError.backupInstallFailed = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: fixture.primaryURL), fixture.originalPrimaryData)
    XCTAssertEqual(
      try Data(contentsOf: fixture.persistence.lastKnownGoodURL),
      fixture.originalBackupData
    )
  }

  func testPrimaryInstallFailureKeepsValidatedLastKnownGoodSnapshot() throws {
    let fixture = try recoveryFixture(recoveryTitle: "Validated recovery")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let operations = WorkbenchRecoveryFileOperations(
      writeAtomically: { data, destinationURL in
        if destinationURL == fixture.primaryURL {
          throw InjectedRecoveryFailure.write
        }
        try self.liveAtomicWrite(data, destinationURL)
      },
      archiveExistingSnapshots: {
        try fixture.persistence.archiveUnrecoverableSnapshotFiles()
      }
    )

    XCTAssertThrowsError(
      try fixture.persistence.installRecoverySnapshot(
        from: fixture.recoveryURL,
        fileOperations: operations
      )
    ) { error in
      guard case WorkbenchRecoveryTransactionError.primaryInstallFailed = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let backup = try decoder.decode(
      WorkbenchSnapshot.self,
      from: Data(contentsOf: fixture.persistence.lastKnownGoodURL)
    )
    XCTAssertEqual(backup.drafts.first?.title, "Validated recovery")
    XCTAssertEqual(try Data(contentsOf: fixture.primaryURL), fixture.originalPrimaryData)
  }

  private func makeSnapshot(title: String = "Semantic validation") -> WorkbenchSnapshot {
    let profile = SiteProfile.defaultProfile
    var draft = ArticleDraft.empty(profile: profile)
    draft.title = title
    return WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [draft],
      releaseRecords: []
    )
  }

  private func writeRecoverySnapshot(
    under rootURL: URL,
    title: String = "Recovery"
  ) throws -> URL {
    let url = rootURL.appendingPathComponent("chosen-recovery.json")
    try JSONEncoder.workbench.encode(makeSnapshot(title: title)).write(
      to: url,
      options: .atomic
    )
    return url
  }

  private func recoveryFixture(
    recoveryTitle: String = "Recovery"
  ) throws -> RecoveryFixture {
    let rootURL = try makeFixture()
    let primaryURL = rootURL.appendingPathComponent("workbench.json")
    let persistence = WorkbenchPersistence(fileURL: primaryURL)
    let originalPrimaryData = Data("{ original primary".utf8)
    let originalBackupData = Data("{ original backup".utf8)
    try originalPrimaryData.write(to: primaryURL)
    try originalBackupData.write(to: persistence.lastKnownGoodURL)
    let recoveryURL = try writeRecoverySnapshot(
      under: rootURL,
      title: recoveryTitle
    )
    return RecoveryFixture(
      rootURL: rootURL,
      primaryURL: primaryURL,
      persistence: persistence,
      recoveryURL: recoveryURL,
      originalPrimaryData: originalPrimaryData,
      originalBackupData: originalBackupData
    )
  }

  private func liveAtomicWrite(_ data: Data, _ destinationURL: URL) throws {
    try data.write(to: destinationURL, options: .atomic)
  }

  private func makeFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workbench-semantic-validation-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private struct RecoveryFixture {
  let rootURL: URL
  let primaryURL: URL
  let persistence: WorkbenchPersistence
  let recoveryURL: URL
  let originalPrimaryData: Data
  let originalBackupData: Data
}

private enum InjectedRecoveryFailure: LocalizedError {
  case write
  case archive

  var errorDescription: String? {
    switch self {
    case .write:
      return "Injected write failure"
    case .archive:
      return "Injected archive failure"
    }
  }
}
