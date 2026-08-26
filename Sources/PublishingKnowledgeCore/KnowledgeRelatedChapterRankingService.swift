import Foundation

package struct KnowledgeRelatedChapterRankingService: Sendable {
  private let collectionService = KnowledgeSmartCollectionService()
  private let qualityService = KnowledgeChunkQualityService()

  package init() {}

  package func recommendations(
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
