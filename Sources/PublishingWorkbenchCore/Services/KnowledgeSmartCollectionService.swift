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
    output += [true, false].compactMap { allowsAIUse in
      let count = documents.count { $0.allowsAIUse == allowsAIUse }
      return count > 0
        ? KnowledgeSmartCollection(
          rule: .aiPermission(allowsAIUse),
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
    case .aiPermission(let allowsAIUse):
      return document.allowsAIUse == allowsAIUse
    }
  }

  public func sourceDomain(for document: KnowledgeDocument) -> String? {
    guard let url = document.sourceURL,
          !url.isFileURL,
          var host = url.host(percentEncoded: false)?.lowercased(),
          !host.isEmpty else { return nil }
    if host.hasPrefix("www.") {
      host.removeFirst(4)
    }
    return host
  }

  private func countedCollections(
    documents: [KnowledgeDocument],
    kind: KnowledgeSmartCollectionKind,
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
      case .time, .aiPermission:
        preconditionFailure("Time and AI permission collections are counted separately")
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

struct KnowledgeRelatedChapterRankingService: Sendable {
  private let collectionService = KnowledgeSmartCollectionService()
  private let qualityService = KnowledgeChunkQualityService()

  func recommendations(
    anchor: KnowledgeSemanticIndexRecord,
    candidates: [KnowledgeSemanticIndexRecord],
    semanticScores: [UUID: Double],
    limit: Int
  ) -> [KnowledgeRelatedChapter] {
    guard limit > 0 else { return [] }
    let ranked = candidates.compactMap { candidate -> KnowledgeRelatedChapter? in
      guard candidate.chunk.id != anchor.chunk.id,
            candidate.chunk.contentHash != anchor.chunk.contentHash else { return nil }
      let quality = qualityService.assessment(for: candidate.chunk.content)
      let sharedAuthors = sharedValues(anchor.document.authors, candidate.document.authors)
      let sharedTags = sharedValues(anchor.document.tags, candidate.document.tags)
      let hasMetadataSignal = !sharedAuthors.isEmpty || !sharedTags.isEmpty
      let semanticScore = semanticScores[candidate.chunk.id] ?? 0
      let hasStrongSemanticSignal = semanticScore >= 0.3
      let isShortButOtherwiseClean = quality.noiseMarkers == ["内容过短"]
      guard quality.isEligibleForRecommendation
              || ((hasMetadataSignal || hasStrongSemanticSignal) && isShortButOtherwiseClean)
      else { return nil }
      if candidate.document.id == anchor.document.id,
         anchor.document.kind == .webpage {
        return nil
      }
      var score = 0.0
      var reasons: [KnowledgeRelatedChapterReason] = []

      if candidate.document.id == anchor.document.id {
        score += 0.18
        reasons.append(.sameDocument)
      }

      if let author = sharedAuthors.first {
        score += 0.22 + min(Double(sharedAuthors.count - 1) * 0.03, 0.06)
        reasons.append(.author(author))
      }

      if let tag = sharedTags.first {
        score += 0.18 + min(Double(sharedTags.count - 1) * 0.025, 0.05)
        reasons.append(.tag(tag))
      }

      if let anchorDomain = collectionService.sourceDomain(for: anchor.document),
         let candidateDomain = collectionService.sourceDomain(for: candidate.document),
         anchorDomain == candidateDomain {
        score += 0.12
        reasons.append(.sourceDomain(anchorDomain))
      }

      let interval = abs(
        candidate.document.importedAt.timeIntervalSince(anchor.document.importedAt)
      )
      if interval <= 7 * 86_400 {
        score += 0.06
        reasons.append(.nearbyTime)
      } else if interval <= 30 * 86_400 {
        score += 0.03
        reasons.append(.nearbyTime)
      }

      if semanticScore > 0 {
        score += min(semanticScore, 1) * 0.5 * quality.scoreMultiplier
        reasons.append(.semantic)
      }

      guard score >= 0.12, !reasons.isEmpty else { return nil }
      return KnowledgeRelatedChapter(
        document: candidate.document,
        chunk: candidate.chunk,
        score: score,
        reasons: reasons
      )
    }
    .sorted {
      if $0.score != $1.score { return $0.score > $1.score }
      if $0.document.updatedAt != $1.document.updatedAt {
        return $0.document.updatedAt > $1.document.updatedAt
      }
      return $0.chunk.ordinal < $1.chunk.ordinal
    }

    var perDocumentCount: [UUID: Int] = [:]
    var output: [KnowledgeRelatedChapter] = []
    for recommendation in ranked {
      guard output.count < limit else { break }
      let count = perDocumentCount[recommendation.document.id, default: 0]
      guard count < 2 else { continue }
      output.append(recommendation)
      perDocumentCount[recommendation.document.id] = count + 1
    }
    return output
  }

  private func sharedValues(_ lhs: [String], _ rhs: [String]) -> [String] {
    let rhsKeys = Set(rhs.map(normalized))
    var seen = Set<String>()
    return lhs.filter { value in
      let key = normalized(value)
      return !key.isEmpty && rhsKeys.contains(key) && seen.insert(key).inserted
    }
  }

  private func normalized(_ value: String) -> String {
    value
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: .current
      )
      .lowercased()
  }
}
