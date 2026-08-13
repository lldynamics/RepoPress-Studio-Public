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
/// The body is intentionally absent. Draft body edits already advance
/// `updatedAt` through the normal update path, which lets the list notice a
/// changed writing-unit count without hashing or scanning the body for every
/// row when an unrelated draft changes.
struct WritingDraftRowPresentationCacheKey: Hashable {
  let updatedAt: Date
  let title: String
  let status: DraftStatus
  let isGeneralDraft: Bool
  let isPrivate: Bool
  let visibility: ArticleVisibility
  let isMasked: Bool
  let help: String

  init(draft: ArticleDraft, profile: SiteProfile, display: PrivateContentDisplay) {
    updatedAt = draft.updatedAt
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
  display.isMasked
    ? display.summary
    : draft.isGeneralDraft
      ? String(localized: "通用草稿，不绑定站点")
      : profile.markdownPath(for: draft)
}

struct WritingDraftRowPresentation {
  let draft: ArticleDraft
  let title: String
  let metadata: String
  let leadingSystemImage: String
  let help: String

  init(draft: ArticleDraft, profile: SiteProfile, display: PrivateContentDisplay) {
    self.draft = draft
    title = display.title.nilIfEmpty ?? String(localized: "未命名文章")
    let writingUnitCount =
      MarkdownWritingStatisticsService
      .statistics(in: draft.bodyMarkdown)
      .writingUnitCount
    var metadataParts = [
      draft.updatedAt.workbenchShortText,
      "\(writingUnitCount) \(String(localized: "字/词"))",
      draft.status.localizedDisplayName,
    ]
    if draft.isGeneralDraft {
      metadataParts.append(String(localized: "通用草稿"))
    }
    if draft.isPrivate {
      metadataParts.append(draft.visibility.localizedDisplayName)
    }
    metadata = metadataParts.joined(separator: " · ")
    if draft.isPrivate {
      leadingSystemImage = display.isMasked ? "lock.shield.fill" : "lock.fill"
    } else {
      leadingSystemImage = draft.status.systemImage
    }
    help = writingDraftRowHelp(draft: draft, profile: profile, display: display)
  }
}

struct WritingDraftRow: View {
  let presentation: WritingDraftRowPresentation

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: presentation.leadingSystemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 4) {
        Text(presentation.title)
          .font(.workbenchBody.weight(.medium))
          .workbenchTruncatedIdentity(presentation.title)

        Text(presentation.metadata)
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .lineLimit(1)
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
      Circle()
        .frame(width: 16, height: 16)

      VStack(alignment: .leading, spacing: 4) {
        Text("标题占位")
          .font(.workbenchBody.weight(.medium))
          .lineLimit(1)

        Text("上次修改占位 · 0000 字/词 · 发布中")
          .font(.workbenchSupporting)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 5)
    .redacted(reason: .placeholder)
    .foregroundStyle(.secondary)
  }
}
