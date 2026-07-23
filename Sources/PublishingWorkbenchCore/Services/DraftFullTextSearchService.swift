import Foundation
import os

private let logger = Logger(subsystem: "com.repopress", category: "DraftFullTextSavedQueryService")

public enum DraftFullTextSearchField: String, CaseIterable, Hashable, Sendable {
  case title
  case summary
  case body
  case slug
  case tags
  case categories
  case authors
  case repositoryPath
}

public struct DraftFullTextSearchHitID: Hashable, Sendable {
  public var draftID: UUID
  public var field: DraftFullTextSearchField
  public var location: Int

  public init(draftID: UUID, field: DraftFullTextSearchField, location: Int) {
    self.draftID = draftID
    self.field = field
    self.location = location
  }
}

public struct DraftFullTextSearchHit: Identifiable, Equatable, Sendable {
  public var id: DraftFullTextSearchHitID
  public var draftID: UUID
  public var siteProfileID: UUID
  public var draftTitle: String
  public var field: DraftFullTextSearchField
  public var sourceRange: NSRange
  public var snippetPrefix: String
  public var matchedText: String
  public var snippetSuffix: String
  public var updatedAt: Date
  public var score: Int

  public init(
    draftID: UUID,
    siteProfileID: UUID,
    draftTitle: String,
    field: DraftFullTextSearchField,
    sourceRange: NSRange,
    snippetPrefix: String,
    matchedText: String,
    snippetSuffix: String,
    updatedAt: Date,
    score: Int
  ) {
    id = DraftFullTextSearchHitID(
      draftID: draftID,
      field: field,
      location: sourceRange.location
    )
    self.draftID = draftID
    self.siteProfileID = siteProfileID
    self.draftTitle = draftTitle
    self.field = field
    self.sourceRange = sourceRange
    self.snippetPrefix = snippetPrefix
    self.matchedText = matchedText
    self.snippetSuffix = snippetSuffix
    self.updatedAt = updatedAt
    self.score = score
  }

  public var snippet: String {
    snippetPrefix + matchedText + snippetSuffix
  }
}

public struct DraftFullTextSearchQuery: Equatable, Sendable {
  public let textTerms: [String]
  public let titleTerms: [String]
  public let tagTerms: [String]
  public let statuses: Set<DraftStatus>
  public let visibilities: Set<ArticleVisibility>
  public let beforeDate: Date?
  public let afterDate: Date?
  public let invalidFilters: [String]

