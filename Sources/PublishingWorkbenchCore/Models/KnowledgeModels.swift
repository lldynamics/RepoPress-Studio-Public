import Foundation

public enum KnowledgeDocumentKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case article
  case book
  case webpage
  case pdf
  case markdown
  case text
  case note
  case other

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .article: "文章"
    case .book: "书籍"
    case .webpage: "网页"
    case .pdf: "PDF"
    case .markdown: "Markdown"
    case .text: "文本"
    case .note: "笔记"
    case .other: "其他"
    }
  }

  public var systemImage: String {
    switch self {
    case .article: "doc.text"
    case .book: "books.vertical"
    case .webpage: "globe"
    case .pdf: "doc.richtext"
    case .markdown: "text.document"
    case .text: "doc.plaintext"
    case .note: "note.text"
    case .other: "archivebox"
    }
  }
}

public enum KnowledgeImportDisposition: String, Codable, Sendable {
  case new
  case update
  case duplicate

  public var displayName: String {
    switch self {
    case .new: "新增"
    case .update: "更新"
    case .duplicate: "重复"
    }
  }
}

public enum KnowledgeRetrievalPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
  case off
  case automatic
  case pinnedOnly

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .off: "关闭资料库"
    case .automatic: "自动检索"
    case .pinnedOnly: "仅固定资料"
    }
  }

  public var detail: String {
    switch self {
    case .off: "本轮对话不读取资料库。"
    case .automatic: "根据当前文章和问题自动寻找相关片段。"
    case .pinnedOnly: "只使用你为当前对话固定的资料。"
    }
  }
}

public struct KnowledgeFolder: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var name: String
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum KnowledgeFolderScope: Hashable, Sendable {
  case all
  case unfiled
  case folder(UUID)
  case smartCollection(KnowledgeSmartCollectionRule)
  case savedCollection(KnowledgeSavedCollection)
}

public enum KnowledgeSmartCollectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case author
  case tag
  case sourceDomain
  case time
  case aiPermission

  public var id: String { rawValue }
}

public enum KnowledgeSmartTimeBucket: String, Codable, CaseIterable, Identifiable, Sendable {
  case today
  case thisWeek
  case thisMonth
  case earlier

  public var id: String { rawValue }
}

public enum KnowledgeSmartCollectionRule: Codable, Hashable, Sendable {
  case author(String)
  case tag(String)
  case sourceDomain(String)
  case time(KnowledgeSmartTimeBucket)
  case aiPermission(Bool)

  public var kind: KnowledgeSmartCollectionKind {
    switch self {
    case .author: .author
    case .tag: .tag
    case .sourceDomain: .sourceDomain
    case .time: .time
    case .aiPermission: .aiPermission
    }
  }

  public var id: String {
    switch self {
    case .author(let value): "author:\(value.lowercased())"
    case .tag(let value): "tag:\(value.lowercased())"
    case .sourceDomain(let value): "domain:\(value.lowercased())"
    case .time(let value): "time:\(value.rawValue)"
    case .aiPermission(let value): "ai:\(value)"
    }
  }
}

public enum KnowledgeSmartCollectionMatchMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case all
  case any

  public var id: String { rawValue }
}

public struct KnowledgeSavedCollection: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var name: String
  public var rules: [KnowledgeSmartCollectionRule]
  public var matchMode: KnowledgeSmartCollectionMatchMode
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    rules: [KnowledgeSmartCollectionRule],
    matchMode: KnowledgeSmartCollectionMatchMode = .all,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    var seen = Set<String>()
    self.rules = rules.filter { seen.insert($0.id).inserted }
    self.matchMode = matchMode
    self.createdAt = createdAt
  }
}

public struct KnowledgeSmartCollection: Identifiable, Hashable, Sendable {
  public var id: String { rule.id }
  public var rule: KnowledgeSmartCollectionRule
  public var documentCount: Int

  public init(rule: KnowledgeSmartCollectionRule, documentCount: Int) {
    self.rule = rule
    self.documentCount = max(0, documentCount)
  }
}

public enum KnowledgeDocumentSortField: String, CaseIterable, Identifiable, Sendable {
  case title
  case kind
  case fileSize
  case addedAt
  case updatedAt

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .title: "标题"
    case .kind: "类型"
    case .fileSize: "文件大小"
    case .addedAt: "添加时间"
    case .updatedAt: "更新时间"
    }
  }
}

