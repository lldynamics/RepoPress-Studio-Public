import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class AIChatAttachmentStoreTests: XCTestCase {
  func testPersistsImageAsContentAddressedBlobAndHydratesIt() throws {
    let rootURL = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = AIChatAttachmentStore(directoryURL: rootURL)
    let data = Data(repeating: 0xA5, count: 128_000)
    let attachment = AIChatImageAttachment(filename: "sample.png", mimeType: "image/png", data: data)
    let session = AIPublishingChatSessionState(
      messages: [.init(role: .user, content: "inspect", imageAttachments: [attachment])]
    )

    let persisted = try store.persistedSessions([UUID(): session])
    let persistedAttachment = try XCTUnwrap(persisted.values.first?.messages.first?.imageAttachments.first)
    let reference = try XCTUnwrap(persistedAttachment.storageReference)

    XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(reference).path))
    XCTAssertEqual(persistedAttachment.data, data)
    let encoded = try JSONEncoder().encode(persistedAttachment)
    XCTAssertLessThan(encoded.count, 2_000)
    XCTAssertFalse(String(data: encoded, encoding: .utf8)?.contains("\"data\"") == true)

    let decoded = try JSONDecoder.workbench.decode(
      [UUID: AIPublishingChatSessionState].self,
      from: JSONEncoder.workbench.encode(persisted)
    )
    XCTAssertTrue(decoded.values.first?.messages.first?.imageAttachments.first?.data.isEmpty == true)
    let hydrated = store.hydratedSessions(decoded)
    XCTAssertEqual(hydrated.values.first?.messages.first?.imageAttachments.first?.data, data)
  }

  func testReclaimsBlobWhenNoSessionReferencesIt() throws {
    let rootURL = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = AIChatAttachmentStore(directoryURL: rootURL)
    let session = AIPublishingChatSessionState(
      messages: [.init(
        role: .user,
        content: "inspect",
        imageAttachments: [.init(filename: "sample.bin", mimeType: "application/octet-stream", data: Data([1, 2, 3]))]
      )]
    )
    let persisted = try store.persistedSessions([UUID(): session])
    let reference = try XCTUnwrap(persisted.values.first?.messages.first?.imageAttachments.first?.storageReference)

    _ = try store.persistedSessions([:])

    XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(reference).path))
  }

  func testSessionPreparedDropsOldImagesAboveTotalCapacity() {
    let messageData = Data(repeating: 1, count: 10_000_000)
    let messages = (0..<3).map { index in
      AIPublishingChatMessage(
        role: .user,
        content: "message-\(index)",
        imageAttachments: [.init(filename: "\(index).jpg", mimeType: "image/jpeg", data: messageData)]
      )
    }

    let prepared = AIPublishingChatSessionState(messages: messages).prepared(maxTotalImageBytes: 24_000_000)

    XCTAssertTrue(prepared.messages[0].imageAttachments.isEmpty)
    XCTAssertFalse(prepared.messages[1].imageAttachments.isEmpty)
    XCTAssertFalse(prepared.messages[2].imageAttachments.isEmpty)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacAIChatAttachmentTests-\(UUID().uuidString)", isDirectory: true)
  }
}
