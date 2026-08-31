import Foundation
import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeBackupModelsTests: XCTestCase {
  func testBackupManifestAndPreviewPreserveRestoreIdentity() throws {
    let backupURL = URL(fileURLWithPath: "/private/tmp/knowledge-backup.pslibrarybackup")
    let file = KnowledgeLibraryBackupFileRecord(
      relativePath: "documents/one.md",
      byteCount: 42,
      sha256: "abc"
    )
    let manifest = KnowledgeLibraryBackupManifest(
      applicationVersion: "1.2.3",
      databaseUserVersion: 8,
      documentCount: 1,
      folderCount: 2,
      revisionCount: 3,
      chunkCount: 4,
      totalByteCount: 42,
      files: [file]
    )
    XCTAssertEqual(
      try JSONDecoder().decode(
        KnowledgeLibraryBackupManifest.self,
        from: JSONEncoder().encode(manifest)
      ),
      manifest
    )

    let preview = KnowledgeLibraryBackupPreview(
      backupURL: backupURL,
      createdAt: manifest.createdAt,
      applicationVersion: manifest.applicationVersion,
      databaseUserVersion: manifest.databaseUserVersion,
      documentCount: manifest.documentCount,
      folderCount: manifest.folderCount,
      revisionCount: manifest.revisionCount,
      chunkCount: manifest.chunkCount,
      totalByteCount: manifest.totalByteCount,
      sampleTitles: ["One"]
    )
    XCTAssertEqual(preview.id, backupURL)
    XCTAssertEqual(
      KnowledgeLibraryRestoreStartupOutcome.restored(
        KnowledgeLibraryRestoreStartupResult(restoredPreview: preview, previousLibraryURL: nil)
      ),
      .restored(
        KnowledgeLibraryRestoreStartupResult(restoredPreview: preview, previousLibraryURL: nil))
    )
  }

  func testEveryBackupValidationErrorRetainsActionableContext() throws {
    let errors: [(KnowledgeLibraryBackupError, String)] = [
      (.sourceUnavailable("library"), "library"),
      (.invalidManifest("manifest"), "manifest"),
      (.unsupportedFormat(2), "2"),
      (.unsupportedDatabaseVersion(found: 9, supported: 8), "9"),
      (.invalidPath("../escape"), "../escape"),
      (.missingFile("missing.md"), "missing.md"),
      (.manifestTooLarge(maximumByteCount: 1_048_576), "1 MB"),
      (.tooManyFiles(maximumCount: 3), "3"),
      (.fileTooLarge(path: "large.pdf", maximumByteCount: 2_097_152), "large.pdf"),
      (.backupTooLarge(maximumByteCount: 1_073_741_824), "1 GB"),
      (.fileSizeMismatch("size.md"), "size.md"),
      (.checksumMismatch("hash.md"), "hash.md"),
      (.databaseIntegrity("integrity"), "integrity"),
      (.metadataMismatch("metadata"), "metadata"),
      (.stagingFailed("staging"), "staging"),
      (.restoreFailed("restore"), "restore"),
    ]

    for (error, expectedContext) in errors {
      let description = try XCTUnwrap(error.errorDescription)
      XCTAssertTrue(
        description.contains(expectedContext),
        "\(error) should retain \(expectedContext) in its recovery message"
      )
    }
  }
}
