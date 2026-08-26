import Foundation

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

public enum KnowledgeBrowserCaptureMode: String, Codable, Hashable, Sendable {
  case cleanedArticle = "cleaned-article"
  case fullPage = "full-page"
  case selection = "selection"
  case linkOnly = "link-only"
}

public struct KnowledgeBrowserConnectionTokenLease: Hashable, Sendable {
  public static let defaultLifetime: TimeInterval = 30 * 24 * 60 * 60

  public var token: String
  public var expiresAt: Date

  public init(
    storedToken: String?,
    storedExpiresAt: Date?,
    now: Date,
    lifetime: TimeInterval = Self.defaultLifetime,
    generateToken: () -> String
  ) {
    if let storedToken, storedToken.count >= 32,
       storedExpiresAt.map({ $0 > now }) ?? true {
      token = storedToken
      expiresAt = storedExpiresAt ?? now.addingTimeInterval(lifetime)
    } else {
      token = generateToken()
      expiresAt = now.addingTimeInterval(lifetime)
    }
  }

  public func isExpired(at date: Date) -> Bool {
    date >= expiresAt
  }
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
  public var archiveEmbeddedResourceCount: Int?
  public var archiveMissingResourceCount: Int?
  public var archiveWasTruncated: Bool?
  public var captureMode: KnowledgeBrowserCaptureMode?
  public var allowsLocalSemanticIndex: Bool?
  public var allowsRemoteAIUse: Bool?

  @available(*, deprecated, message: "请使用 allowsLocalSemanticIndex 或 allowsRemoteAIUse")
  public var allowsAIUse: Bool? {
    get { allowsRemoteAIUse }
    set { allowsRemoteAIUse = newValue }
  }

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
    archiveData: Data? = nil,
    archiveEmbeddedResourceCount: Int? = nil,
    archiveMissingResourceCount: Int? = nil,
    archiveWasTruncated: Bool? = nil,
    captureMode: KnowledgeBrowserCaptureMode? = nil,
    allowsLocalSemanticIndex: Bool? = nil,
    allowsRemoteAIUse: Bool? = nil,
    allowsAIUse: Bool? = nil
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
    self.archiveEmbeddedResourceCount = archiveEmbeddedResourceCount
    self.archiveMissingResourceCount = archiveMissingResourceCount
    self.archiveWasTruncated = archiveWasTruncated
    self.captureMode = captureMode
    self.allowsLocalSemanticIndex = allowsLocalSemanticIndex
    self.allowsRemoteAIUse = allowsRemoteAIUse ?? allowsAIUse
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case sourceURL
    case title
    case authors
    case language
    case summary
    case tags
    case capturedAt
    case contentText
    case originalHTML
    case archiveFormat
    case archiveData
    case archiveEmbeddedResourceCount
    case archiveMissingResourceCount
    case archiveWasTruncated
    case captureMode
    case allowsLocalSemanticIndex
    case allowsRemoteAIUse
    case allowsAIUse
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    sourceURL = try container.decode(URL.self, forKey: .sourceURL)
    title = try container.decode(String.self, forKey: .title)
    authors = try container.decode([String].self, forKey: .authors)
    language = try container.decodeIfPresent(String.self, forKey: .language)
    summary = try container.decode(String.self, forKey: .summary)
    tags = try container.decode([String].self, forKey: .tags)
    capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    contentText = try container.decode(String.self, forKey: .contentText)
    originalHTML = try container.decodeIfPresent(String.self, forKey: .originalHTML)
    archiveFormat = try container.decodeIfPresent(String.self, forKey: .archiveFormat)
    archiveData = try container.decodeIfPresent(Data.self, forKey: .archiveData)
    archiveEmbeddedResourceCount = try container.decodeIfPresent(
      Int.self,
      forKey: .archiveEmbeddedResourceCount
    )
    archiveMissingResourceCount = try container.decodeIfPresent(
      Int.self,
      forKey: .archiveMissingResourceCount
    )
    archiveWasTruncated = try container.decodeIfPresent(Bool.self, forKey: .archiveWasTruncated)
    captureMode = try container.decodeIfPresent(KnowledgeBrowserCaptureMode.self, forKey: .captureMode)
    let legacyPermission = try container.decodeIfPresent(Bool.self, forKey: .allowsAIUse)
    allowsLocalSemanticIndex = try container.decodeIfPresent(
      Bool.self,
      forKey: .allowsLocalSemanticIndex
    ) ?? legacyPermission
    allowsRemoteAIUse = try container.decodeIfPresent(Bool.self, forKey: .allowsRemoteAIUse)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(sourceURL, forKey: .sourceURL)
    try container.encode(title, forKey: .title)
    try container.encode(authors, forKey: .authors)
    try container.encodeIfPresent(language, forKey: .language)
    try container.encode(summary, forKey: .summary)
    try container.encode(tags, forKey: .tags)
    try container.encode(capturedAt, forKey: .capturedAt)
    try container.encode(contentText, forKey: .contentText)
    try container.encodeIfPresent(originalHTML, forKey: .originalHTML)
    try container.encodeIfPresent(archiveFormat, forKey: .archiveFormat)
    try container.encodeIfPresent(archiveData, forKey: .archiveData)
    try container.encodeIfPresent(archiveEmbeddedResourceCount, forKey: .archiveEmbeddedResourceCount)
    try container.encodeIfPresent(archiveMissingResourceCount, forKey: .archiveMissingResourceCount)
    try container.encodeIfPresent(archiveWasTruncated, forKey: .archiveWasTruncated)
    try container.encodeIfPresent(captureMode, forKey: .captureMode)
    try container.encodeIfPresent(allowsLocalSemanticIndex, forKey: .allowsLocalSemanticIndex)
    try container.encodeIfPresent(allowsRemoteAIUse, forKey: .allowsRemoteAIUse)
    try container.encode(allowsRemoteAIUse ?? false, forKey: .allowsAIUse)
  }
}

