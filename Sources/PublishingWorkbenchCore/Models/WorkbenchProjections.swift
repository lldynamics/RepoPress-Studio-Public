import Foundation

/// The sort choices used by the Writing list.  The macOS view keeps ownership
/// of labels and persistence, while the ordering rules live in the core.
public enum DraftListSortOrder: String, CaseIterable, Codable, Identifiable, Sendable {
  case updatedNewest
  case updatedOldest
  case articleDateNewest
  case articleDateOldest
  case titleAscending
  case titleDescending

  public var id: String { rawValue }
}

public struct DraftListStatistics: Hashable, Sendable {
  public let totalCount: Int
  public let siteDraftCount: Int
  public let generalDraftCount: Int

  public init(totalCount: Int, siteDraftCount: Int, generalDraftCount: Int) {
    self.totalCount = totalCount
    self.siteDraftCount = siteDraftCount
    self.generalDraftCount = generalDraftCount
  }
}

/// Pure selection, filtering and ordering rules for the Writing list.
///
/// This type deliberately has no Store reference or cached state.  Keeping
/// the rules here makes them reusable by facades, commands and tests without
/// causing WorkbenchStore to become another presentation layer.
public struct DraftListProjection: Sendable {
  private init() {}

  public static func siteDrafts(
    _ drafts: [ArticleDraft],
    for profileID: UUID
  ) -> [ArticleDraft] {
    drafts.filter { $0.belongs(toSiteProfileID: profileID) }
  }

  public static func writingDrafts(
    _ drafts: [ArticleDraft],
    activeProfileID: UUID,
    scope: DraftListContentScope
  ) -> [ArticleDraft] {
    switch scope {
    case .currentSite:
      return siteDrafts(drafts, for: activeProfileID)
    case .general:
      return drafts.filter(\.isGeneralDraft)
    }
  }

  public static func selectedDraft(
    _ drafts: [ArticleDraft],
    selectedDraftID: UUID?,
    activeProfileID: UUID,
    scope: DraftListContentScope
  ) -> ArticleDraft? {
    let visibleDrafts = writingDrafts(
      drafts,
      activeProfileID: activeProfileID,
      scope: scope
    )
    if let selectedDraftID,
      let selected = visibleDrafts.first(where: { $0.id == selectedDraftID })
    {
      return selected
    }
    return visibleDrafts.first
  }

  public static func statistics(
    _ drafts: [ArticleDraft],
    activeProfileID: UUID
  ) -> DraftListStatistics {
    let siteDraftCount = siteDrafts(drafts, for: activeProfileID).count
    let generalDraftCount = drafts.filter(\.isGeneralDraft).count
    return DraftListStatistics(
      totalCount: drafts.count,
      siteDraftCount: siteDraftCount,
      generalDraftCount: generalDraftCount
    )
  }

  public static func sorted(
    _ drafts: [ArticleDraft],
    by order: DraftListSortOrder
  ) -> [ArticleDraft] {
    drafts.sorted { lhs, rhs in
      switch order {
      case .updatedNewest:
        return ordered(lhs, rhs, date: \.metadataUpdatedAt, newestFirst: true)
      case .updatedOldest:
        return ordered(lhs, rhs, date: \.metadataUpdatedAt, newestFirst: false)
      case .articleDateNewest:
        return ordered(lhs, rhs, date: \.date, newestFirst: true)
      case .articleDateOldest:
        return ordered(lhs, rhs, date: \.date, newestFirst: false)
      case .titleAscending:
        return orderedByTitle(lhs, rhs, ascending: true)
      case .titleDescending:
        return orderedByTitle(lhs, rhs, ascending: false)
      }
    }
  }

  private static func ordered(
    _ lhs: ArticleDraft,
    _ rhs: ArticleDraft,
    date: KeyPath<ArticleDraft, Date>,
    newestFirst: Bool
  ) -> Bool {
    let lhsDate = lhs[keyPath: date]
    let rhsDate = rhs[keyPath: date]
    guard lhsDate != rhsDate else {
      return stableTitleOrder(lhs, rhs)
    }
    return newestFirst ? lhsDate > rhsDate : lhsDate < rhsDate
  }

