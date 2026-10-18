import PublishingDomainContracts
import PublishingWorkbenchCore
import SwiftUI

enum DraftListFilter: String, CaseIterable, Identifiable {
  case all
  case draft
  case checkFailed
  case ready
  case published
  case localOnly
  case privateArticles

  var id: String { rawValue }

  static let primaryFilters: [DraftListFilter] = [.all, .draft, .ready]
  static let overflowFilters: [DraftListFilter] = [
    .published, .localOnly, .privateArticles, .checkFailed,
  ]

  var displayName: String {
    switch self {
    case .all:
      return "全部文章"
    case .draft:
      return "草稿"
    case .checkFailed:
      return "检查失败"
    case .ready:
      return "待发布"
    case .published:
      return "已发布"
    case .localOnly:
      return "仅本地"
    case .privateArticles:
      return "私密文章"
    }
  }

  var requiresTaskQueueState: Bool {
    switch self {
    case .checkFailed:
      return true
    case .all, .draft, .ready, .published, .localOnly, .privateArticles:
      return false
    }
  }

  func matches(
    _ draft: ArticleDraft,
    taskState: DraftTaskQueueState?
  ) -> Bool {
    switch self {
    case .all:
      return true
    case .draft:
      return draft.articleState == .draft
    case .checkFailed:
      return taskState?.hasPreflightErrors == true
    case .ready:
      return draft.articleState == .ready
    case .published:
      return draft.articleState == .published
    case .localOnly:
      return draft.articleState == .localOnly
    case .privateArticles:
      return draft.isPrivate
    }
  }
}

enum WritingDraftSortOrder: String, CaseIterable, Identifiable {
  case updatedNewest
  case updatedOldest
  case articleDateNewest
  case articleDateOldest
  case titleAscending
  case titleDescending

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .updatedNewest:
      return "最近更新"
    case .updatedOldest:
      return "最早更新"
    case .articleDateNewest:
      return "文章日期：最新"
    case .articleDateOldest:
      return "文章日期：最早"
    case .titleAscending:
      return "标题：A–Z"
    case .titleDescending:
      return "标题：Z–A"
    }
  }

  func sorted(_ drafts: [ArticleDraft]) -> [ArticleDraft] {
    let projectionOrder = DraftListSortOrder(rawValue: rawValue) ?? .updatedNewest
    return DraftListProjection.sorted(drafts, by: projectionOrder)
  }
}

/// Lightweight identity for the fields rendered by a draft-list row.
///
/// The body is intentionally absent. The persisted count changes only after a
/// background refresh, so rows can notice it without hashing or scanning the
/// body when an unrelated draft changes.
/// Per-row facts that come from checks and repository state rather than the
/// draft's own metadata.
struct WritingDraftRowAttention: Hashable {
  var articleIssueCount = 0
  var needsSync = false

  static let none = WritingDraftRowAttention()

  static func syncNeedsAttention(_ state: DraftRepositorySyncState) -> Bool {
    state.hasSyncProblem
  }
}

struct WritingDraftRowPresentationCacheKey: Hashable {
  let attention: WritingDraftRowAttention
  let metadataUpdatedAt: Date
  let wordCount: Int
  let title: String
  let status: DraftStatus
  let articleState: ArticleState
  let isGeneralDraft: Bool
  let isPrivate: Bool
  let visibility: ArticleVisibility
  let isMasked: Bool
  let help: String

  init(
    draft: ArticleDraft,
    profile: SiteProfile,
    display: PrivateContentDisplay,
    attention: WritingDraftRowAttention = .none
  ) {
    self.attention = attention
    metadataUpdatedAt = draft.metadataUpdatedAt
    wordCount = draft.wordCount
    title = display.title
    status = draft.status
    articleState = draft.articleState
    isGeneralDraft = draft.isGeneralDraft
    isPrivate = draft.isPrivate
    visibility = draft.visibility
    isMasked = display.isMasked
    help = writingDraftRowHelp(draft: draft, profile: profile, display: display)
  }
}

private func writingDraftRowHelp(
  draft: ArticleDraft,
  profile: SiteProfile,
  display: PrivateContentDisplay
) -> String {
  if display.isMasked { return display.summary }
  return draft.isGeneralDraft
    ? String(localized: "仅本地草稿，不绑定站点")
    : profile.markdownPath(for: draft)
}

