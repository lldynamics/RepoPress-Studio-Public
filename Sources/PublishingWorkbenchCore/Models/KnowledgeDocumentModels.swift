import Foundation

public struct KnowledgeDocument: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var kind: KnowledgeDocumentKind
  public var title: String
  public var authors: [String]
  public var language: String?
  public var summary: String
  public var tags: [String]
  public var sourceURL: URL?
  public var sourceName: String
  public var folderID: UUID?
  public var sourceByteCount: Int64
  public var allowsLocalSemanticIndex: Bool
  public var allowsRemoteAIUse: Bool
  public var isArchived: Bool
  public var importedAt: Date
  public var updatedAt: Date
  public var currentRevisionID: UUID

  @available(*, deprecated, message: "请使用 allowsLocalSemanticIndex 或 allowsRemoteAIUse")
  public var allowsAIUse: Bool {
    get { allowsRemoteAIUse }
    set { allowsRemoteAIUse = newValue }
  }

  public init(
    id: UUID = UUID(),
    kind: KnowledgeDocumentKind,
    title: String,
    authors: [String] = [],
    language: String? = nil,
    summary: String = "",
    tags: [String] = [],
    sourceURL: URL? = nil,
    sourceName: String = "",
    folderID: UUID? = nil,
    sourceByteCount: Int64 = 0,
    allowsLocalSemanticIndex: Bool = true,
    allowsRemoteAIUse: Bool = false,
    allowsAIUse: Bool? = nil,
    isArchived: Bool = false,
    importedAt: Date = Date(),
    updatedAt: Date = Date(),
    currentRevisionID: UUID = UUID()
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.authors = authors
    self.language = language
    self.summary = summary
    self.tags = tags
    self.sourceURL = sourceURL
    self.sourceName = sourceName
    self.folderID = folderID
    self.sourceByteCount = max(0, sourceByteCount)
    self.allowsLocalSemanticIndex = allowsLocalSemanticIndex
    self.allowsRemoteAIUse = allowsAIUse ?? allowsRemoteAIUse
    self.isArchived = isArchived
    self.importedAt = importedAt
    self.updatedAt = updatedAt
    self.currentRevisionID = currentRevisionID
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case kind
    case title
    case authors
    case language
    case summary
    case tags
    case sourceURL
    case sourceName
    case folderID
    case sourceByteCount
    case allowsLocalSemanticIndex
    case allowsRemoteAIUse
    case allowsAIUse
    case isArchived
    case importedAt
    case updatedAt
    case currentRevisionID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    kind = try container.decode(KnowledgeDocumentKind.self, forKey: .kind)
    title = try container.decode(String.self, forKey: .title)
    authors = try container.decode([String].self, forKey: .authors)
    language = try container.decodeIfPresent(String.self, forKey: .language)
    summary = try container.decode(String.self, forKey: .summary)
    tags = try container.decode([String].self, forKey: .tags)
    sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
    sourceName = try container.decode(String.self, forKey: .sourceName)
    folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
    sourceByteCount = max(0, try container.decodeIfPresent(Int64.self, forKey: .sourceByteCount) ?? 0)
    allowsLocalSemanticIndex = try container.decodeIfPresent(
      Bool.self,
      forKey: .allowsLocalSemanticIndex
    ) ?? true
    allowsRemoteAIUse = try container.decodeIfPresent(Bool.self, forKey: .allowsRemoteAIUse)
      ?? container.decodeIfPresent(Bool.self, forKey: .allowsAIUse)
      ?? false
    isArchived = try container.decode(Bool.self, forKey: .isArchived)
    importedAt = try container.decode(Date.self, forKey: .importedAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    currentRevisionID = try container.decode(UUID.self, forKey: .currentRevisionID)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(kind, forKey: .kind)
    try container.encode(title, forKey: .title)
    try container.encode(authors, forKey: .authors)
    try container.encodeIfPresent(language, forKey: .language)
    try container.encode(summary, forKey: .summary)
    try container.encode(tags, forKey: .tags)
    try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
    try container.encode(sourceName, forKey: .sourceName)
    try container.encodeIfPresent(folderID, forKey: .folderID)
    try container.encode(sourceByteCount, forKey: .sourceByteCount)
    try container.encode(allowsLocalSemanticIndex, forKey: .allowsLocalSemanticIndex)
    try container.encode(allowsRemoteAIUse, forKey: .allowsRemoteAIUse)
    try container.encode(allowsRemoteAIUse, forKey: .allowsAIUse)
    try container.encode(isArchived, forKey: .isArchived)
    try container.encode(importedAt, forKey: .importedAt)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encode(currentRevisionID, forKey: .currentRevisionID)
  }
}
public struct KnowledgeDocumentRevision: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var documentID: UUID
  public var originalContentHash: String
  public var normalizedContentHash: String
  public var parserVersion: Int
  public var importedAt: Date
  public var sourceModifiedAt: Date?
  public var originalStorageReference: String?
  public var capturedTextStorageReference: String?
  public var normalizedStorageReference: String

  public init(
    id: UUID = UUID(),
    documentID: UUID,
    originalContentHash: String,
    normalizedContentHash: String,
    parserVersion: Int,
    importedAt: Date = Date(),
    sourceModifiedAt: Date? = nil,
    originalStorageReference: String? = nil,
    capturedTextStorageReference: String? = nil,
    normalizedStorageReference: String
  ) {
    self.id = id
    self.documentID = documentID
    self.originalContentHash = originalContentHash
    self.normalizedContentHash = normalizedContentHash
    self.parserVersion = parserVersion
    self.importedAt = importedAt
    self.sourceModifiedAt = sourceModifiedAt
    self.originalStorageReference = originalStorageReference
    self.capturedTextStorageReference = capturedTextStorageReference
    self.normalizedStorageReference = normalizedStorageReference
  }
}

