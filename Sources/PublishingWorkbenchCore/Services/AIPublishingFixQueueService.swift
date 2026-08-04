import Foundation

public enum AIPublishingFixQueuePriority: Int, Codable, Comparable, Sendable {
  case high = 0
  case medium = 1
  case low = 2

  public static func < (lhs: AIPublishingFixQueuePriority, rhs: AIPublishingFixQueuePriority) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public var displayName: String {
    switch self {
    case .high:
      return "高"
    case .medium:
      return "中"
    case .low:
      return "低"
    }
  }
}

public struct AIPublishingFixQueueItem: Identifiable, Codable, Hashable, Sendable {
  public var id: String
  public var priority: AIPublishingFixQueuePriority
  public var draftID: UUID
  public var draftTitle: String
  public var markdownPath: String
  public var needsSummary: Bool
  public var needsTags: Bool
  public var frontMatterIssueCount: Int
  public var issueTitles: [String]
  public var recommendedAction: AIPublishingActionKind

  public init(
    id: String,
    priority: AIPublishingFixQueuePriority,
    draftID: UUID,
    draftTitle: String,
    markdownPath: String,
    needsSummary: Bool,
    needsTags: Bool,
    frontMatterIssueCount: Int,
    issueTitles: [String],
    recommendedAction: AIPublishingActionKind
  ) {
    self.id = id
    self.priority = priority
    self.draftID = draftID
    self.draftTitle = draftTitle
    self.markdownPath = markdownPath
    self.needsSummary = needsSummary
    self.needsTags = needsTags
    self.frontMatterIssueCount = frontMatterIssueCount
    self.issueTitles = issueTitles
    self.recommendedAction = recommendedAction
  }

  public var requestSummary: String {
    var parts: [String] = []
    if needsSummary {
      parts.append("摘要")
    }
    if needsTags {
      parts.append("Tags")
    }
    if frontMatterIssueCount > 0 {
      parts.append("Front Matter \(frontMatterIssueCount) 项")
    }
    return parts.isEmpty ? "AI 检查" : parts.joined(separator: " / ")
  }
}

public struct AIPublishingFixQueueService: Sendable {
  public init() {}

  public func items(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    summaries: [DraftPreflightSummary]
  ) -> [AIPublishingFixQueueItem] {
    let summariesByDraftID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.draftID, $0) })
    return drafts.compactMap { draft in
      item(
        for: draft,
        profile: profile,
        summary: summariesByDraftID[draft.id]
      )
    }
    .sorted { lhs, rhs in
      if lhs.priority != rhs.priority {
        return lhs.priority < rhs.priority
      }
      if lhs.frontMatterIssueCount != rhs.frontMatterIssueCount {
        return lhs.frontMatterIssueCount > rhs.frontMatterIssueCount
      }
      return lhs.draftTitle.localizedStandardCompare(rhs.draftTitle) == .orderedAscending
    }
  }

  private func item(
    for draft: ArticleDraft,
    profile: SiteProfile,
    summary: DraftPreflightSummary?
  ) -> AIPublishingFixQueueItem? {
    guard !draft.isPrivate else {
      return nil
    }

    guard !draft.bodyMarkdown.trimmedForPublishing.isEmpty else {
      return nil
    }

    let issues = summary?.blockingIssues ?? []
    let metadataIssues = issues.filter(Self.isAIFixableMetadataIssue)
    let needsSummary = draft.summary.trimmedForPublishing.isEmpty
      || metadataIssues.contains { $0.structuredField == .summary }
    let needsTags = draft.tags.isEmpty
      || metadataIssues.contains { $0.structuredField == .tags }

    guard needsSummary || needsTags || !metadataIssues.isEmpty else {
      return nil
    }

    return AIPublishingFixQueueItem(
      id: "\(draft.id.uuidString)-ai-fix",
      priority: priority(needsSummary: needsSummary, needsTags: needsTags, issues: metadataIssues),
      draftID: draft.id,
      draftTitle: draft.title.trimmedForPublishing.nilIfEmpty ?? profile.markdownPath(for: draft),
      markdownPath: profile.markdownPath(for: draft),
      needsSummary: needsSummary,
      needsTags: needsTags,
      frontMatterIssueCount: metadataIssues.count,
      issueTitles: Array(metadataIssues.map(\.title).prefix(4)),
      recommendedAction: recommendedAction(
        needsSummary: needsSummary,
        needsTags: needsTags,
        issues: metadataIssues
      )
    )
  }

  private func priority(
    needsSummary: Bool,
    needsTags: Bool,
    issues: [PreflightIssue]
  ) -> AIPublishingFixQueuePriority {
    if issues.contains(where: { $0.severity == .error }) {
      return .high
    }
    if needsSummary || needsTags {
      return .medium
    }
    return .low
  }

  private func recommendedAction(
    needsSummary: Bool,
    needsTags: Bool,
    issues: [PreflightIssue]
  ) -> AIPublishingActionKind {
    if needsSummary && needsTags {
      return .draftFrontMatterPack
    }
    if needsSummary {
      return .suggestSummary
    }
    if needsTags {
      return .suggestTags
    }
    if issues.contains(where: {
      $0.structuredField == .title || $0.structuredField == .slug || $0.structuredField == .cover
    }) {
      return .draftFrontMatterPack
    }
    return .reviewSEOReadability
  }

  private static func isAIFixableMetadataIssue(_ issue: PreflightIssue) -> Bool {
    guard issue.severity != .info else {
      return false
    }
    switch issue.structuredField {
    case .title, .slug, .summary, .tags, .cover:
      return true
    default:
      return false
    }
  }
}
