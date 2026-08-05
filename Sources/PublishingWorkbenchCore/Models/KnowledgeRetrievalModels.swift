import Foundation

public struct KnowledgeChunk: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var documentID: UUID
  public var revisionID: UUID
  public var ordinal: Int
  public var headingPath: String?
  public var locator: String?
  public var content: String
  public var tokenEstimate: Int
  public var contentHash: String

  public init(
    id: UUID = UUID(),
    documentID: UUID,
    revisionID: UUID,
    ordinal: Int,
    headingPath: String? = nil,
    locator: String? = nil,
    content: String,
    tokenEstimate: Int,
    contentHash: String
  ) {
    self.id = id
    self.documentID = documentID
    self.revisionID = revisionID
    self.ordinal = ordinal
    self.headingPath = headingPath
    self.locator = locator
    self.content = content
    self.tokenEstimate = tokenEstimate
    self.contentHash = contentHash
  }
}
public enum KnowledgeRetrievalSignal: String, Hashable, Sendable {
  case title
  case fullText
  case semantic
}

public struct KnowledgeSearchResult: Identifiable, Hashable, Sendable {
  public var id: UUID { chunk.id }
  public var document: KnowledgeDocument
  public var chunk: KnowledgeChunk
  public var score: Double
  public var signals: Set<KnowledgeRetrievalSignal>

  public init(
    document: KnowledgeDocument,
    chunk: KnowledgeChunk,
    score: Double,
    signals: Set<KnowledgeRetrievalSignal> = []
  ) {
    self.document = document
    self.chunk = chunk
    self.score = score
    self.signals = signals
  }
}

public enum KnowledgeRelatedChapterReason: Hashable, Sendable {
  case sameDocument
  case author(String)
  case tag(String)
  case sourceDomain(String)
  case nearbyTime
  case semantic
}

public struct KnowledgeRelatedChapter: Identifiable, Hashable, Sendable {
  public var id: UUID { chunk.id }
  public var document: KnowledgeDocument
  public var chunk: KnowledgeChunk
  public var score: Double
  public var reasons: [KnowledgeRelatedChapterReason]

  public init(
    document: KnowledgeDocument,
    chunk: KnowledgeChunk,
    score: Double,
    reasons: [KnowledgeRelatedChapterReason]
  ) {
    self.document = document
    self.chunk = chunk
    self.score = score
    self.reasons = reasons
  }
}

public struct KnowledgeSemanticRepairReport: Hashable, Sendable {
  public var scannedChunkCount: Int
  public var regeneratedVectorCount: Int
  public var modelIdentifiers: [String]

  public init(
    scannedChunkCount: Int,
    regeneratedVectorCount: Int,
    modelIdentifiers: [String]
  ) {
    self.scannedChunkCount = scannedChunkCount
    self.regeneratedVectorCount = regeneratedVectorCount
    self.modelIdentifiers = modelIdentifiers.sorted()
  }
}

public struct KnowledgeCitation: Identifiable, Codable, Hashable, Sendable {
  public var id: String
  public var documentID: UUID
  public var chunkID: UUID
  public var title: String
  public var authors: [String]
  public var locator: String?
  public var excerpt: String
  public var sourceURL: URL?

  public init(
    id: String,
    documentID: UUID,
    chunkID: UUID,
    title: String,
    authors: [String] = [],
    locator: String? = nil,
    excerpt: String,
    sourceURL: URL? = nil
  ) {
    self.id = id
    self.documentID = documentID
    self.chunkID = chunkID
    self.title = title
    self.authors = authors
    self.locator = locator
    self.excerpt = excerpt
    self.sourceURL = sourceURL
  }
}

public struct KnowledgeContextSnapshot: Hashable, Sendable {
  public var query: String
  public var citations: [KnowledgeCitation]

  public init(query: String, citations: [KnowledgeCitation]) {
    self.query = query
    self.citations = citations
  }

  public var promptText: String {
    citations.map { citation in
      let authorText = citation.authors.isEmpty ? "未记录" : citation.authors.joined(separator: "、")
      let locatorText = citation.locator?.nilIfEmpty ?? "未记录"
      return """
      [\(citation.id)]
      标题：\(citation.title)
      作者：\(authorText)
      位置：\(locatorText)
      内容：\(citation.excerpt)
      """
    }
    .joined(separator: "\n\n")
  }
}

public struct KnowledgeExtractedSection: Hashable, Sendable {
  public var headingPath: String?
  public var locator: String?
  public var text: String

  public init(headingPath: String? = nil, locator: String? = nil, text: String) {
    self.headingPath = headingPath
    self.locator = locator
    self.text = text
  }
}
