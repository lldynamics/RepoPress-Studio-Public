import PublishingDomainContracts
import PublishingWorkbenchCore
import SwiftUI

enum DraftListFilter: String, CaseIterable, Identifiable {
  case all
  case draft
  case checkFailed
  case ready
  case published
  case privateArticles

  var id: String { rawValue }

  static let primaryFilters: [DraftListFilter] = [.all, .draft, .ready]
  static let overflowFilters: [DraftListFilter] = [.privateArticles, .checkFailed, .published]

  var displayName: String {
    switch self {
    case .all:
      return "全部任务"
    case .draft:
      return "待写作"
    case .checkFailed:
      return "检查失败"
    case .ready:
      return "待发布"
    case .published:
      return "已上线"
    case .privateArticles:
      return "私密文章"
    }
  }

  var requiresTaskQueueState: Bool {
    switch self {
    case .checkFailed:
      return true
    case .all, .draft, .ready, .published, .privateArticles:
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
      return draft.status == .draft
    case .checkFailed:
      return taskState?.hasPreflightErrors == true
    case .ready:
      return draft.status == .ready
    case .published:
      return draft.status == .published
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
struct WritingDraftRowPresentationCacheKey: Hashable {
  let metadataUpdatedAt: Date
  let wordCount: Int
  let title: String
  let status: DraftStatus
  let isGeneralDraft: Bool
  let isPrivate: Bool
  let visibility: ArticleVisibility
  let isMasked: Bool
  let help: String

  init(draft: ArticleDraft, profile: SiteProfile, display: PrivateContentDisplay) {
    metadataUpdatedAt = draft.metadataUpdatedAt
    wordCount = draft.wordCount
    title = display.title
    status = draft.status
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
  if let source = draft.externalDraftSource {
    if source.isDetached {
      return String(localized: "已断开的外部文件：\(source.relativePath)")
    }
    return String(localized: "外部文件：\(source.relativePath)")
  }
  return draft.isGeneralDraft
    ? String(localized: "通用草稿，不绑定站点")
    : profile.markdownPath(for: draft)
}

/// Rows use two lines — title, then status and facts — so a default window
/// shows substantially more articles than the former three-line layout.
struct WritingDraftRowPresentation {
  let title: String
  let metadata: String
  let leadingSystemImage: String
  let help: String

  init(draft: ArticleDraft, profile: SiteProfile, display: PrivateContentDisplay) {
    title = display.title.nilIfEmpty ?? String(localized: "未命名文章")
    // The list scope already says whether rows are general drafts, so only
    // status, privacy and the facts that differ per row are repeated here.
    var parts = [draft.status.localizedDisplayName]
    if draft.isPrivate { parts.append(draft.visibility.localizedDisplayName) }
    if let source = draft.externalDraftSource {
      parts.append(
        source.isDetached
          ? String(localized: "外部文件（已断开）") : String(localized: "外部文件"))
    }
    parts.append(writingDraftListDateText(draft.metadataUpdatedAt))
    metadata = parts.joined(separator: " · ")
    if draft.isPrivate {
      leadingSystemImage = display.isMasked ? "lock.shield.fill" : "lock.fill"
    } else {
      leadingSystemImage = draft.status.systemImage
    }
    help = [
      title,
      metadata,
      "\(draft.wordCount) \(String(localized: "字/词"))",
      writingDraftRowHelp(draft: draft, profile: profile, display: display),
    ].joined(separator: " · ")
  }
}

/// Use the shortest useful date in the dense draft list. Comparing calendar
/// days (rather than elapsed hours) keeps rows around midnight from being
/// mislabeled as "today".
func writingDraftListDateText(
  _ date: Date,
  now: Date = Date(),
  calendar: Calendar = .current
) -> String {
  if calendar.isDate(date, inSameDayAs: now) {
    return date.formatted(date: .omitted, time: .shortened)
  }
  return date.formatted(date: .numeric, time: .omitted)
}

struct WritingDraftRow: View {
  let presentation: WritingDraftRowPresentation

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: presentation.leadingSystemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 3) {
        Text(presentation.title)
          .font(.workbenchBody.weight(.medium))
          .workbenchTruncatedIdentity(
            presentation.title,
            lineLimit: 2,
            truncationMode: .tail
          )

        Text(presentation.metadata)
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .accessibilityLabel(presentation.help)
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 5)
    .help(presentation.help)
  }
}

struct WritingDraftSkeletonRow: View {
  var body: some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(Color.secondary.opacity(0.18))
        .frame(width: 16, height: 16)

      VStack(alignment: .leading, spacing: 6) {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(Color.secondary.opacity(0.22))
          .frame(width: 120, height: 14)

        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(Color.secondary.opacity(0.14))
          .frame(width: 180, height: 11)
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 5)
    .accessibilityHidden(true)
  }
}
