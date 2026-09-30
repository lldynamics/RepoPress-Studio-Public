import CryptoKit
import Foundation

extension KnowledgeNoteCloudSyncAdapter {
  static func revision(for note: RPNote) throws -> String {
    SHA256.hash(data: try RPNoteCloudPayload.encode(note)).map { String(format: "%02x", $0) }
      .joined()
  }

  static func deterministicUUID(namespace: UUID, name: String) -> UUID {
    var digest = Array(
      SHA256.hash(data: Data("\(namespace.uuidString.lowercased())|\(name)".utf8)).prefix(16))
    digest[6] = (digest[6] & 0x0f) | 0x50
    digest[8] = (digest[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
        digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
      ))
  }

  static func portableNote(_ note: KnowledgeNote) -> RPNote {
    RPNote(
      id: note.id,
      title: note.title,
      tags: note.tags,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      isArchived: note.isArchived,
      sourceURL: note.sourceURL,
      markdown: note.markdown,
      attachments: note.attachments.map {
        RPNoteAttachment(
          id: $0.id, fileName: $0.fileName, mimeType: $0.mimeType ?? "application/octet-stream",
          data: $0.data)
      }
    )
  }

  static func knowledgeNote(_ note: RPNote) -> KnowledgeNote {
    KnowledgeNote(
      id: note.id,
      title: note.title,
      tags: note.tags,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      isArchived: note.isArchived,
      sourceURL: note.sourceURL,
      markdown: note.markdown,
      attachments: note.attachments.map {
        KnowledgeNoteAttachment(
          id: $0.id, fileName: $0.fileName, mimeType: $0.mimeType, data: $0.data)
      }
    )
  }
}