public enum KnowledgeBrowserDuplicateResolution: String, Codable, Hashable, Sendable {
  case saveNewVersion = "save-new-version"
  case moveOnly = "move-only"
  case keepCopy = "keep-copy"
}

public enum KnowledgeBrowserImportAction: String, Codable, Hashable, Sendable {
  case inserted
  case updated
  case existing
  case moved
  case copied
}

public struct KnowledgeBrowserDuplicateConflict: Hashable, Sendable {
  public var document: KnowledgeDocument
  public var folder: KnowledgeFolder?
  public var incomingHasChanges: Bool

  public init(
    document: KnowledgeDocument,
    folder: KnowledgeFolder?,
    incomingHasChanges: Bool
  ) {
    self.document = document
    self.folder = folder
    self.incomingHasChanges = incomingHasChanges
  }
}

public enum KnowledgeBrowserImportOutcome: Hashable, Sendable {
  case requiresDuplicateResolution(KnowledgeBrowserDuplicateConflict)
  case saved(result: KnowledgeImportResult, action: KnowledgeBrowserImportAction)
}

public struct KnowledgeBrowserReceiptFolder: Codable, Hashable, Sendable {
  public var id: UUID
  public var name: String

  public init(id: UUID, name: String) {
    self.id = id
    self.name = name
  }
}

public struct KnowledgeBrowserImportReceipt: Codable, Hashable, Sendable {
  public var operationID: UUID
  public var insertedCount: Int
  public var updatedCount: Int
  public var skippedCount: Int
  public var action: String
  public var documentID: UUID
  public var title: String
  public var sourceURL: URL?
  public var folder: KnowledgeBrowserReceiptFolder?
  public var fileSizeBytes: Int64
  public var archiveType: String
  public var indexStatus: String
  public var allowsLocalSemanticIndex: Bool
  public var allowsRemoteAIUse: Bool
  public var savedAt: Date
  public var replayed: Bool

  @available(*, deprecated, message: "请使用 allowsLocalSemanticIndex 或 allowsRemoteAIUse")
  public var allowsAIUse: Bool {
    get { allowsRemoteAIUse }
    set { allowsRemoteAIUse = newValue }
  }