/// Rows separate the fixed date from variable status facts, so a narrow list
/// preserves a complete year rather than truncating one metadata line.
struct WritingDraftRowPresentation {
  let title: String
  /// Non-status row facts other than the date; the compact summary keeps
  /// attention first so truncation cannot hide it behind ordinary metadata.
  let metadataDetails: String
  let metadataDate: String
  let metadata: String
  let privacySystemImage: String?
  let metadataSymbolRole: WritingDraftRowSymbolRole
  let statusSummary: String
  /// "N 项问题" when the article's own publish checks report errors.
  let issueSummary: String?
  let statusTags: [WorkbenchStatusTagKind]
  let help: String

  init(
    draft: ArticleDraft,
    profile: SiteProfile,
    display: PrivateContentDisplay,
    attention: WritingDraftRowAttention = .none
  ) {
    title = display.title.nilIfEmpty ?? String(localized: "未命名文章")
    // The list scope already says whether rows are general drafts, so only
    // status, privacy and the facts that differ per row are repeated here.
    // Keep variable status facts separate from the date. A narrow sidebar can
    // truncate the former without ever clipping a year in the latter.
    metadataDetails = ""
    issueSummary =
      attention.articleIssueCount > 0
      ? String(localized: "\(attention.articleIssueCount) 项问题") : nil
    var tags = [WorkbenchStatusTagKind(state: draft.articleState)]
    if attention.needsSync { tags.append(.unsynced) }
    if attention.articleIssueCount > 0 { tags.append(.alerts(attention.articleIssueCount)) }
    if draft.status == .failed { tags.append(.publishFailed) }
    statusTags = tags
    metadataDate = writingDraftListDateText(draft.metadataUpdatedAt)
    metadata = [metadataDetails, metadataDate].filter { !$0.isEmpty }.joined(separator: " · ")
    privacySystemImage =
      draft.isPrivate
      ? (display.isMasked ? "lock.shield.fill" : "lock.fill") : nil
    metadataSymbolRole =
      draft.status == .failed
      ? .failed
      : attention.articleIssueCount > 0
        ? .warning
        : attention.needsSync ? .warning : .neutral
    let summaryTags = Array(tags.reversed())
    statusSummary = (summaryTags.map(\.title) + [metadataDetails])
      .filter { !$0.isEmpty }.joined(separator: " · ")
    help = [
      title,
      draft.articleState.workbenchLocalizedDisplayName,
      draft.isPrivate ? draft.visibility.localizedDisplayName : nil,
      draft.status == .failed ? String(localized: "发布失败") : nil,
      attention.needsSync ? String(localized: "同步异常") : nil,
      issueSummary,
      metadata,
      "\(draft.wordCount) \(String(localized: "字/词"))",
      writingDraftRowHelp(draft: draft, profile: profile, display: display),
    ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

/// Recency sections for a list ordered by update time. Groups follow the
/// order of the input, so an oldest-first list simply shows them reversed.
enum WritingDraftRecencyGroup: String, Hashable {
  /// Timestamps after today (clock skew or imported data) are never "today".
  case future
  case today
  case thisWeek
  case earlier

  var title: String {
    switch self {
    case .future: return String(localized: "未来日期")
    case .today: return String(localized: "今天")
    case .thisWeek: return String(localized: "本周")
    case .earlier: return String(localized: "更早")
    }
  }

  init(date: Date, now: Date, calendar: Calendar) {
    let days =
      calendar.dateComponents(
        [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
      ).day ?? .max
    switch days {
    case ..<0: self = .future
    case 0: self = .today
    case 1...6: self = .thisWeek
    default: self = .earlier
    }
  }

  struct Section: Identifiable {
    let group: WritingDraftRecencyGroup
    /// Each row keeps its index in the paginated list for load-more paging.
    let rows: [(index: Int, draft: ArticleDraft)]

    var id: String { group.rawValue }
  }

  static func sections(
    for drafts: [ArticleDraft],
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> [Section] {
    var sections: [Section] = []
    var currentGroup: WritingDraftRecencyGroup?
    var currentRows: [(index: Int, draft: ArticleDraft)] = []
    for (index, draft) in drafts.enumerated() {
      let group = WritingDraftRecencyGroup(
        date: draft.metadataUpdatedAt, now: now, calendar: calendar)
      if group != currentGroup, let previous = currentGroup {
        sections.append(Section(group: previous, rows: currentRows))
        currentRows = []
      }
      currentGroup = group
      currentRows.append((index, draft))
    }
    if let currentGroup {
      sections.append(Section(group: currentGroup, rows: currentRows))
    }
    return sections
  }
}

/// Ordinary row metadata stays neutral; only actionable states draw the eye.
enum WritingDraftRowSymbolRole: Equatable {
  case neutral
  case ready
  case warning
  case failed

  var color: Color {
    switch self {
    case .neutral: return .secondary
    case .ready: return WorkbenchTheme.info
    case .warning: return WorkbenchTheme.warning
    case .failed: return WorkbenchTheme.risk
    }
  }
}

/// Use the shortest useful date in the dense draft list: the time today,
/// "昨天", the weekday within the last week, then the full numeric date.
/// Comparing calendar days (rather than elapsed hours) keeps rows around
/// midnight from being mislabeled.
func writingDraftListDateText(
  _ date: Date,
  now: Date = Date(),
  calendar: Calendar = .current
) -> String {
  if calendar.isDate(date, inSameDayAs: now) {
    return date.formatted(date: .omitted, time: .shortened)
  }
  let startOfDate = calendar.startOfDay(for: date)
  let startOfNow = calendar.startOfDay(for: now)
  let dayDistance = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? .max
  if dayDistance == 1 {
    return String(localized: "昨天")
  }
  if (2...6).contains(dayDistance) {
    var style = Date.FormatStyle.dateTime.weekday(.abbreviated)
    style.calendar = calendar
    style.timeZone = calendar.timeZone
    return date.formatted(style)
  }
  return date.formatted(date: .numeric, time: .omitted)
}

struct WritingDraftRow: View {
  let presentation: WritingDraftRowPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.tight) {
      titleText
      statusAndMetadataLine
    }
    .padding(.vertical, WorkbenchSpacing.tight)
    .help(presentation.help)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(presentation.help)
  }
}

extension WorkbenchStatusTagKind {
  fileprivate init(state: ArticleState) {
    switch state {
    case .draft: self = .draft
    case .ready: self = .ready
    case .published: self = .published
    case .localOnly: self = .localOnly
    }
  }
}

extension WritingDraftRow {
  private var statusAndMetadataLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.icon) {
      if let privacySystemImage = presentation.privacySystemImage {
        Image(systemName: privacySystemImage)
          .foregroundStyle(.workbenchSecondary)
          .accessibilityHidden(true)
      }
      Text(presentation.statusSummary)
        .font(.workbenchMetadata)
        .foregroundStyle(presentation.metadataSymbolRole.color)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      dateText
        .layoutPriority(1)
    }
  }

  private var titleText: some View {
    Text(presentation.title)
      .font(.workbenchBody.weight(.medium))
      .workbenchTruncatedIdentity(
        presentation.title,
        lineLimit: 2,
        truncationMode: .tail
      )
  }

  private var dateText: some View {
    Text(presentation.metadataDate)
      .font(.workbenchMetadata.monospacedDigit())
      .foregroundStyle(.workbenchSecondary)
      .fixedSize(horizontal: true, vertical: false)
  }
}

struct WritingDraftSkeletonRow: View {
  var body: some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.badge, style: .continuous)
        .fill(Color.secondary.opacity(0.18))
        .frame(width: 16, height: 16)

      VStack(alignment: .leading, spacing: 2) {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.badge, style: .continuous)
          .fill(Color.secondary.opacity(0.22))
          .frame(width: 120, height: 14)

        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.badge, style: .continuous)
          .fill(Color.secondary.opacity(0.14))
          .frame(width: 180, height: 11)
      }
    }
    .padding(.horizontal, WorkbenchSpacing.tight)
    .padding(.vertical, WorkbenchSpacing.tight)
    .accessibilityHidden(true)
  }
}
