import Foundation

public struct KnowledgeImportCandidate: Identifiable, Hashable, Sendable {
  public var id: UUID
  public var existingDocumentID: UUID?
  public var disposition: KnowledgeImportDisposition
  public var kind: KnowledgeDocumentKind
  public var title: String
  public var authors: [String]
  public var language: String?
  public var summary: String
  public var tags: [String]
  public var sourceURL: URL?
  public var sourceName: String
  public var sourceModifiedAt: Date?
  public var allowsLocalSemanticIndex: Bool?
  public var allowsRemoteAIUse: Bool?

  @available(*, deprecated, message: "请使用 allowsLocalSemanticIndex 或 allowsRemoteAIUse")
  public var allowsAIUse: Bool? {
    get { allowsRemoteAIUse }
    set { allowsRemoteAIUse = newValue }
  }
  public var originalFilenameExtension: String?
  public var originalData: Data?
  public var capturedText: String?
  public var originalContentHash: String
  public var normalizedText: String
  public var normalizedContentHash: String
  public var sections: [KnowledgeExtractedSection]
  public var warnings: [String]

  public init(
    id: UUID = UUID(),
    existingDocumentID: UUID? = nil,
    disposition: KnowledgeImportDisposition = .new,
    kind: KnowledgeDocumentKind,
    title: String,
    authors: [String] = [],
    language: String? = nil,
    summary: String = "",
    tags: [String] = [],
    sourceURL: URL? = nil,
    sourceName: String,
    sourceModifiedAt: Date? = nil,
    allowsLocalSemanticIndex: Bool? = nil,
    allowsRemoteAIUse: Bool? = nil,
    allowsAIUse: Bool? = nil,
    originalFilenameExtension: String? = nil,
    originalData: Data? = nil,
    capturedText: String? = nil,
    originalContentHash: String,
    normalizedText: String,
    normalizedContentHash: String,
    sections: [KnowledgeExtractedSection],
    warnings: [String] = []
  ) {
    self.id = id
    self.existingDocumentID = existingDocumentID
    self.disposition = disposition
    self.kind = kind
    self.title = title
    self.authors = authors
    self.language = language
    self.summary = summary
    self.tags = tags
    self.sourceURL = sourceURL
    self.sourceName = sourceName
    self.sourceModifiedAt = sourceModifiedAt
    self.allowsLocalSemanticIndex = allowsLocalSemanticIndex
    self.allowsRemoteAIUse = allowsRemoteAIUse ?? allowsAIUse
    self.originalFilenameExtension = originalFilenameExtension
    self.originalData = originalData
    self.capturedText = capturedText
    self.originalContentHash = originalContentHash
    self.normalizedText = normalizedText
    self.normalizedContentHash = normalizedContentHash
    self.sections = sections
    self.warnings = warnings
  }
}
public struct KnowledgeImportPreview: Hashable, Sendable {
  public var sourceName: String
  public var candidates: [KnowledgeImportCandidate]
  public var warnings: [String]

  public init(sourceName: String, candidates: [KnowledgeImportCandidate], warnings: [String] = []) {
    self.sourceName = sourceName
    self.candidates = candidates
    self.warnings = warnings
  }

  public var newCount: Int { candidates.filter { $0.disposition == .new }.count }
  public var updateCount: Int { candidates.filter { $0.disposition == .update }.count }
  public var duplicateCount: Int { candidates.filter { $0.disposition == .duplicate }.count }
  public var importableCount: Int { newCount + updateCount }
}

public struct KnowledgeImportResult: Hashable, Sendable {
  public var insertedCount: Int
  public var updatedCount: Int
  public var skippedCount: Int
  public var documentIDs: [UUID]

  public init(
    insertedCount: Int,
    updatedCount: Int,
    skippedCount: Int,
    documentIDs: [UUID] = []
  ) {
    self.insertedCount = insertedCount
    self.updatedCount = updatedCount
    self.skippedCount = skippedCount
    self.documentIDs = documentIDs
  }
}

public struct KnowledgeDocumentDeletionReport: Hashable, Sendable {
  public var removedStoredFileCount: Int
  public var failedStoredFileCount: Int

  public init(
    removedStoredFileCount: Int,
    failedStoredFileCount: Int
  ) {
    self.removedStoredFileCount = max(0, removedStoredFileCount)
    self.failedStoredFileCount = max(0, failedStoredFileCount)
  }
}

public struct KnowledgeRecycleBinCleanupSummary: Hashable, Sendable {
  public var requestedDocumentCount: Int
  public var removedDocumentCount: Int
  public var failedDocumentCount: Int
  public var removedStoredFileCount: Int
  public var failedStoredFileCount: Int

  public init(
    requestedDocumentCount: Int,
    removedDocumentCount: Int,
    failedDocumentCount: Int,
    removedStoredFileCount: Int,
    failedStoredFileCount: Int
  ) {
    self.requestedDocumentCount = max(0, requestedDocumentCount)
    self.removedDocumentCount = max(0, removedDocumentCount)
    self.failedDocumentCount = max(0, failedDocumentCount)
    self.removedStoredFileCount = max(0, removedStoredFileCount)
    self.failedStoredFileCount = max(0, failedStoredFileCount)
  }
}

public struct KnowledgeBatchExportReport: Hashable, Sendable {
  public var exportedDocumentCount: Int
  public var destinationDirectory: URL

  public init(exportedDocumentCount: Int, destinationDirectory: URL) {
    self.exportedDocumentCount = max(0, exportedDocumentCount)
    self.destinationDirectory = destinationDirectory
  }
}