public struct KnowledgeRecycledDocument: Identifiable, Hashable, Sendable {
  public var id: UUID { document.id }
  public var document: KnowledgeDocument
  public var deletedAt: Date

  public init(document: KnowledgeDocument, deletedAt: Date) {
    self.document = document
    self.deletedAt = deletedAt
  }
}

public struct KnowledgeDocumentMetadata: Hashable, Sendable {
  public var kind: KnowledgeDocumentKind
  public var title: String
  public var authors: [String]
  public var language: String?
  public var summary: String
  public var tags: [String]

  public init(
    kind: KnowledgeDocumentKind,
    title: String,
    authors: [String] = [],
    language: String? = nil,
    summary: String = "",
    tags: [String] = []
  ) {
    self.kind = kind
    self.title = title
    self.authors = authors
    self.language = language
    self.summary = summary
    self.tags = tags
  }

  public init(document: KnowledgeDocument) {
    self.init(
      kind: document.kind,
      title: document.title,
      authors: document.authors,
      language: document.language,
      summary: document.summary,
      tags: document.tags
    )
  }
}

public struct KnowledgeAnnotation: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var documentID: UUID
  public var revisionID: UUID?
  public var chunkID: UUID?
  public var locator: String?
  public var highlightedText: String
  public var note: String
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    documentID: UUID,
    revisionID: UUID? = nil,
    chunkID: UUID? = nil,
    locator: String? = nil,
    highlightedText: String = "",
    note: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.documentID = documentID
    self.revisionID = revisionID
    self.chunkID = chunkID
    self.locator = locator
    self.highlightedText = highlightedText
    self.note = note
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum KnowledgeBacklinkTargetKind: String, Codable, CaseIterable, Sendable {
  case articleDraft
  case aiResponse

  public var displayName: String {
    switch self {
    case .articleDraft: "文章"
    case .aiResponse: "AI 回复"
    }
  }
}

public struct KnowledgeBacklinkTarget: Hashable, Sendable {
  public var kind: KnowledgeBacklinkTargetKind
  public var id: String
  public var title: String
  public var location: String?

  public init(
    kind: KnowledgeBacklinkTargetKind,
    id: String,
    title: String,
    location: String? = nil
  ) {
    self.kind = kind
    self.id = id
    self.title = title
    self.location = location
  }
}