  public init(
    operationID: UUID,
    insertedCount: Int,
    updatedCount: Int,
    skippedCount: Int,
    action: String,
    documentID: UUID,
    title: String,
    sourceURL: URL? = nil,
    folder: KnowledgeBrowserReceiptFolder?,
    fileSizeBytes: Int64,
    archiveType: String,
    indexStatus: String,
    allowsLocalSemanticIndex: Bool = true,
    allowsRemoteAIUse: Bool = false,
    allowsAIUse: Bool? = nil,
    savedAt: Date,
    replayed: Bool = false
  ) {
    self.operationID = operationID
    self.insertedCount = insertedCount
    self.updatedCount = updatedCount
    self.skippedCount = skippedCount
    self.action = action
    self.documentID = documentID
    self.title = title
    self.sourceURL = sourceURL
    self.folder = folder
    self.fileSizeBytes = fileSizeBytes
    self.archiveType = archiveType
    self.indexStatus = indexStatus
    self.allowsLocalSemanticIndex = allowsLocalSemanticIndex
    self.allowsRemoteAIUse = allowsAIUse ?? allowsRemoteAIUse
    self.savedAt = savedAt
    self.replayed = replayed
  }

  private enum CodingKeys: String, CodingKey {
    case operationID
    case insertedCount
    case updatedCount
    case skippedCount
    case action
    case documentID
    case title
    case sourceURL
    case folder
    case fileSizeBytes
    case archiveType
    case indexStatus
    case allowsLocalSemanticIndex
    case allowsRemoteAIUse
    case allowsAIUse
    case savedAt
    case replayed
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    operationID = try container.decode(UUID.self, forKey: .operationID)
    insertedCount = try container.decode(Int.self, forKey: .insertedCount)
    updatedCount = try container.decode(Int.self, forKey: .updatedCount)
    skippedCount = try container.decode(Int.self, forKey: .skippedCount)
    action = try container.decode(String.self, forKey: .action)
    documentID = try container.decode(UUID.self, forKey: .documentID)
    title = try container.decode(String.self, forKey: .title)
    sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
    folder = try container.decodeIfPresent(KnowledgeBrowserReceiptFolder.self, forKey: .folder)
    fileSizeBytes = try container.decode(Int64.self, forKey: .fileSizeBytes)
    archiveType = try container.decode(String.self, forKey: .archiveType)
    indexStatus = try container.decode(String.self, forKey: .indexStatus)
    let legacyPermission = try container.decodeIfPresent(Bool.self, forKey: .allowsAIUse)
    allowsLocalSemanticIndex = try container.decodeIfPresent(
      Bool.self,
      forKey: .allowsLocalSemanticIndex
    ) ?? true
    allowsRemoteAIUse = try container.decodeIfPresent(Bool.self, forKey: .allowsRemoteAIUse)
      ?? legacyPermission
      ?? false
    savedAt = try container.decode(Date.self, forKey: .savedAt)
    replayed = try container.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(operationID, forKey: .operationID)
    try container.encode(insertedCount, forKey: .insertedCount)
    try container.encode(updatedCount, forKey: .updatedCount)
    try container.encode(skippedCount, forKey: .skippedCount)
    try container.encode(action, forKey: .action)
    try container.encode(documentID, forKey: .documentID)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
    try container.encodeIfPresent(folder, forKey: .folder)
    try container.encode(fileSizeBytes, forKey: .fileSizeBytes)
    try container.encode(archiveType, forKey: .archiveType)
    try container.encode(indexStatus, forKey: .indexStatus)
    try container.encode(allowsLocalSemanticIndex, forKey: .allowsLocalSemanticIndex)
    try container.encode(allowsRemoteAIUse, forKey: .allowsRemoteAIUse)
    try container.encode(allowsRemoteAIUse, forKey: .allowsAIUse)
    try container.encode(savedAt, forKey: .savedAt)
    try container.encode(replayed, forKey: .replayed)
  }
}

public struct KnowledgeBrowserImportOperationRecord: Codable, Hashable, Sendable {
  public var operationID: UUID
  public var requestFingerprint: String
  public var receipt: KnowledgeBrowserImportReceipt
  public var completedAt: Date

  public init(
    operationID: UUID,
    requestFingerprint: String,
    receipt: KnowledgeBrowserImportReceipt,
    completedAt: Date
  ) {
    self.operationID = operationID
    self.requestFingerprint = requestFingerprint
    self.receipt = receipt
    self.completedAt = completedAt
  }
}