  public init(_ value: String) {
    var textTerms: [String] = []
    var titleTerms: [String] = []
    var tagTerms: [String] = []
    var statuses = Set<DraftStatus>()
    var visibilities = Set<ArticleVisibility>()
    var beforeDate: Date?
    var afterDate: Date?
    var invalidFilters: [String] = []

    for token in Self.tokens(in: value) {
      guard let separator = token.firstIndex(of: ":") else {
        Self.appendUnique(token, to: &textTerms)
        continue
      }

      let name = token[..<separator].lowercased()
      let rawValue = String(token[token.index(after: separator)...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      switch name {
      case "title":
        if rawValue.isEmpty {
          Self.appendUnique(token, to: &invalidFilters)
        } else {
          Self.appendUnique(rawValue, to: &titleTerms)
        }
      case "tag":
        if rawValue.isEmpty {
          Self.appendUnique(token, to: &invalidFilters)
        } else {
          Self.appendUnique(rawValue, to: &tagTerms)
        }
      case "status":
        if let status = Self.status(for: rawValue) {
          statuses.insert(status)
        } else {
          Self.appendUnique(token, to: &invalidFilters)
        }
      case "before":
        if let date = Self.date(from: rawValue) {
          beforeDate = beforeDate.map { min($0, date) } ?? date
        } else {
          Self.appendUnique(token, to: &invalidFilters)
        }
      case "after":
        if let date = Self.date(from: rawValue) {
          afterDate = afterDate.map { max($0, date) } ?? date
        } else {
          Self.appendUnique(token, to: &invalidFilters)
        }
      case "is":
        if let visibility = Self.visibility(for: rawValue) {
          visibilities.insert(visibility)
        } else {
          Self.appendUnique(token, to: &invalidFilters)
        }
      default:
        Self.appendUnique(token, to: &textTerms)
      }
    }

    self.textTerms = textTerms
    self.titleTerms = titleTerms
    self.tagTerms = tagTerms
    self.statuses = statuses
    self.visibilities = visibilities
    self.beforeDate = beforeDate
    self.afterDate = afterDate
    self.invalidFilters = invalidFilters
  }

  public var hasCriteria: Bool {
    !textTerms.isEmpty
      || !titleTerms.isEmpty
      || !tagTerms.isEmpty
      || !statuses.isEmpty
      || !visibilities.isEmpty
      || beforeDate != nil
      || afterDate != nil
  }

  fileprivate var textPhrase: String {
    textTerms.joined(separator: " ")
  }

  fileprivate func highlightTerms(for field: DraftFullTextSearchField) -> [String] {
    var result = textTerms
    if field == .title {
      titleTerms.forEach { Self.appendUnique($0, to: &result) }
    }
    if field == .tags {
      tagTerms.forEach { Self.appendUnique($0, to: &result) }
    }
    return result
  }

  private static func tokens(in value: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var isInsideQuotes = false

    for character in value.trimmingCharacters(in: .whitespacesAndNewlines) {
      if character == "\"" {
        isInsideQuotes.toggle()
      } else if character.isWhitespace && !isInsideQuotes {
        if !current.isEmpty {
          tokens.append(current)
          current = ""
        }
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty {
      tokens.append(current)
    }
    return tokens
  }

  private static func appendUnique(_ value: String, to values: inout [String]) {
    guard !value.isEmpty,
          !values.contains(where: {
            $0.compare(value, options: comparisonOptions) == .orderedSame
          }) else {
      return
    }
    values.append(value)
  }

  private static func status(for value: String) -> DraftStatus? {
    switch value.lowercased() {
    case "draft", "草稿": .draft
    case "ready", "待发布", "待發佈": .ready
    case "published", "已发布", "已發佈": .published
    case "failed", "失败", "失敗": .failed
    default: nil
    }
  }

  private static func visibility(for value: String) -> ArticleVisibility? {
    switch value.lowercased() {
    case "private", "私密": .private
    case "public", "公开", "公開": .public
    default: nil
    }
  }

  private static func date(from value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    return formatter.date(from: value)
  }

  private static let comparisonOptions: String.CompareOptions = [
    .caseInsensitive,
    .diacriticInsensitive,
    .widthInsensitive,
  ]
}

public struct DraftFullTextSavedQuery: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var query: String
  public var searchesAllSites: Bool
  public var savedAt: Date

  public init(
    id: UUID = UUID(),
    query: String,
    searchesAllSites: Bool,
    savedAt: Date = Date()
  ) {
    self.id = id
    self.query = query
    self.searchesAllSites = searchesAllSites
    self.savedAt = savedAt
  }
}

public enum DraftFullTextSavedQueryService {
  public static let maximumCount = 20

  public static func saving(
    query: String,
    searchesAllSites: Bool,
    in existing: [DraftFullTextSavedQuery],
    id: UUID = UUID(),
    savedAt: Date = Date()
  ) -> [DraftFullTextSavedQuery] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else { return existing }
    var result = existing.filter {
      $0.searchesAllSites != searchesAllSites
        || $0.query.compare(
          normalizedQuery,
          options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        ) != .orderedSame
    }
    result.insert(
      DraftFullTextSavedQuery(
        id: id,
        query: normalizedQuery,
        searchesAllSites: searchesAllSites,
        savedAt: savedAt
      ),
      at: 0
    )
    return Array(result.prefix(maximumCount))
  }

  public static func removing(
    id: UUID,
    from existing: [DraftFullTextSavedQuery]
  ) -> [DraftFullTextSavedQuery] {
    existing.filter { $0.id != id }
  }

  public static func encode(_ queries: [DraftFullTextSavedQuery]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(Array(queries.prefix(maximumCount)))
    } catch {
      logger.warning("无法序列化查询历史: \(error.localizedDescription, privacy: .public)")
      return ""
    }
    return String(data: data, encoding: .utf8) ?? ""
  }

  public static func decode(_ value: String) -> [DraftFullTextSavedQuery] {
    guard let data = value.data(using: .utf8) else { return [] }
    let decoded: [DraftFullTextSavedQuery]
    do {
      decoded = try JSONDecoder().decode([DraftFullTextSavedQuery].self, from: data)
    } catch {
      logger.warning("无法反序列化查询历史: \(error.localizedDescription, privacy: .public)")
      return []
    }
    return Array(decoded.filter { !$0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .prefix(maximumCount))
  }
}

public struct DraftFullTextSearchService: Sendable {
  public init() {}

  public func search(
    query: String,
    drafts: [ArticleDraft],
    limit: Int = 120,
    matchesPerDraft: Int = 5
  ) -> [DraftFullTextSearchHit] {
    let parsedQuery = parse(query: query)
    guard parsedQuery.hasCriteria, limit > 0, matchesPerDraft > 0 else {
      return []
    }

    var hits: [DraftFullTextSearchHit] = []
    for draft in drafts {
      guard !Task.isCancelled else { return [] }
      guard matchesFilters(parsedQuery, draft: draft) else { continue }
      let sources = searchSources(for: draft)
      guard parsedQuery.textTerms.allSatisfy({ term in
        sources.contains { contains(term, in: $0.value) }
      }) else {
        continue
      }

      var draftHits = sources.flatMap { source in
        matches(
          in: source,
          query: parsedQuery,
          draft: draft
        )
      }
      if draftHits.isEmpty,
         parsedQuery.textTerms.isEmpty,
         let representativeHit = representativeHit(for: draft, sources: sources) {
        draftHits = [representativeHit]
      }
      draftHits.sort(by: hitSort)
      hits.append(contentsOf: draftHits.prefix(matchesPerDraft))
    }

    hits.sort(by: hitSort)
    return Array(hits.prefix(limit))
  }

  public func parse(query: String) -> DraftFullTextSearchQuery {
    DraftFullTextSearchQuery(query)
  }

  private func searchSources(for draft: ArticleDraft) -> [SearchSource] {
    [
      SearchSource(field: .title, value: draft.title),
      SearchSource(field: .summary, value: draft.summary),
      SearchSource(field: .body, value: draft.bodyMarkdown),
      SearchSource(field: .slug, value: draft.slug),
      SearchSource(field: .tags, value: draft.tags.joined(separator: " · ")),
      SearchSource(field: .categories, value: draft.categories.joined(separator: " · ")),
      SearchSource(field: .authors, value: draft.authors.joined(separator: " · ")),
      SearchSource(field: .repositoryPath, value: draft.repositoryPath ?? ""),
    ].filter { !$0.value.isEmpty }
  }

  private func matches(
    in source: SearchSource,
    query: DraftFullTextSearchQuery,
    draft: ArticleDraft
  ) -> [DraftFullTextSearchHit] {
    let sourceTerms = query.highlightTerms(for: source.field)
    guard !sourceTerms.isEmpty else { return [] }
    let usesTextPhrase = sourceTerms == query.textTerms
      && contains(query.textPhrase, in: source.value)
    let needles = usesTextPhrase ? [query.textPhrase] : sourceTerms
    var matchedRanges = needles.flatMap { matchRanges(of: $0, in: source.value) }
    matchedRanges.sort {
      if $0.location == $1.location { return $0.length > $1.length }
      return $0.location < $1.location
    }
    matchedRanges = matchedRanges.reduce(into: []) { result, range in
      guard !result.contains(where: { NSIntersectionRange($0, range).length > 0 }) else {
        return
      }
      result.append(range)
    }

    let maximumMatches = source.field == .body ? 3 : 1
    return matchedRanges.prefix(maximumMatches).map { range in
      let snippet = snippet(in: source.value, around: range, field: source.field)
      return DraftFullTextSearchHit(
        draftID: draft.id,
        siteProfileID: draft.siteProfileID,
        draftTitle: draft.title,
        field: source.field,
        sourceRange: range,
        snippetPrefix: snippet.prefix,
        matchedText: snippet.match,
        snippetSuffix: snippet.suffix,
        updatedAt: draft.updatedAt,
        score: score(
          field: source.field,
          sourceLength: (source.value as NSString).length,
          range: range,
          isPhraseMatch: usesTextPhrase
        )
      )
    }
  }

  private func matchesFilters(
    _ query: DraftFullTextSearchQuery,
    draft: ArticleDraft
  ) -> Bool {
    guard query.titleTerms.allSatisfy({ contains($0, in: draft.title) }) else {
      return false
    }
    guard query.tagTerms.allSatisfy({ term in
      draft.tags.contains { contains(term, in: $0) }
    }) else {
      return false
    }
    guard query.statuses.isEmpty || query.statuses.contains(draft.status) else {
      return false
    }
    guard query.visibilities.isEmpty || query.visibilities.contains(draft.visibility) else {
      return false
    }
    if let beforeDate = query.beforeDate, draft.date >= beforeDate {
      return false
    }
    if let afterDate = query.afterDate, draft.date <= afterDate {
      return false
    }
    return true
  }

  private func representativeHit(
    for draft: ArticleDraft,
    sources: [SearchSource]
  ) -> DraftFullTextSearchHit? {
    guard let source = sources.first else { return nil }
    let text = source.value as NSString
    let desiredRange = NSRange(location: 0, length: min(text.length, 80))
    let range = text.rangeOfComposedCharacterSequences(for: desiredRange)
    let snippet = snippet(in: source.value, around: range, field: source.field)
    return DraftFullTextSearchHit(
      draftID: draft.id,
      siteProfileID: draft.siteProfileID,
      draftTitle: draft.title,
      field: source.field,
      sourceRange: range,
      snippetPrefix: snippet.prefix,
      matchedText: snippet.match,
      snippetSuffix: snippet.suffix,
      updatedAt: draft.updatedAt,
      score: score(
        field: source.field,
        sourceLength: text.length,
        range: range,
        isPhraseMatch: false
      )
    )
  }

  private func matchRanges(of needle: String, in value: String) -> [NSRange] {
    guard !needle.isEmpty else { return [] }
    let source = value as NSString
    var results: [NSRange] = []
    var cursor = 0
    while cursor < source.length {
      let range = source.range(
        of: needle,
        options: Self.comparisonOptions,
        range: NSRange(location: cursor, length: source.length - cursor)
      )
      guard range.location != NSNotFound, range.length > 0 else { break }
      results.append(range)
      cursor = NSMaxRange(range)
    }
    return results
  }

  private func contains(_ needle: String, in value: String) -> Bool {
    guard !needle.isEmpty else { return false }
    return (value as NSString).range(
      of: needle,
      options: Self.comparisonOptions
    ).location != NSNotFound
  }

  private func snippet(
    in value: String,
    around matchRange: NSRange,
    field: DraftFullTextSearchField
  ) -> (prefix: String, match: String, suffix: String) {
    let source = value as NSString
    let contextBefore = field == .body ? 72 : 44
    let contextAfter = field == .body ? 120 : 76
    let desiredRange = NSRange(
      location: max(0, matchRange.location - contextBefore),
      length: min(
        source.length - max(0, matchRange.location - contextBefore),
        matchRange.length + contextBefore + contextAfter
      )
    )
    let snippetRange = source.rangeOfComposedCharacterSequences(for: desiredRange)
    let prefixRange = NSRange(
      location: snippetRange.location,
      length: max(0, matchRange.location - snippetRange.location)
    )
    let suffixLocation = NSMaxRange(matchRange)
    let suffixRange = NSRange(
      location: suffixLocation,
      length: max(0, NSMaxRange(snippetRange) - suffixLocation)
    )
    return (
      prefix: (snippetRange.location > 0 ? "…" : "") + source.substring(with: prefixRange),
      match: source.substring(with: matchRange),
      suffix: source.substring(with: suffixRange) + (NSMaxRange(snippetRange) < source.length ? "…" : "")
    )
  }

  private func score(
    field: DraftFullTextSearchField,
    sourceLength: Int,
    range: NSRange,
    isPhraseMatch: Bool
  ) -> Int {
    let fieldScore: Int
    switch field {
    case .title: fieldScore = 900
    case .summary: fieldScore = 720
    case .body: fieldScore = 560
    case .slug: fieldScore = 500
    case .tags: fieldScore = 440
    case .categories: fieldScore = 420
    case .authors: fieldScore = 400
    case .repositoryPath: fieldScore = 320
    }
    return fieldScore
      + (isPhraseMatch ? 90 : 0)
      + (range.location == 0 ? 45 : 0)
      + (range.length == sourceLength ? 70 : 0)
      - min(40, range.location / 24)
  }

  private func hitSort(_ lhs: DraftFullTextSearchHit, _ rhs: DraftFullTextSearchHit) -> Bool {
    if lhs.score != rhs.score { return lhs.score > rhs.score }
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
    let titleOrder = lhs.draftTitle.localizedStandardCompare(rhs.draftTitle)
    if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
    if lhs.draftID != rhs.draftID { return lhs.draftID.uuidString < rhs.draftID.uuidString }
    if lhs.field != rhs.field { return lhs.field.rawValue < rhs.field.rawValue }
    return lhs.sourceRange.location < rhs.sourceRange.location
  }

  private static let comparisonOptions: NSString.CompareOptions = [
    .caseInsensitive,
    .diacriticInsensitive,
    .widthInsensitive,
  ]

  private struct SearchSource {
    let field: DraftFullTextSearchField
    let value: String
  }

}
