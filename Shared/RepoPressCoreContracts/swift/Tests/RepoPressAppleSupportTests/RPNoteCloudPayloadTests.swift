import Foundation
import RepoPressAppleSupport
import XCTest

final class RPNoteCloudPayloadTests: XCTestCase {
  func testEnvelopeRoundTripPreservesMetadataAndRebuildsAttachments() throws {
    let noteID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let attachmentID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let created = Date(timeIntervalSince1970: 1_700_000_000.123_456_7)
    let updated = Date(timeIntervalSince1970: 1_700_000_001.987_654_3)
    let attachment = RPNoteAttachment(
      id: attachmentID, fileName: "图片.png", mimeType: "image/png", data: Data([0, 1, 127, 128, 255])
    )
    let note = RPNote(
      id: noteID, title: "跨端笔记", tags: ["同步", "想法"], createdAt: created, updatedAt: updated,
      isArchived: true, sourceURL: URL(string: "https://example.com/a?q=1")!,
      markdown: "# 内容\n\n保留 UTF-8。",
      attachments: [attachment]
    )
    let encoded = try RPNoteCloudPayload.encode(note)
    let envelope = try RPNoteCloudPayload.decode(encoded)
    XCTAssertEqual(envelope.note.id, noteID)
    XCTAssertEqual(envelope.note.title, note.title)
    XCTAssertEqual(envelope.note.tags, note.tags)
    XCTAssertEqual(envelope.note.isArchived, true)
    XCTAssertEqual(envelope.note.sourceURL, note.sourceURL)
    XCTAssertEqual(envelope.note.markdown, note.markdown)
    XCTAssertTrue(envelope.note.attachments.isEmpty)
    XCTAssertEqual(envelope.attachments.map(\.id), [attachmentID])
    XCTAssertEqual(envelope.attachments.first?.byteCount, 5)
    XCTAssertLessThan(abs(envelope.note.createdAt.timeIntervalSince(created)), 0.000_001)
    XCTAssertLessThan(abs(envelope.note.updatedAt.timeIntervalSince(updated)), 0.000_001)

    let rebuilt = try RPNoteCloudPayload.assemble(envelope) { _ in attachment.data }
    XCTAssertEqual(rebuilt.attachments, note.attachments)
    // Rebuilding and re-encoding reproduces the revision computed from the original note.
    XCTAssertEqual(try RPNoteCloudPayload.encode(rebuilt), encoded)
  }

  func testEnvelopeOmitsAttachmentBytesButItsRevisionCoversThem() throws {
    let marker = Data("attachment-bytes-must-not-be-embedded".utf8)
    let id = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
    let attachmentID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    func note(_ data: Data) -> RPNote {
      RPNote(
        id: id, createdAt: date, updatedAt: date, markdown: "x",
        attachments: [RPNoteAttachment(id: attachmentID, fileName: "a", mimeType: "x/a", data: data)]
      )
    }
    let encoded = try RPNoteCloudPayload.encode(note(marker))
    XCTAssertNil(encoded.range(of: marker))
    var changed = marker
    changed[0] ^= 1
    XCTAssertNotEqual(try RPNoteCloudPayload.encode(note(changed)), encoded)
  }

  func testAssembleRejectsBytesThatDoNotMatchTheEnvelope() throws {
    let attachment = RPNoteAttachment(fileName: "a", mimeType: "x/a", data: Data([1, 2, 3]))
    let envelope = try RPNoteCloudPayload.decode(
      RPNoteCloudPayload.encode(RPNote(markdown: "body", attachments: [attachment]))
    )
    XCTAssertThrowsError(try RPNoteCloudPayload.assemble(envelope) { _ in Data([1, 2, 4]) })
    XCTAssertThrowsError(try RPNoteCloudPayload.assemble(envelope) { _ in Data([1, 2]) })
  }

  func testEncodingIsDeterministicAndIndependentOfAttachmentOrder() throws {
    let first = RPNoteAttachment(
      id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!, fileName: "a", mimeType: "x/a", data: Data([1])
    )
    let second = RPNoteAttachment(
      id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!, fileName: "b", mimeType: "x/b", data: Data([2])
    )
    let id = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
    let created = Date(timeIntervalSince1970: 1_700_000_000.5)
    let updated = Date(timeIntervalSince1970: 1_700_000_001.5)
    let ordered = RPNote(id: id, createdAt: created, updatedAt: updated, markdown: "x", attachments: [first, second])
    let reversed = RPNote(id: id, createdAt: created, updatedAt: updated, markdown: "x", attachments: [second, first])
    XCTAssertEqual(try RPNoteCloudPayload.encode(ordered), try RPNoteCloudPayload.encode(reversed))
  }

  func testRejectsTamperedPayloadAndMalformedHeader() throws {
    var bytes = try RPNoteCloudPayload.encode(RPNote(markdown: "body"))
    bytes[bytes.count - 1] ^= 0xff
    XCTAssertThrowsError(try RPNoteCloudPayload.decode(bytes))
    XCTAssertThrowsError(try RPNoteCloudPayload.decode(Data("bad".utf8)))
  }

  func testRejectsCredentialsInSourceURL() throws {
    let note = RPNote(sourceURL: URL(string: "https://user:secret@example.com/")!, markdown: "body")
    XCTAssertThrowsError(try RPNoteCloudPayload.encode(note))
  }

}
