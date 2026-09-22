import Foundation
import PublishingDomainContracts
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class AIChatImageAttachmentLoaderTests: XCTestCase {
  func testMixedLoadFailureBlocksSubmissionAndRetainsSpecificReasons() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIChatImageAttachmentLoader-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let validURL = directory.appendingPathComponent("valid.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: validURL)
    let unsupportedURL = directory.appendingPathComponent("unsupported.tiff")
    try Data([0x49, 0x49, 0x2A, 0x00]).write(to: unsupportedURL)
    let oversizedURL = directory.appendingPathComponent("oversized.jpeg")
    try Data(
      repeating: 0xFF,
      count: AIPublishingChatImageAttachmentPresentation.maxAttachmentBytes + 1
    ).write(to: oversizedURL)

    let validID = UUID()
    let missingID = UUID()
    let unsupportedID = UUID()
    let oversizedID = UUID()
    let result = AIChatImageAttachmentLoader.loadResult([
      attachment(id: validID, filename: "valid.png", sourceURL: validURL),
      attachment(
        id: missingID,
        filename: "missing.png",
        sourceURL: directory.appendingPathComponent("missing.png")
      ),
      attachment(id: unsupportedID, filename: "unsupported.tiff", sourceURL: unsupportedURL),
      attachment(id: oversizedID, filename: "oversized.jpeg", sourceURL: oversizedURL),
    ])

    XCTAssertEqual(result.images.map(\.filename), ["valid.png"])
    XCTAssertEqual(result.failures.map(\.attachmentID), [missingID, unsupportedID, oversizedID])
    XCTAssertEqual(
      result.failures.map(\.reason),
      [.unreadableFile, .unsupportedFormat, .exceedsSizeLimit]
    )
    XCTAssertEqual(result.skippedCount, 3)

    let message = try XCTUnwrap(result.submissionFailureMessage)
    XCTAssertTrue(message.contains("missing.png"))
    XCTAssertTrue(message.contains("无法读取文件"))
    XCTAssertTrue(message.contains("unsupported.tiff"))
    XCTAssertTrue(message.contains("格式不支持"))
    XCTAssertTrue(message.contains("oversized.jpeg"))
    XCTAssertTrue(message.contains("超过"))
  }

  func testValidTemporaryImageProducesSendableAttachment() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIChatImageAttachmentLoader-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let imageURL = directory.appendingPathComponent("photo.webp")
    let imageData = Data([0x52, 0x49, 0x46, 0x46])
    try imageData.write(to: imageURL)

    let result = AIChatImageAttachmentLoader.loadResult([
      attachment(id: UUID(), filename: "photo.webp", sourceURL: imageURL)
    ])

    XCTAssertFalse(result.hasFailures)
    XCTAssertEqual(result.images.count, 1)
    XCTAssertEqual(result.images.first?.data, imageData)
    XCTAssertNil(result.submissionFailureMessage)
  }

  func testDetailedStoreResultReportsStaleNonImageAndExcessSelections() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIChatImageAttachmentStore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json"))
    )
    let imageAttachments = try (1...4).map { index in
      let url = directory.appendingPathComponent("image-\(index).png")
      try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
      return attachment(id: UUID(), filename: url.lastPathComponent, sourceURL: url)
    }
    let videoAttachment = DraftAttachment(
      id: UUID(),
      originalFilename: "movie.mp4",
      relativePublishPath: "/media/movie.mp4",
      repositoryPath: "static/media/movie.mp4",
      byteSize: 1,
      sourceFilePath: directory.appendingPathComponent("movie.mp4").path
    )
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Attachment selection",
      slug: "attachment-selection",
      attachments: [
        imageAttachments[0], imageAttachments[1], imageAttachments[2], videoAttachment,
        imageAttachments[3],
      ]
    )
    let removedAttachmentID = UUID()

    let result = await store.aiStore.aiChatImageAttachmentLoadResult(
      for: draft,
      attachmentIDs: Set(imageAttachments.map(\.id) + [videoAttachment.id, removedAttachmentID])
    )

    XCTAssertEqual(result.images.map(\.filename), ["image-1.png", "image-2.png", "image-3.png"])
    XCTAssertEqual(
      result.failures.map(\.attachmentID),
      [videoAttachment.id, imageAttachments[3].id, removedAttachmentID]
    )
    XCTAssertEqual(
      result.failures.map(\.reason),
      [.notImage, .exceedsSelectionLimit, .removedFromArticle]
    )
    XCTAssertNotNil(result.submissionFailureMessage)
  }

  private func attachment(id: UUID, filename: String, sourceURL: URL) -> DraftAttachment {
    DraftAttachment(
      id: id,
      originalFilename: filename,
      relativePublishPath: "/images/\(filename)",
      repositoryPath: "static/images/\(filename)",
      byteSize: 0,
      sourceFilePath: sourceURL.path
    )
  }
}
