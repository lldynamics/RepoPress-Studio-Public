import Foundation
import Testing
@testable import PublishingWorkbenchCore

struct ManagedAttachmentFileStoreSwiftTestingTests {
  @Test
  func discardRemovesManagedFileAndEmptyAttachmentDirectory() throws {
    let temporaryRoot = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let sourceURL = temporaryRoot.appendingPathComponent("source.jpg")
    try Data("attachment".utf8).write(to: sourceURL)
    let managedRoot = temporaryRoot.appendingPathComponent("Managed", isDirectory: true)
    let store = ManagedAttachmentFileStore(rootDirectoryURL: managedRoot)
    let attachmentID = UUID()
    let storedURL = try store.storeFile(at: sourceURL, attachmentID: attachmentID)

    try store.discardStoredFile(at: storedURL)

    #expect(!FileManager.default.fileExists(atPath: storedURL.path))
    #expect(!FileManager.default.fileExists(atPath: storedURL.deletingLastPathComponent().path))
  }

  @Test
  func discardTreatsMissingManagedFileAsIdempotent() throws {
    let temporaryRoot = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let attachmentDirectory = temporaryRoot
      .appendingPathComponent("Managed", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: attachmentDirectory,
      withIntermediateDirectories: true
    )
    let missingURL = attachmentDirectory.appendingPathComponent("missing.jpg")
    let store = ManagedAttachmentFileStore(
      rootDirectoryURL: temporaryRoot.appendingPathComponent("Managed", isDirectory: true)
    )

    try store.discardStoredFile(at: missingURL)

    #expect(!FileManager.default.fileExists(atPath: attachmentDirectory.path))
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ManagedAttachmentFileStoreSwiftTesting-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }
}