public struct KnowledgeBacklink: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var documentID: UUID
  public var chunkID: UUID
  public var targetKind: KnowledgeBacklinkTargetKind
  public var targetID: String
  public var targetTitle: String
  public var targetLocation: String?
  public var chunkLocator: String?
  public var chunkExcerpt: String?
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    documentID: UUID,
    chunkID: UUID,
    targetKind: KnowledgeBacklinkTargetKind,
    targetID: String,
    targetTitle: String,
    targetLocation: String? = nil,
    chunkLocator: String? = nil,
    chunkExcerpt: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.documentID = documentID
    self.chunkID = chunkID
    self.targetKind = targetKind
    self.targetID = targetID
    self.targetTitle = targetTitle
    self.targetLocation = targetLocation
    self.chunkLocator = chunkLocator
    self.chunkExcerpt = chunkExcerpt
    self.createdAt = createdAt
  }
}

public struct KnowledgeBacklinkGroup: Identifiable, Hashable, Sendable {
  public var id: String { "\(targetKind.rawValue):\(targetID)" }
  public var targetKind: KnowledgeBacklinkTargetKind
  public var targetID: String
  public var targetTitle: String
  public var targetLocation: String?
  public var createdAt: Date
  public var backlinks: [KnowledgeBacklink]

  public init?(backlinks: [KnowledgeBacklink]) {
    guard !backlinks.isEmpty else { return nil }
    let sorted = backlinks.sorted { $0.createdAt > $1.createdAt }
    let first = sorted[0]
    targetKind = first.targetKind
    targetID = first.targetID
    targetTitle = first.targetTitle
    targetLocation = first.targetLocation
    createdAt = first.createdAt
    self.backlinks = sorted
  }

  public var citedChunkIDs: [UUID] {
    Array(Set(backlinks.map(\.chunkID))).sorted { $0.uuidString < $1.uuidString }
  }
}

public struct KnowledgeRevisionDifference: Hashable, Sendable {
  public var previousLineCount: Int
  public var currentLineCount: Int
  public var addedLineCount: Int
  public var removedLineCount: Int
  public var previousExcerpt: String
  public var currentExcerpt: String

  public init(
    previousLineCount: Int,
    currentLineCount: Int,
    addedLineCount: Int,
    removedLineCount: Int,
    previousExcerpt: String,
    currentExcerpt: String
  ) {
    self.previousLineCount = max(0, previousLineCount)
    self.currentLineCount = max(0, currentLineCount)
    self.addedLineCount = max(0, addedLineCount)
    self.removedLineCount = max(0, removedLineCount)
    self.previousExcerpt = previousExcerpt
    self.currentExcerpt = currentExcerpt
  }

  public var hasChanges: Bool {
    addedLineCount > 0 || removedLineCount > 0
  }
}

public struct KnowledgeSourceRefreshPreview: Hashable, Sendable {
  public var documentID: UUID
  public var currentRevision: KnowledgeDocumentRevision
  public var importPreview: KnowledgeImportPreview
  public var difference: KnowledgeRevisionDifference

  public init(
    documentID: UUID,
    currentRevision: KnowledgeDocumentRevision,
    importPreview: KnowledgeImportPreview,
    difference: KnowledgeRevisionDifference
  ) {
    self.documentID = documentID
    self.currentRevision = currentRevision
    self.importPreview = importPreview
    self.difference = difference
  }
}

public struct KnowledgeLibraryHealthSnapshot: Hashable, Sendable {
  public var currentParserVersion: Int
  public var documentCount: Int
  public var indexedChunkCount: Int
  public var outdatedParserDocumentCount: Int
  public var locallyRepairableDocumentCount: Int
  public var lowQualityChunkCount: Int
  public var semanticRepairChunkCount: Int

  public init(
    currentParserVersion: Int,
    documentCount: Int,
    indexedChunkCount: Int,
    outdatedParserDocumentCount: Int,
    locallyRepairableDocumentCount: Int,
    lowQualityChunkCount: Int,
    semanticRepairChunkCount: Int
  ) {
    self.currentParserVersion = currentParserVersion
    self.documentCount = max(0, documentCount)
    self.indexedChunkCount = max(0, indexedChunkCount)
    self.outdatedParserDocumentCount = max(0, outdatedParserDocumentCount)
    self.locallyRepairableDocumentCount = max(0, locallyRepairableDocumentCount)
    self.lowQualityChunkCount = max(0, lowQualityChunkCount)
    self.semanticRepairChunkCount = max(0, semanticRepairChunkCount)
  }

  public var needsAttention: Bool {
    outdatedParserDocumentCount > 0
      || lowQualityChunkCount > 0
      || semanticRepairChunkCount > 0
  }
}
