import Foundation
import PublishingCoreSupport

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

/// A content binding for one knowledge source that is about to be sent to a
/// remote AI provider.  Automatic retrieval binds an individual chunk;
/// explicit @ references bind the exact normalized document revision.
public struct KnowledgeAuthorizationBinding: Codable, Hashable, Sendable {
  public let documentID: UUID
  public let revisionID: UUID
  public let chunkID: UUID?
  public let contentHash: String

  public init(
    documentID: UUID,
    revisionID: UUID,
    chunkID: UUID? = nil,
    contentHash: String
  ) {
    self.documentID = documentID
    self.revisionID = revisionID
    self.chunkID = chunkID
    self.contentHash = contentHash
  }
}

/// The exact text and authorization binding captured for an explicit
/// knowledge @ reference.  The binding remains tied to the revision used to
/// read `text`, even if a newer revision is imported later.
public struct KnowledgeExplicitContextSnapshot: Hashable, Sendable {
  public let text: String
  public let authorizationBinding: KnowledgeAuthorizationBinding

  public init(
    text: String,
    authorizationBinding: KnowledgeAuthorizationBinding
  ) {
    self.text = text
    self.authorizationBinding = authorizationBinding
  }

  public var binding: KnowledgeAuthorizationBinding { authorizationBinding }
}

/// A prompt assembled from explicit context references plus the knowledge
/// bindings for the sections that were actually included in the prompt.
public struct AIContextPromptSnapshot: Hashable, Sendable {
  public let prompt: String
  public let authorizationBindings: [KnowledgeAuthorizationBinding]

  public init(
    prompt: String,
    authorizationBindings: [KnowledgeAuthorizationBinding] = []
  ) {
    self.prompt = prompt
    self.authorizationBindings = authorizationBindings
  }

  public var knowledgeBindings: [KnowledgeAuthorizationBinding] { authorizationBindings }
}

public struct KnowledgeContextSnapshot: Codable, Hashable, Sendable {
  public var query: String
  public var citations: [KnowledgeCitation]
  public var authorizationBindings: [KnowledgeAuthorizationBinding]

  public init(
    query: String,
    citations: [KnowledgeCitation],
    authorizationBindings: [KnowledgeAuthorizationBinding] = []
  ) {
    self.query = query
    self.citations = citations
    self.authorizationBindings = authorizationBindings
  }

  private enum CodingKeys: String, CodingKey {
    case query
    case citations
    case authorizationBindings
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    query = try container.decode(String.self, forKey: .query)
    citations = try container.decode([KnowledgeCitation].self, forKey: .citations)
    // Continuations and saved requests written before authorization bindings
    // existed remain readable, but carry no implicit authority.
    authorizationBindings =
      try container.decodeIfPresent(
        [KnowledgeAuthorizationBinding].self,
        forKey: .authorizationBindings
      ) ?? []
  }

  public var knowledgeBindings: [KnowledgeAuthorizationBinding] {
    get { authorizationBindings }
    set { authorizationBindings = newValue }
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
