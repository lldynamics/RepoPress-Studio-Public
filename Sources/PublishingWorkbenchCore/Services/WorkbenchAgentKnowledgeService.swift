import Foundation

/// Errors exposed by the read-only knowledge tools.
///
/// The cases intentionally do not carry the underlying library error or a
/// filesystem path.  A tool response may be sent to a remote model, so a
/// local path must not escape through an error string.
public enum WorkbenchAgentKnowledgeError: LocalizedError, Equatable, Sendable {
  case emptyQuery
  case missingDocument
  case notAllowed
  case cancelled
  case unavailable

  public var errorDescription: String? {
    switch self {
    case .emptyQuery:
      return "资料库搜索词不能为空。"
    case .missingDocument:
      return "找不到这条资料。"
    case .notAllowed:
      return "这条资料未允许远程 AI 使用。"
    case .cancelled:
      return "资料库操作已取消。"
    case .unavailable:
      return "资料库暂时不可用。"
    }
  }
}

/// A bounded, JSON-friendly projection of a knowledge-library search hit.
/// It deliberately omits the full document and chunk models, which can carry
/// more metadata and text than an Agent tool should return.
public struct WorkbenchAgentKnowledgeSearchHit:
  Codable, Equatable, Hashable, Identifiable, Sendable
{
  public var id: String { "\(documentID.uuidString):\(chunkID.uuidString)" }

  public let documentID: UUID
  public let chunkID: UUID
  public let title: String
  public let locator: String?
  public let excerpt: String
  public let signals: [String]
  public let sourceURL: URL?

  public init(
    documentID: UUID,
    chunkID: UUID,
    title: String,
    locator: String?,
    excerpt: String,
    signals: [String],
    sourceURL: URL?
  ) {
    self.documentID = documentID
    self.chunkID = chunkID
    self.title = title
    self.locator = locator
    self.excerpt = excerpt
    self.signals = signals
    self.sourceURL = sourceURL
  }
}

/// A bounded read of the current normalized text for an allowed document.
public struct WorkbenchAgentKnowledgeReadResult:
  Codable, Equatable, Hashable, Sendable
{
  public let documentID: UUID
  public let title: String
  public let text: String
  public let isTruncated: Bool

  /// Alias that reads naturally at call sites while keeping the serialized
  /// contract as the single `isTruncated` field.
  public var wasTruncated: Bool { isTruncated }

  public init(
    documentID: UUID,
    title: String,
    text: String,
    isTruncated: Bool
  ) {
    self.documentID = documentID
    self.title = title
    self.text = text
    self.isTruncated = isTruncated
  }
}

/// Local-only Agent access to the knowledge library.
///
/// Search and read never perform network requests and only project documents
/// that are explicitly marked `allowsRemoteAIUse`.  The underlying
/// `KnowledgeLibraryService` retains ownership of storage and cancellation
/// behavior; this type only adds the smaller, safer tool boundary.
public struct WorkbenchAgentKnowledgeService: Sendable {
  public static let maximumQueryLength = 512
  public static let maximumSearchLimit = 10
  public static let maximumTitleLength = 300
  public static let maximumLocatorLength = 240
  public static let maximumExcerptLength = 640
  public static let maximumSourceURLLength = 2_048
  public static let maximumSearchOutputCharacters = 8_192
  public static let maximumReadCharacters = 24_000

  private let library: KnowledgeLibraryService

  public init(library: KnowledgeLibraryService = KnowledgeLibraryService()) {
    self.library = library
  }

  /// Searches the explicitly remote-AI-allowed portion of the local library.
  /// Query and output sizes are bounded before returning to the Agent.
  public func search(
    query: String,
    limit: Int = Self.maximumSearchLimit
  ) async throws -> [WorkbenchAgentKnowledgeSearchHit] {
    do {
      try checkCancellation()
      let normalizedQuery = try normalizedQuery(query)
      let boundedLimit = min(Self.maximumSearchLimit, max(1, limit))

      // Use the library's lexical SQLite read path directly.  The public
      // hybrid search API may backfill semantic embeddings on first use, which
      // would turn an Agent read into a storage mutation.  This path remains
      // local/read-only while still reusing KnowledgeLibraryService's database
      // and cancellation-aware query implementation.
      let results = try await readOnlySearch(
        query: normalizedQuery,
        limit: boundedLimit
      )
      try checkCancellation()
      let currentlyAllowedResults = try results.filter { result in
        guard let document = try library.document(id: result.document.id) else {
          return false
        }
        return !document.isArchived && document.allowsRemoteAIUse
      }
      let hits = boundedSearchHits(
        currentlyAllowedResults,
        query: normalizedQuery,
        limit: boundedLimit
      )
      try checkCancellation()
      return hits
    } catch let error as WorkbenchAgentKnowledgeError {
      throw error
    } catch is CancellationError {
      throw WorkbenchAgentKnowledgeError.cancelled
    } catch {
      if Task.isCancelled {
        throw WorkbenchAgentKnowledgeError.cancelled
      }
      throw WorkbenchAgentKnowledgeError.unavailable
    }
  }

