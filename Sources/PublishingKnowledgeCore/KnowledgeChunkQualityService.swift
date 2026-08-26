import Foundation

package struct KnowledgeChunkQualityAssessment: Hashable, Sendable {
  package var scoreMultiplier: Double
  package var isEligibleForRecommendation: Bool
  package var noiseMarkers: [String]
}

/// Shared quality gate for search diversification, related-content ranking,
/// and library health reporting. It intentionally keeps questionable chunks
/// searchable at a low rank while preventing them from becoming proactive AI
/// recommendations.
package struct KnowledgeChunkQualityService: Sendable {
  package init() {}

  package func assessment(for content: String) -> KnowledgeChunkQualityAssessment {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return KnowledgeChunkQualityAssessment(
        scoreMultiplier: 0.05,
        isEligibleForRecommendation: false,
        noiseMarkers: ["空白片段"]
      )
    }

    let lines = trimmed
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
    let lowercased = trimmed.lowercased()
    let knownNoiseMarkers = [
      "blogthis", "share to", "分享到", "发表评论", "发布评论", "comments",
      "较新的博文", "较早的博文", "博客归档", "订阅：", "posted by",
      "previous post", "next post", "cookie", "all rights reserved",
      "blogger.com/comment/frame", "blogger.com/share-post", "resources.blogblog.com/",
    ]
    let matchedMarkers = knownNoiseMarkers.filter(lowercased.contains)
    let noisyLineCount = lines.filter { line in
      knownNoiseMarkers.contains { line.contains($0) }
    }.count
    let noiseRatio = Double(noisyLineCount) / Double(max(lines.count, 1))

    let linkCount = lowercased.components(separatedBy: "http://").count - 1
      + lowercased.components(separatedBy: "https://").count - 1
      + lowercased.components(separatedBy: "](").count - 1
    let meaningfulCharacters = trimmed.unicodeScalars.filter {
      CharacterSet.alphanumerics.contains($0)
    }.count
    let urlLikeLineCount = lines.filter { line in
      line.hasPrefix("http://")
        || line.hasPrefix("https://")
        || line.range(of: "^!?\\[[^\\]]*\\]\\(https?://", options: .regularExpression) != nil
    }.count
    let isURLOnly = !lines.isEmpty && urlLikeLineCount == lines.count
    let isLinkHeavy = linkCount >= 6
      || (linkCount >= 3 && Double(linkCount) / Double(max(lines.count, 1)) >= 0.5)
    let isTooShort = meaningfulCharacters < 32 || trimmed.count < 48
    let hasHardNoise = matchedMarkers.contains {
      $0.contains("blogger.com/") || $0.contains("resources.blogblog.com/")
    }

    let linkPenalty = isLinkHeavy ? 0.42 : (linkCount >= 3 ? 0.72 : 1.0)
    let lengthPenalty = isTooShort ? 0.58 : 1.0
    let noisePenalty = max(0.12, 1 - min(noiseRatio, 0.85) * 1.12)
    let hardNoisePenalty = hasHardNoise || isURLOnly ? 0.12 : 1.0
    let multiplier = max(0.03, linkPenalty * lengthPenalty * noisePenalty * hardNoisePenalty)
    let eligible = !isTooShort
      && !isURLOnly
      && !isLinkHeavy
      && !hasHardNoise
      && noiseRatio < 0.34

    var reasons = matchedMarkers
    if isURLOnly { reasons.append("纯链接片段") }
    if isLinkHeavy { reasons.append("链接密集") }
    if isTooShort { reasons.append("内容过短") }
    return KnowledgeChunkQualityAssessment(
      scoreMultiplier: multiplier,
      isEligibleForRecommendation: eligible,
      noiseMarkers: Array(Set(reasons)).sorted()
    )
  }
}