public enum KnowledgeSortDirection: String, CaseIterable, Identifiable, Sendable {
  case ascending
  case descending

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .ascending: "升序"
    case .descending: "降序"
    }
  }

  public var systemImage: String {
    switch self {
    case .ascending: "arrow.up"
    case .descending: "arrow.down"
    }
  }
}

public struct KnowledgeDocumentSort: Hashable, Sendable {
  public var field: KnowledgeDocumentSortField
  public var direction: KnowledgeSortDirection

  public init(
    field: KnowledgeDocumentSortField = .addedAt,
    direction: KnowledgeSortDirection = .descending
  ) {
    self.field = field
    self.direction = direction
  }

  public func sorted(_ documents: [KnowledgeDocument]) -> [KnowledgeDocument] {
    documents.sorted { lhs, rhs in
      let comparison = primaryComparison(lhs, rhs)
      if comparison != .orderedSame {
        return direction == .ascending
          ? comparison == .orderedAscending
          : comparison == .orderedDescending
      }
      let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
      if titleComparison != .orderedSame {
        return titleComparison == .orderedAscending
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  private func primaryComparison(_ lhs: KnowledgeDocument, _ rhs: KnowledgeDocument) -> ComparisonResult {
    switch field {
    case .title:
      return lhs.title.localizedStandardCompare(rhs.title)
    case .kind:
      return lhs.kind.displayName.localizedStandardCompare(rhs.kind.displayName)
    case .fileSize:
      return compare(lhs.sourceByteCount, rhs.sourceByteCount)
    case .addedAt:
      return compare(lhs.importedAt, rhs.importedAt)
    case .updatedAt:
      return compare(lhs.updatedAt, rhs.updatedAt)
    }
  }

  private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
    if lhs < rhs { return .orderedAscending }
    if lhs > rhs { return .orderedDescending }
    return .orderedSame
  }
}

public enum KnowledgeSearchScope: String, CaseIterable, Identifiable, Sendable {
  case currentCollection
  case allLibrary

  public var id: String { rawValue }
}

public enum KnowledgeSearchSignalFilter: String, CaseIterable, Identifiable, Sendable {
  case all
  case title
  case fullText
  case semantic

  public var id: String { rawValue }

  public var signal: KnowledgeRetrievalSignal? {
    switch self {
    case .all: nil
    case .title: .title
    case .fullText: .fullText
    case .semantic: .semantic
    }
  }
}

public enum KnowledgeSearchResultSort: String, CaseIterable, Identifiable, Sendable {
  case relevance
  case addedNewest

  public var id: String { rawValue }
}

public struct KnowledgeSearchFilter: Hashable, Sendable {
  public var scope: KnowledgeSearchScope
  public var signal: KnowledgeSearchSignalFilter
  public var sort: KnowledgeSearchResultSort

  public init(
    scope: KnowledgeSearchScope = .currentCollection,
    signal: KnowledgeSearchSignalFilter = .all,
    sort: KnowledgeSearchResultSort = .relevance
  ) {
    self.scope = scope
    self.signal = signal
    self.sort = sort
  }

  public func filtered(
    _ results: [KnowledgeSearchResult],
    isInCurrentCollection: (KnowledgeDocument) -> Bool
  ) -> [KnowledgeSearchResult] {
    let scoped = results.filter { result in
      (scope == .allLibrary || isInCurrentCollection(result.document))
        && (signal.signal.map(result.signals.contains) ?? true)
    }
    switch sort {
    case .relevance:
      return scoped
    case .addedNewest:
      return scoped.sorted {
        if $0.document.importedAt != $1.document.importedAt {
          return $0.document.importedAt > $1.document.importedAt
        }
        if $0.document.id != $1.document.id {
          return $0.document.title.localizedStandardCompare($1.document.title) == .orderedAscending
        }
        return $0.chunk.ordinal < $1.chunk.ordinal
      }
    }
  }
}

public struct KnowledgeImportOptions: Hashable, Sendable {
  public var performsPDFOCR: Bool
  public var maximumPDFOCRPageCount: Int

  public init(
    performsPDFOCR: Bool = true,
    maximumPDFOCRPageCount: Int = 200
  ) {
    self.performsPDFOCR = performsPDFOCR
    self.maximumPDFOCRPageCount = min(max(maximumPDFOCRPageCount, 1), 500)
  }
}

public enum KnowledgeImportDestination: Hashable, Sendable {
  case preserveExisting
  case unfiled
  case folder(UUID)
}

public struct KnowledgeBrowserCapture: Codable, Hashable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var sourceURL: URL
  public var title: String
  public var authors: [String]
  public var language: String?
  public var summary: String
  public var tags: [String]
  public var capturedAt: Date
  public var contentText: String
  public var originalHTML: String?
  public var archiveFormat: String?
  public var archiveData: Data?

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    sourceURL: URL,
    title: String,
    authors: [String] = [],
    language: String? = nil,
    summary: String = "",
    tags: [String] = [],
    capturedAt: Date = Date(),
    contentText: String,
    originalHTML: String? = nil,
    archiveFormat: String? = nil,
    archiveData: Data? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.sourceURL = sourceURL
    self.title = title
    self.authors = authors
    self.language = language
    self.summary = summary
    self.tags = tags
    self.capturedAt = capturedAt
    self.contentText = contentText
    self.originalHTML = originalHTML
    self.archiveFormat = archiveFormat
    self.archiveData = archiveData
  }
}

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
  public var allowsAIUse: Bool
  public var isArchived: Bool
  public var importedAt: Date
  public var updatedAt: Date
  public var currentRevisionID: UUID

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
    allowsAIUse: Bool = true,
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
    self.allowsAIUse = allowsAIUse
    self.isArchived = isArchived
    self.importedAt = importedAt
    self.updatedAt = updatedAt
    self.currentRevisionID = currentRevisionID
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
  public var originalFilenameExtension: String?
  public var originalData: Data?
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
    originalFilenameExtension: String? = nil,
    originalData: Data? = nil,
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
    self.originalFilenameExtension = originalFilenameExtension
    self.originalData = originalData
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

  public init(insertedCount: Int, updatedCount: Int, skippedCount: Int) {
    self.insertedCount = insertedCount
    self.updatedCount = updatedCount
    self.skippedCount = skippedCount
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

public struct KnowledgeBatchExportReport: Hashable, Sendable {
  public var exportedDocumentCount: Int
  public var destinationDirectory: URL

  public init(exportedDocumentCount: Int, destinationDirectory: URL) {
    self.exportedDocumentCount = max(0, exportedDocumentCount)
    self.destinationDirectory = destinationDirectory
  }
}

public enum KnowledgeLibraryError: LocalizedError, Sendable {
  case unsupportedSource(String)
  case noImportableSources(String)
  case unreadableSource(String)
  case emptyContent(String)
  case sourceLimitExceeded(String)
  case invalidWebURL
  case networkFailure(String)
  case database(String)
  case unsupportedDatabaseVersion(found: Int, supported: Int)
  case missingDocument
  case invalidFolderName
  case duplicateFolderName(String)
  case missingFolder
  case invalidBrowserCapture(String)
  case invalidMetadata(String)
  case missingRevision
  case sourceRefreshUnavailable
  case contentRepairUnavailable(String)
  case exportFailure(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedSource(let name): "暂不支持这种资料格式：\(name)"
    case .noImportableSources(let message): "拖放内容中没有可导入的资料：\(message)"
    case .unreadableSource(let path): "无法读取资料来源：\(path)"
    case .emptyContent(let name): "没有从资料中提取到可检索文本：\(name)"
    case .sourceLimitExceeded(let message): message
    case .invalidWebURL: "请输入有效的 HTTPS 网页地址。"
    case .networkFailure(let message): "网页读取失败：\(message)"
    case .database(let message): "资料库数据库错误：\(message)"
    case .unsupportedDatabaseVersion(let found, let supported):
      "此资料库由更新版本的软件创建（数据库版本 \(found)），当前版本最高支持 \(supported)。为避免损坏，已拒绝打开。"
    case .missingDocument: "找不到这条资料。"
    case .invalidFolderName: "文件夹名称不能为空，且最多使用 80 个字符。"
    case .duplicateFolderName(let name): "已经存在名为“\(name)”的资料文件夹。"
    case .missingFolder: "找不到这个资料文件夹。"
    case .invalidBrowserCapture(let message): "浏览器页面保存失败：\(message)"
    case .invalidMetadata(let message): "资料元数据无效：\(message)"
    case .missingRevision: "找不到这条资料修订。"
    case .sourceRefreshUnavailable: "这条资料没有可重新读取的来源。"
    case .contentRepairUnavailable(let message): "无法在本机修复这条资料：\(message)"
    case .exportFailure(let message): "资料导出失败：\(message)"
    }
  }
}