  private static func orderedByTitle(
    _ lhs: ArticleDraft,
    _ rhs: ArticleDraft,
    ascending: Bool
  ) -> Bool {
    let comparison = lhs.title.localizedStandardCompare(rhs.title)
    guard comparison != .orderedSame else {
      if lhs.metadataUpdatedAt != rhs.metadataUpdatedAt {
        return lhs.metadataUpdatedAt > rhs.metadataUpdatedAt
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    return ascending
      ? comparison == .orderedAscending
      : comparison == .orderedDescending
  }

  private static func stableTitleOrder(
    _ lhs: ArticleDraft,
    _ rhs: ArticleDraft
  ) -> Bool {
    let comparison = lhs.title.localizedStandardCompare(rhs.title)
    guard comparison == .orderedSame else {
      return comparison == .orderedAscending
    }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}

public struct ContentHealthStatistics: Hashable, Sendable {
  public let draftCount: Int
  public let issueCount: Int
  public let errorCount: Int
  public let warningCount: Int
  public let passingDraftCount: Int

  public init(
    draftCount: Int,
    issueCount: Int,
    errorCount: Int,
    warningCount: Int,
    passingDraftCount: Int
  ) {
    self.draftCount = draftCount
    self.issueCount = issueCount
    self.errorCount = errorCount
    self.warningCount = warningCount
    self.passingDraftCount = passingDraftCount
  }
}

/// Pure aggregation rules for content-health summaries.
public struct ContentHealthProjection: Sendable {
  private init() {}

  public static func publicRiskSummary(
    from summaries: [DraftPreflightSummary]
  ) -> PublicRiskSummary {
    PublicRiskSummary(issues: summaries.flatMap(\.issues))
  }

  public static func publicRiskDraftSummaries(
    from summaries: [DraftPreflightSummary]
  ) -> [DraftPreflightSummary] {
    summaries.filter { !$0.publicRiskIssues.isEmpty }
  }

  public static func statistics(
    from summaries: [DraftPreflightSummary]
  ) -> ContentHealthStatistics {
    let issues = summaries.flatMap(\.issues)
    return ContentHealthStatistics(
      draftCount: summaries.count,
      issueCount: issues.count,
      errorCount: issues.filter { $0.severity == .error }.count,
      warningCount: issues.filter { $0.severity == .warning }.count,
      passingDraftCount: summaries.filter(\.isPassing).count
    )
  }
}

/// Pure readiness calculation for local write/commit actions.  Repository
/// access, preflight execution and remote risk checks stay outside this type;
/// callers pass their results in as values.
public struct PublishingReadinessProjection: Sendable {
  private init() {}

  public static func blockingIssues(
    preview: LocalPublishPreview,
    draftIssues: [PreflightIssue]
  ) -> [PreflightIssue] {
    (draftIssues + preview.issues).filter { $0.severity == .error }
  }

  public static func makeReadiness(
    package: PublishPackage,
    preview: LocalPublishPreview,
    draftIssuesWithoutRepository: [PreflightIssue],
    draftIssuesWithRepository: [PreflightIssue],
    repositoryBlockingIssues: [PreflightIssue] = [],
    remoteWarningIssues: [PreflightIssue] = []
  ) -> LocalPublishReadiness {
    var writeBlockingIssues = blockingIssues(
      preview: preview,
      draftIssues: draftIssuesWithoutRepository
    )
    var commitBlockingIssues = blockingIssues(
      preview: preview,
      draftIssues: draftIssuesWithRepository
    )
    for repositoryIssue in repositoryBlockingIssues
    where !commitBlockingIssues.contains(where: { $0.title == repositoryIssue.title }) {
      commitBlockingIssues.append(repositoryIssue)
    }
    for repositoryIssue in repositoryBlockingIssues
    where !writeBlockingIssues.contains(where: { $0.title == repositoryIssue.title }) {
      writeBlockingIssues.append(repositoryIssue)
    }

    let warningIssues = (preview.issues + draftIssuesWithRepository + remoteWarningIssues)
      .filter { $0.severity == .warning }
    let changedFileCount = preview.changedFileDiffs.count

    return LocalPublishReadiness(
      writeReadiness: actionReadiness(
        blockingIssues: writeBlockingIssues,
        warningIssues: warningIssues,
        changedFileCount: changedFileCount
      ),
      commitReadiness: actionReadiness(
        blockingIssues: commitBlockingIssues,
        warningIssues: warningIssues,
        changedFileCount: changedFileCount
      ),
      changedFileCount: changedFileCount,
      fileCount: package.files.count,
      writeBlockingIssues: writeBlockingIssues,
      commitBlockingIssues: commitBlockingIssues,
      warningIssues: warningIssues
    )
  }

  private static func actionReadiness(
    blockingIssues: [PreflightIssue],
    warningIssues: [PreflightIssue],
    changedFileCount: Int
  ) -> LocalPublishActionReadiness {
    if !blockingIssues.isEmpty { return .blocked }
    if changedFileCount == 0 { return .unchanged }
    if !warningIssues.isEmpty { return .needsReview }
    return .ready
  }
}
