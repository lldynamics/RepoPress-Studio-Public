import Foundation

/// A user-authored Markdown note. Notes are stored in the local knowledge
/// library but remain separate from imported sources and publishing drafts.
public struct KnowledgeNote: Identifiable, Hashable, Sendable {
  public var id: UUID
  public var title: String
  public var tags: [String]
  public var createdAt: Date
  public var updatedAt: Date
  public var isArchived: Bool
  public var sourceURL: URL?
  public var markdown: String
  public var attachments: [KnowledgeNoteAttachment]

  public init(
    id: UUID = UUID(),
    title: String = "",
    tags: [String] = [],
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    isArchived: Bool = false,
    sourceURL: URL? = nil,
    markdown: String = "",
    attachments: [KnowledgeNoteAttachment] = []
  ) {
    self.id = id
    self.title = title
    self.tags = tags
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.isArchived = isArchived
    self.sourceURL = sourceURL
    self.markdown = markdown
    self.attachments = attachments
  }
}

/// Binary data owned by a user note. The data remains in the local library
/// until an explicit export or article insertion action uses it.
public struct KnowledgeNoteAttachment: Identifiable, Hashable, Sendable {
  public var id: UUID
  public var fileName: String
  public var mimeType: String?
  public var data: Data

  public init(
    id: UUID = UUID(),
    fileName: String,
    mimeType: String? = nil,
    data: Data
  ) {
    self.id = id
    self.fileName = fileName
    self.mimeType = mimeType
    self.data = data
  }
}

public struct KnowledgeNoteSignature: Hashable, Sendable {
  public var id: UUID
  public var contentHash: String
  public var attachmentHashes: [UUID: String]

  public init(id: UUID, contentHash: String, attachmentHashes: [UUID: String]) {
    self.id = id
    self.contentHash = contentHash
    self.attachmentHashes = attachmentHashes
  }
}

public enum KnowledgeNoteImportMode: Sendable {
  /// Refuses a different note with the same stable identifier.
  case rejectConflict
  /// Imports a different note as a new local note while retaining the source.
  case copyWithNewID
  /// Replaces the current local note only after the caller explicitly chooses it.
  case replaceExisting
}

public enum KnowledgeNoteImportDisposition: Sendable, Equatable {
  case inserted(UUID)
  case skippedIdentical(UUID)
  case copied(sourceID: UUID, localID: UUID)
  case replaced(UUID)
}
