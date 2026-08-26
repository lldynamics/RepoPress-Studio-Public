import Foundation

public struct KnowledgeSmartCollectionService: Sendable {
  public init() {}

  public func collections(
    for documents: [KnowledgeDocument],
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> [KnowledgeSmartCollection] {
    var output: [KnowledgeSmartCollection] = []
    output += countedCollections(documents: documents, kind: .author) { $0.authors }
    output += countedCollections(documents: documents, kind: .tag) { $0.tags }
    output += countedCollections(documents: documents, kind: .sourceDomain) { document in
      sourceDomain(for: document).map { [$0] } ?? []
    }
    output += KnowledgeSmartTimeBucket.allCases.compactMap { bucket in
      let count = documents.count {
        matches($0, rule: .time(bucket), now: now, calendar: calendar)
      }
      return count > 0
        ? KnowledgeSmartCollection(rule: .time(bucket), documentCount: count)
        : nil
    }
    output += [true, false].compactMap { allowsRemoteAIUse in
      let count = documents.count { $0.allowsRemoteAIUse == allowsRemoteAIUse }
      return count > 0
        ? KnowledgeSmartCollection(
          rule: .aiPermission(allowsRemoteAIUse),
          documentCount: count
        )
        : nil
    }
    return output
  }

  public func matches(
    _ document: KnowledgeDocument,
    rule: KnowledgeSmartCollectionRule,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> Bool {
    switch rule {
    case .author(let author):
      return document.authors.contains { equivalent($0, author) }
    case .tag(let tag):
      return document.tags.contains { equivalent($0, tag) }
    case .sourceDomain(let domain):
      return sourceDomain(for: document).map { equivalent($0, domain) } ?? false
    case .time(let bucket):
      return matches(document.importedAt, bucket: bucket, now: now, calendar: calendar)
    case .aiPermission(let allowsRemoteAIUse):
      return document.allowsRemoteAIUse == allowsRemoteAIUse
    }
  }

  public func matches(
    _ document: KnowledgeDocument,
    rules: [KnowledgeSmartCollectionRule],
    matchMode: KnowledgeSmartCollectionMatchMode,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> Bool {
    guard !rules.isEmpty else { return true }
    switch matchMode {
    case .all:
      return rules.allSatisfy { matches(document, rule: $0, now: now, calendar: calendar) }
    case .any:
      return rules.contains { matches(document, rule: $0, now: now, calendar: calendar) }
    }
  }

  public func sourceDomain(for document: KnowledgeDocument) -> String? {
    document.sourceURL.flatMap { sourceDomain(for: $0) }
  }

  public func sourceDomain(for url: URL) -> String? {
    guard !url.isFileURL,
          var host = url.host(percentEncoded: false)?.lowercased(),
          !host.isEmpty else { return nil }
    if host.hasPrefix("www.") {
      host.removeFirst(4)
    }
    return host
  }

  public func browserOrganizationSuggestions(
    sourceURL: URL,
    authors: [String],
    tags: [String],
    documents: [KnowledgeDocument],
    folders: [KnowledgeFolder],
    limit: Int = 3
  ) -> KnowledgeBrowserOrganizationSuggestions {
    guard limit > 0 else {
      return KnowledgeBrowserOrganizationSuggestions(folders: [], tags: [])
    }
    let incomingDomain = sourceDomain(for: sourceURL)
    let incomingAuthors = Set(authors.map(normalized).filter { !$0.isEmpty })
    let incomingTags = Set(tags.map(normalized).filter { !$0.isEmpty })
    let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
    var folderScores: [UUID: Double] = [:]
    var folderReasons: [UUID: Set<KnowledgeBrowserFolderSuggestionReason>] = [:]
    var tagScores: [String: (displayValue: String, score: Double)] = [:]

    for document in documents {
      guard let folderID = document.folderID, foldersByID[folderID] != nil else { continue }
      var documentScore = 0.0
      var reasons = Set<KnowledgeBrowserFolderSuggestionReason>()
      if let incomingDomain,
         matches(document, rule: .sourceDomain(incomingDomain)) {
        documentScore += 6
        reasons.insert(.sourceDomain)
      }
      let sharedAuthors = document.authors.filter { incomingAuthors.contains(normalized($0)) }
      if !sharedAuthors.isEmpty {
        documentScore += 4 + min(Double(sharedAuthors.count - 1), 2)
        reasons.insert(.author)
      }
      let sharedTags = document.tags.filter { incomingTags.contains(normalized($0)) }
      if !sharedTags.isEmpty {
        documentScore += 2 + min(Double(sharedTags.count - 1), 3)
        reasons.insert(.tag)
      }
      guard documentScore > 0 else { continue }
      folderScores[folderID, default: 0] += documentScore
      folderReasons[folderID, default: []].formUnion(reasons)
      for tag in document.tags {
        let displayValue = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalized(displayValue)
        guard !key.isEmpty, !incomingTags.contains(key) else { continue }
        let current = tagScores[key] ?? (displayValue, 0)
        tagScores[key] = (current.displayValue, current.score + documentScore)
      }
    }

    let folderSuggestions = folderScores.compactMap { folderID, score in
      foldersByID[folderID].map {
        KnowledgeBrowserFolderSuggestion(
          folder: $0,
          score: score,
          reasons: Array(folderReasons[folderID] ?? []).sorted { $0.rawValue < $1.rawValue }
        )
      }
    }
    .sorted {
      if $0.score != $1.score { return $0.score > $1.score }
      return $0.folder.name.localizedStandardCompare($1.folder.name) == .orderedAscending
    }
    .prefix(limit)

    let suggestedTags = tagScores.values
      .sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        return $0.displayValue.localizedStandardCompare($1.displayValue) == .orderedAscending
      }
      .prefix(8)
      .map(\.displayValue)

    return KnowledgeBrowserOrganizationSuggestions(
      folders: Array(folderSuggestions),
      tags: suggestedTags
    )
  }

  private func countedCollections(
    documents: [KnowledgeDocument],
    kind: CountedKnowledgeSmartCollectionKind,
    values: (KnowledgeDocument) -> [String]
  ) -> [KnowledgeSmartCollection] {
    var counts: [String: (displayValue: String, count: Int)] = [:]
    for document in documents {
      var seen = Set<String>()
      for rawValue in values(document) {
        let displayValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalized(displayValue)
        guard !key.isEmpty, seen.insert(key).inserted else { continue }
        let current = counts[key] ?? (displayValue, 0)
        counts[key] = (current.displayValue, current.count + 1)
      }
    }
    return counts.values.map { item in
      let rule: KnowledgeSmartCollectionRule
      switch kind {
      case .author: rule = .author(item.displayValue)
      case .tag: rule = .tag(item.displayValue)
      case .sourceDomain: rule = .sourceDomain(item.displayValue)
      }
      return KnowledgeSmartCollection(rule: rule, documentCount: item.count)
    }
    .sorted {
      if $0.documentCount != $1.documentCount {
        return $0.documentCount > $1.documentCount
      }
      return $0.rule.id.localizedStandardCompare($1.rule.id) == .orderedAscending
    }
  }

  private enum CountedKnowledgeSmartCollectionKind {
    case author
    case tag
    case sourceDomain
  }

  private func matches(
    _ date: Date,
    bucket: KnowledgeSmartTimeBucket,
    now: Date,
    calendar: Calendar
  ) -> Bool {
    switch bucket {
    case .today:
      return calendar.isDate(date, inSameDayAs: now)
    case .thisWeek:
      return !calendar.isDate(date, inSameDayAs: now)
        && calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
    case .thisMonth:
      return !calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        && calendar.isDate(date, equalTo: now, toGranularity: .month)
        && calendar.isDate(date, equalTo: now, toGranularity: .year)
    case .earlier:
      return !calendar.isDate(date, equalTo: now, toGranularity: .month)
        || !calendar.isDate(date, equalTo: now, toGranularity: .year)
    }
  }

  private func equivalent(_ lhs: String, _ rhs: String) -> Bool {
    normalized(lhs) == normalized(rhs)
  }

  private func normalized(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: .current
      )
      .lowercased()
  }
}