public enum KnowledgeBrowserImportOperationLookup: Hashable, Sendable {
  case miss
  case replay(KnowledgeBrowserImportReceipt)
  case conflictingRequest
  case missingDocument
}

public struct KnowledgeBrowserImportOperationLedger: Sendable {
  public static let defaultMaximumRecordCount = 256
  public static let defaultRetentionInterval: TimeInterval = 30 * 24 * 60 * 60

  private var recordsByID: [UUID: KnowledgeBrowserImportOperationRecord]
  private let maximumRecordCount: Int
  private let retentionInterval: TimeInterval

  public init(
    records: [KnowledgeBrowserImportOperationRecord] = [],
    maximumRecordCount: Int = Self.defaultMaximumRecordCount,
    retentionInterval: TimeInterval = Self.defaultRetentionInterval
  ) {
    self.maximumRecordCount = max(1, maximumRecordCount)
    self.retentionInterval = max(60, retentionInterval)
    recordsByID = [:]
    for record in records.sorted(by: { $0.completedAt < $1.completedAt }) {
      recordsByID[record.operationID] = record
    }
  }

  public var records: [KnowledgeBrowserImportOperationRecord] {
    recordsByID.values.sorted {
      if $0.completedAt != $1.completedAt { return $0.completedAt < $1.completedAt }
      return $0.operationID.uuidString < $1.operationID.uuidString
    }
  }

  public mutating func lookup(
    operationID: UUID,
    requestFingerprint: String,
    now: Date,
    documentExists: (UUID) -> Bool
  ) -> KnowledgeBrowserImportOperationLookup {
    prune(at: now)
    guard let record = recordsByID[operationID] else { return .miss }
    guard record.requestFingerprint == requestFingerprint else {
      return .conflictingRequest
    }
    guard documentExists(record.receipt.documentID) else {
      recordsByID.removeValue(forKey: operationID)
      return .missingDocument
    }
    var receipt = record.receipt
    receipt.replayed = true
    return .replay(receipt)
  }

  public mutating func record(
    operationID: UUID,
    requestFingerprint: String,
    receipt: KnowledgeBrowserImportReceipt,
    completedAt: Date
  ) {
    var storedReceipt = receipt
    storedReceipt.operationID = operationID
    storedReceipt.replayed = false
    recordsByID[operationID] = KnowledgeBrowserImportOperationRecord(
      operationID: operationID,
      requestFingerprint: requestFingerprint,
      receipt: storedReceipt,
      completedAt: completedAt
    )
    prune(at: completedAt)
  }

  public mutating func prune(at now: Date) {
    recordsByID = recordsByID.filter { _, record in
      now.timeIntervalSince(record.completedAt) <= retentionInterval
    }
    guard recordsByID.count > maximumRecordCount else { return }
    let retainedIDs = Set(recordsByID.values
      .sorted {
        if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
        return $0.operationID.uuidString > $1.operationID.uuidString
      }
      .prefix(maximumRecordCount)
      .map(\.operationID))
    recordsByID = recordsByID.filter { retainedIDs.contains($0.key) }
  }
}

public enum KnowledgeBrowserFolderSuggestionReason: String, Codable, Hashable, Sendable {
  case sourceDomain = "source-domain"
  case author
  case tag
}

public struct KnowledgeBrowserFolderSuggestion: Hashable, Sendable {
  public var folder: KnowledgeFolder
  public var score: Double
  public var reasons: [KnowledgeBrowserFolderSuggestionReason]

  public init(
    folder: KnowledgeFolder,
    score: Double,
    reasons: [KnowledgeBrowserFolderSuggestionReason]
  ) {
    self.folder = folder
    self.score = score
    self.reasons = reasons
  }
}

public struct KnowledgeBrowserOrganizationSuggestions: Hashable, Sendable {
  public var folders: [KnowledgeBrowserFolderSuggestion]
  public var tags: [String]

  public init(folders: [KnowledgeBrowserFolderSuggestion], tags: [String]) {
    self.folders = folders
    self.tags = tags
  }
}