  /// Reads only the current normalized text of a non-archived, explicitly
  /// remote-AI-allowed document.  It never reads the original blob or source
  /// URL and never exposes a filesystem path.
  public func read(documentID: UUID) async throws -> WorkbenchAgentKnowledgeReadResult {
    do {
      try checkCancellation()
      guard let document = try library.document(id: documentID) else {
        throw WorkbenchAgentKnowledgeError.missingDocument
      }
      guard !document.isArchived, document.allowsRemoteAIUse else {
        throw WorkbenchAgentKnowledgeError.notAllowed
      }
      try checkCancellation()

      let normalizedText = try await readOnlyNormalizedText(documentID: documentID)
      try checkCancellation()
      guard let currentDocument = try library.document(id: documentID) else {
        throw WorkbenchAgentKnowledgeError.missingDocument
      }
      guard !currentDocument.isArchived, currentDocument.allowsRemoteAIUse else {
        throw WorkbenchAgentKnowledgeError.notAllowed
      }
      let text = String(normalizedText.prefix(Self.maximumReadCharacters))
      return WorkbenchAgentKnowledgeReadResult(
        documentID: documentID,
        title: bounded(currentDocument.title, maximumLength: Self.maximumTitleLength),
        text: text,
        isTruncated: normalizedText.count > Self.maximumReadCharacters
      )
    } catch let error as WorkbenchAgentKnowledgeError {
      throw error
    } catch is CancellationError {
      throw WorkbenchAgentKnowledgeError.cancelled
    } catch {
      if Task.isCancelled {
        throw WorkbenchAgentKnowledgeError.cancelled
      }
      // Do not forward KnowledgeLibraryError.localizedDescription: it may
      // contain a local source or storage path.
      throw WorkbenchAgentKnowledgeError.unavailable
    }
  }

  private func normalizedQuery(_ query: String) throws -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let bounded = String(trimmed.prefix(Self.maximumQueryLength))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !bounded.isEmpty else {
      throw WorkbenchAgentKnowledgeError.emptyQuery
    }
    return bounded
  }

  private func readOnlySearch(
    query: String,
    limit: Int
  ) async throws -> [KnowledgeSearchResult] {
    let library = self.library
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let database = try library.database()
      try Task.checkCancellation()
      return try database.search(
        query: query,
        limit: limit,
        onlyRemoteAIAllowed: true
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func readOnlyNormalizedText(documentID: UUID) async throws -> String {
    let library = self.library
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let text = try library.normalizedText(documentID: documentID)
      try Task.checkCancellation()
      return text
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func boundedSearchHits(
    _ results: [KnowledgeSearchResult],
    query: String,
    limit: Int
  ) -> [WorkbenchAgentKnowledgeSearchHit] {
    let presentationService = KnowledgeSearchPresentationService()
    var seenIDs = Set<String>()
    var output: [WorkbenchAgentKnowledgeSearchHit] = []
    var totalCharacters = 0

    // Fused semantic and lexical rankings can return the same chunk more than
    // once. Sorting the projection by both IDs gives the Agent stable output
    // even when the storage query's insertion order changes.
    let sortedResults = results.sorted {
      if $0.document.id != $1.document.id {
        return $0.document.id.uuidString < $1.document.id.uuidString
      }
      if $0.chunk.id != $1.chunk.id {
        return $0.chunk.id.uuidString < $1.chunk.id.uuidString
      }
      return $0.score > $1.score
    }

    for result in sortedResults {
      guard !Task.isCancelled, output.count < limit else { break }
      let identifier = "\(result.document.id.uuidString):\(result.chunk.id.uuidString)"
      guard seenIDs.insert(identifier).inserted else { continue }

      let presentation = presentationService.presentation(
        for: result,
        query: query,
        maximumSnippetCharacters: Self.maximumExcerptLength
      )
      let title = bounded(result.document.title, maximumLength: Self.maximumTitleLength)
      let locator =
        result.chunk.locator?.nilIfEmpty.map {
          bounded($0, maximumLength: Self.maximumLocatorLength)
        }
        ?? result.chunk.headingPath?.nilIfEmpty.map {
          bounded($0, maximumLength: Self.maximumLocatorLength)
        }
      let excerpt = bounded(presentation.snippet, maximumLength: Self.maximumExcerptLength)
      let signals = orderedSignals(result.signals)
      let sourceURL = safeSourceURL(result.document.sourceURL)
      let hit = WorkbenchAgentKnowledgeSearchHit(
        documentID: result.document.id,
        chunkID: result.chunk.id,
        title: title,
        locator: locator,
        excerpt: excerpt,
        signals: signals,
        sourceURL: sourceURL
      )
      let cost =
        result.document.id.uuidString.count
        + result.chunk.id.uuidString.count
        + title.count
        + (locator?.count ?? 0)
        + excerpt.count
        + signals.reduce(0) { $0 + $1.count }
        + (sourceURL?.absoluteString.count ?? 0)
      guard totalCharacters + cost <= Self.maximumSearchOutputCharacters else { break }

      output.append(hit)
      totalCharacters += cost
    }
    return output
  }

  private func orderedSignals(_ signals: Set<KnowledgeRetrievalSignal>) -> [String] {
    [.title, .fullText, .semantic]
      .filter(signals.contains)
      .map(\.rawValue)
  }

  private func safeSourceURL(_ url: URL?) -> URL? {
    guard let url,
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      url.absoluteString.count <= Self.maximumSourceURLLength
    else {
      return nil
    }
    return url
  }

  private func bounded(_ value: String, maximumLength: Int) -> String {
    String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumLength))
  }

  private func checkCancellation() throws {
    guard !Task.isCancelled else {
      throw WorkbenchAgentKnowledgeError.cancelled
    }
  }
}
