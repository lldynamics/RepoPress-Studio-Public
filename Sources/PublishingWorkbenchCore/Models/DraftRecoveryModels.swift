import Foundation

public struct DraftRecoveryRecord: Codable, Hashable, Identifiable, Sendable {
  public let draftID: UUID
  public let siteProfileID: UUID
  public let scope: ArticleDraftScope
  public let title: String
  public let slug: String
  public let tags: [String]
  public let categories: [String]
  public let authors: [String]
  public let draft: Bool
  public let visibility: ArticleVisibility
  public let summary: String
  public let repositoryPath: String?
  public let baselineBodyMarkdown: String
  public let recoveredBodyMarkdown: String
  public let capturedAt: Date

  public var id: UUID { draftID }

  public init(
    draftID: UUID,
    siteProfileID: UUID,
    scope: ArticleDraftScope,
    title: String,
    slug: String,
    tags: [String],
    categories: [String],
    authors: [String],
    draft: Bool,
    visibility: ArticleVisibility,
    summary: String,
    repositoryPath: String?,
    baselineBodyMarkdown: String,
    recoveredBodyMarkdown: String,
    capturedAt: Date = Date()
  ) {
    self.draftID = draftID
    self.siteProfileID = siteProfileID
    self.scope = scope
    self.title = title
    self.slug = slug
    self.tags = tags
    self.categories = categories
    self.authors = authors
    self.draft = draft
    self.visibility = visibility
    self.summary = summary
    self.repositoryPath = repositoryPath
    self.baselineBodyMarkdown = baselineBodyMarkdown
    self.recoveredBodyMarkdown = recoveredBodyMarkdown
    self.capturedAt = capturedAt
  }

  public init(draft: ArticleDraft, recoveredBodyMarkdown: String, capturedAt: Date = Date()) {
    self.init(
      draftID: draft.id,
      siteProfileID: draft.siteProfileID,
      scope: draft.scope,
      title: draft.title,
      slug: draft.slug,
      tags: draft.tags,
      categories: draft.categories,
      authors: draft.authors,
      draft: draft.draft,
      visibility: draft.visibility,
      summary: draft.summary,
      repositoryPath: draft.repositoryPath,
      baselineBodyMarkdown: draft.bodyMarkdown,
      recoveredBodyMarkdown: recoveredBodyMarkdown,
      capturedAt: capturedAt
    )
  }

  public func makeDraft(id: UUID = UUID()) -> ArticleDraft {
    ArticleDraft(
      id: id,
      siteProfileID: siteProfileID,
      scope: scope,
      title: title,
      slug: slug,
      tags: tags,
      categories: categories,
      authors: authors,
      draft: draft,
      visibility: visibility,
      summary: summary,
      bodyMarkdown: recoveredBodyMarkdown,
      repositoryPath: repositoryPath
    )
  }
}

public struct DraftRecoveryJournal: Sendable {
  public static let maximumRecordCount = 16
  public static let maximumJournalByteCount = 16 * 1_024 * 1_024

  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> [DraftRecoveryRecord] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let data = try BoundedFileReader.data(
      at: fileURL,
      maximumByteCount: Self.maximumJournalByteCount
    )
    let decoded = try JSONDecoder.draftRecovery.decode([DraftRecoveryRecord].self, from: data)
      .sorted { $0.capturedAt > $1.capturedAt }
    var seenDraftIDs = Set<UUID>()
    return Array(decoded.filter { seenDraftIDs.insert($0.draftID).inserted }
      .prefix(Self.maximumRecordCount))
  }

  /// Moves an unreadable journal aside before new recovery writes begin, so a
  /// malformed file remains available for manual inspection instead of being
  /// silently replaced.
  public func quarantineUnreadableFile() throws -> URL? {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
    let quarantineURL = fileURL.deletingPathExtension()
      .appendingPathExtension("unreadable-\(UUID().uuidString.lowercased()).json")
    try fileManager.moveItem(at: fileURL, to: quarantineURL)
    return quarantineURL
  }

  public func save(_ records: [DraftRecoveryRecord]) throws {
    let normalized = Array(
      records
        .filter { !$0.recoveredBodyMarkdown.isEmpty || !$0.baselineBodyMarkdown.isEmpty }
        .sorted { $0.capturedAt > $1.capturedAt }
        .prefix(Self.maximumRecordCount)
    )
    let fileManager = FileManager.default
    if normalized.isEmpty {
      if fileManager.fileExists(atPath: fileURL.path) {
        try fileManager.removeItem(at: fileURL)
      }
      return
    }

    let data = try JSONEncoder.draftRecovery.encode(normalized)
    guard data.count <= Self.maximumJournalByteCount else {
      throw DraftRecoveryJournalError.exceedsSizeLimit
    }
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: [.atomic])
  }
}

/// Serializes journal commits and prevents a cancelled, older background save
/// from overwriting a newer synchronous flush.
final class DraftRecoveryJournalWriteCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private var latestGeneration: UInt64 = 0

  @discardableResult
  func save(
    _ records: [DraftRecoveryRecord],
    to journal: DraftRecoveryJournal,
    generation: UInt64
  ) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard generation >= latestGeneration else { return false }
    // Claim the generation before I/O. If the newest write fails, an older
    // queued write must still not restore stale recovery contents afterward.
    latestGeneration = generation
    try journal.save(records)
    return true
  }
}

public enum DraftRecoveryJournalError: LocalizedError, Equatable, Sendable {
  case exceedsSizeLimit

  public var errorDescription: String? {
    switch self {
    case .exceedsSizeLimit:
      return CoreL10n.text("未保存草稿恢复日志超过大小限制。")
    }
  }
}

extension JSONEncoder {
  fileprivate static var draftRecovery: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var draftRecovery: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
