import Foundation

public struct KnowledgeSearchDiversificationService: Sendable {
  private let qualityService = KnowledgeChunkQualityService()

  public init() {}

  public func rank(
    _ candidates: [KnowledgeSearchResult],
    limit: Int,
    maximumResultsPerDocument: Int = 2
  ) -> [KnowledgeSearchResult] {
    guard limit > 0, maximumResultsPerDocument > 0 else { return [] }

    let prepared = collapseNearDuplicates(candidates).map { candidate in
      RankedCandidate(
        result: candidate,
        adjustedScore: max(candidate.score, 0.000_001)
          * qualityService.assessment(for: candidate.chunk.content).scoreMultiplier,
        fingerprint: fingerprint(candidate.chunk.content)
      )
    }
    var remaining = prepared
    var selected: [RankedCandidate] = []
    var documentCounts: [UUID: Int] = [:]

    while selected.count < limit {
      var bestIndex: Int?
      var bestValue = -Double.infinity

      for (index, candidate) in remaining.enumerated() {
        let existingCount = documentCounts[candidate.result.document.id, default: 0]
        guard existingCount < maximumResultsPerDocument else { continue }
        let documentNovelty = existingCount == 0 ? 1.0 : 0.58
        let maximumSimilarity = selected
          .map { similarity(candidate.fingerprint, $0.fingerprint) }
          .max() ?? 0
        let novelty = max(0.28, 1 - maximumSimilarity * 0.62)
        let value = candidate.adjustedScore * documentNovelty * novelty

        if value > bestValue {
          bestValue = value
          bestIndex = index
        } else if value == bestValue,
                  let currentBestIndex = bestIndex,
                  precedes(candidate.result, remaining[currentBestIndex].result) {
          bestIndex = index
        }
      }

      guard let bestIndex else { break }
      let chosen = remaining.remove(at: bestIndex)
      selected.append(chosen)
      documentCounts[chosen.result.document.id, default: 0] += 1
    }

    return selected.map(\.result)
  }

  private func collapseNearDuplicates(
    _ candidates: [KnowledgeSearchResult]
  ) -> [KnowledgeSearchResult] {
    let sorted = candidates.sorted(by: precedes)
    var retained: [KnowledgeSearchResult] = []
    var fingerprints: [UUID: [Set<String>]] = [:]
    var hashes: [UUID: Set<String>] = [:]

    for candidate in sorted {
      let documentID = candidate.document.id
      if hashes[documentID, default: []].contains(candidate.chunk.contentHash) {
        continue
      }
      let candidateFingerprint = fingerprint(candidate.chunk.content)
      let isNearDuplicate = fingerprints[documentID, default: []].contains { existing in
        similarity(candidateFingerprint, existing) >= 0.86
      }
      guard !isNearDuplicate else { continue }
      retained.append(candidate)
      fingerprints[documentID, default: []].append(candidateFingerprint)
      hashes[documentID, default: []].insert(candidate.chunk.contentHash)
    }
    return retained
  }

  private func precedes(_ lhs: KnowledgeSearchResult, _ rhs: KnowledgeSearchResult) -> Bool {
    if lhs.score != rhs.score { return lhs.score > rhs.score }
    if lhs.document.updatedAt != rhs.document.updatedAt {
      return lhs.document.updatedAt > rhs.document.updatedAt
    }
    if lhs.document.id != rhs.document.id {
      return lhs.document.id.uuidString < rhs.document.id.uuidString
    }
    return lhs.chunk.ordinal < rhs.chunk.ordinal
  }

  private func fingerprint(_ content: String) -> Set<String> {
    let normalized = content
      .lowercased()
      .unicodeScalars
      .filter { CharacterSet.alphanumerics.contains($0) }
      .map(String.init)
      .joined()
    guard !normalized.isEmpty else { return [] }
    let characters = Array(normalized)
    let width = min(12, max(4, characters.count / 10))
    guard characters.count > width else { return [normalized] }
    var shingles = Set<String>()
    var index = 0
    while index + width <= characters.count {
      shingles.insert(String(characters[index..<(index + width)]))
      index += max(1, width / 2)
    }
    return shingles
  }

  private func similarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
    guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
    let intersection = lhs.intersection(rhs).count
    let union = lhs.union(rhs).count
    return union == 0 ? 0 : Double(intersection) / Double(union)
  }
}

private struct RankedCandidate {
  var result: KnowledgeSearchResult
  var adjustedScore: Double
  var fingerprint: Set<String>
}
