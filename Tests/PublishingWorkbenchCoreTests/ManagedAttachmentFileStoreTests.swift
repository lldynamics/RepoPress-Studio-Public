import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class ManagedAttachmentFileStoreTests: XCTestCase {
  func testStoredFileRemainsReadableAfterOriginalIsRemoved() throws {
    let temporaryRoot = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let sourceDirectory = temporaryRoot.appendingPathComponent("External", isDirectory: true)
    let managedRoot = temporaryRoot.appendingPathComponent("Managed", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sourceDirectory,
      withIntermediateDirectories: true
    )
    let sourceURL = sourceDirectory.appendingPathComponent("cover image.png")
    let expectedData = Data("durable-attachment".utf8)
    try expectedData.write(to: sourceURL)
    let attachmentID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let store = ManagedAttachmentFileStore(rootDirectoryURL: managedRoot)

    let storedURL = try store.storeFile(
      at: sourceURL,
      attachmentID: attachmentID
    )
    try FileManager.default.removeItem(at: sourceURL)

    XCTAssertEqual(
      storedURL.deletingLastPathComponent().lastPathComponent,
      attachmentID.uuidString.lowercased()
    )
    XCTAssertEqual(storedURL.lastPathComponent, "cover image.png")
    XCTAssertEqual(try Data(contentsOf: storedURL), expectedData)
  }

  func testRepeatedStoreForSameAttachmentKeepsCommittedCopy() throws {
    let temporaryRoot = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let sourceURL = temporaryRoot.appendingPathComponent("walkthrough.mp4")
    let originalData = Data("first-version".utf8)
    try originalData.write(to: sourceURL)
    let store = ManagedAttachmentFileStore(
      rootDirectoryURL: temporaryRoot.appendingPathComponent("Managed")
    )
    let attachmentID = UUID()

    let firstURL = try store.storeFile(at: sourceURL, attachmentID: attachmentID)
    try Data("second-version".utf8).write(to: sourceURL)
    let secondURL = try store.storeFile(at: sourceURL, attachmentID: attachmentID)

    XCTAssertEqual(secondURL, firstURL)
    XCTAssertEqual(try Data(contentsOf: secondURL), originalData)
  }

  func testConcurrentStoreForSameAttachmentReturnsCommittedCopy() async throws {
    let temporaryRoot = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let sourceURL = temporaryRoot.appendingPathComponent("concurrent.mov")
    let expectedData = Data("concurrent-attachment".utf8)
    try expectedData.write(to: sourceURL)
    let store = ManagedAttachmentFileStore(
      rootDirectoryURL: temporaryRoot.appendingPathComponent("Managed")
    )
    let attachmentID = UUID()

    var storedURLs = [URL]()
    try await withThrowingTaskGroup(of: URL.self) { group in
      for _ in 0 ..< 8 {
        group.addTask {
          try store.storeFile(at: sourceURL, attachmentID: attachmentID)
        }
      }
      for try await storedURL in group {
        storedURLs.append(storedURL)
      }
    }

    XCTAssertEqual(Set(storedURLs).count, 1)
    let storedURL = try XCTUnwrap(storedURLs.first)
    XCTAssertEqual(try Data(contentsOf: storedURL), expectedData)
  }

  func testMissingSourceIsRejectedWithoutCreatingManagedFile() throws {
    let temporaryRoot = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let managedRoot = temporaryRoot.appendingPathComponent("Managed")
    let store = ManagedAttachmentFileStore(rootDirectoryURL: managedRoot)
    let missingURL = temporaryRoot.appendingPathComponent("missing.jpg")

    XCTAssertThrowsError(
      try store.storeFile(at: missingURL, attachmentID: UUID())
    ) { error in
      guard case ManagedAttachmentFileStoreError.sourceUnavailable(let path) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(path, missingURL.path)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: managedRoot.path))
  }

  func testSymbolicLinkSourceIsRejected() throws {
    let temporaryRoot = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let targetURL = temporaryRoot.appendingPathComponent("target.jpg")
    let symbolicLinkURL = temporaryRoot.appendingPathComponent("selected.jpg")
    try Data("target".utf8).write(to: targetURL)
    try FileManager.default.createSymbolicLink(
      at: symbolicLinkURL,
      withDestinationURL: targetURL
    )
    let store = ManagedAttachmentFileStore(
      rootDirectoryURL: temporaryRoot.appendingPathComponent("Managed")
    )

    XCTAssertThrowsError(
      try store.storeFile(at: symbolicLinkURL, attachmentID: UUID())
    ) { error in
      guard case ManagedAttachmentFileStoreError.sourceUnavailable = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testLegacyAttachmentJSONWithoutManagedStorageMetadataStillDecodes() throws {
    let json = Data(
      """
      {
        "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        "originalFilename": "legacy.png",
        "relativePublishPath": "/images/legacy.png",
        "repositoryPath": "static/images/legacy.png",
        "altText": "Legacy",
        "caption": "",
        "byteSize": 42,
        "sourceFilePath": "/tmp/legacy.png"
      }
      """.utf8
    )

    let attachment = try JSONDecoder().decode(DraftAttachment.self, from: json)

    XCTAssertEqual(attachment.originalFilename, "legacy.png")
    XCTAssertEqual(attachment.sourceFilePath, "/tmp/legacy.png")
    XCTAssertNil(attachment.repositorySHA)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ManagedAttachmentFileStoreTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }
}
