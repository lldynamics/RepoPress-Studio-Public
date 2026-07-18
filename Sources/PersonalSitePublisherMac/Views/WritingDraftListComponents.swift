import PublishingWorkbenchCore
import SwiftUI

enum DraftListFilter: String, CaseIterable, Identifiable {
  case all
  case draft
  case checkFailed
  case ready
  case published
  case privateArticles
  case imageIssues

  var id: String { rawValue }

  static let primaryFilters: [DraftListFilter] = [.all, .draft, .ready]
  static let overflowFilters: [DraftListFilter] = [.privateArticles, .checkFailed, .published, .imageIssues]

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
    case .imageIssues:
      return "有图片问题"
    }
  }

  var requiresTaskQueueState: Bool {
    switch self {
    case .checkFailed, .imageIssues:
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
    case .imageIssues:
      return taskState?.hasImageIssues == true
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
    drafts.sorted { lhs, rhs in
      switch self {
      case .updatedNewest:
        return ordered(lhs, rhs, date: \ArticleDraft.updatedAt, newestFirst: true)
      case .updatedOldest:
        return ordered(lhs, rhs, date: \ArticleDraft.updatedAt, newestFirst: false)
      case .articleDateNewest:
        return ordered(lhs, rhs, date: \ArticleDraft.date, newestFirst: true)
      case .articleDateOldest:
        return ordered(lhs, rhs, date: \ArticleDraft.date, newestFirst: false)
      case .titleAscending:
        return orderedByTitle(lhs, rhs, ascending: true)
      case .titleDescending:
        return orderedByTitle(lhs, rhs, ascending: false)
      }
    }
  }

  private func ordered(
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

  private func orderedByTitle(
    _ lhs: ArticleDraft,
    _ rhs: ArticleDraft,
    ascending: Bool
  ) -> Bool {
    let comparison = lhs.title.localizedStandardCompare(rhs.title)
    guard comparison != .orderedSame else {
      if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
  }

  private func stableTitleOrder(_ lhs: ArticleDraft, _ rhs: ArticleDraft) -> Bool {
    let comparison = lhs.title.localizedStandardCompare(rhs.title)
    guard comparison == .orderedSame else {
      return comparison == .orderedAscending
    }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}

struct WritingDraftRow: View {
  let draft: ArticleDraft
  let profile: SiteProfile
  let display: PrivateContentDisplay

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: leadingSystemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 4) {
        let displayTitle = display.title.nilIfEmpty ?? "未命名文章"
        Text(displayTitle)
          .font(.body.weight(.medium))
          .workbenchTruncatedIdentity(displayTitle)

        metadataText
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 5)
    .help(
      display.isMasked
        ? display.summary
        : draft.isGeneralDraft
          ? String(localized: "通用草稿，不绑定站点")
          : profile.markdownPath(for: draft)
    )
  }

  private var leadingSystemImage: String {
    guard draft.isPrivate else {
      return draft.status.systemImage
    }
    return display.isMasked ? "lock.shield.fill" : "lock.fill"
  }

  private var metadataText: Text {
    let base = Text("\(draft.updatedAt.workbenchShortText) · \(draft.writingUnitCount) 字/词 · \(draft.status.localizedDisplayName)")
    let scoped = draft.isGeneralDraft
      ? base + Text(verbatim: " · ") + Text("通用草稿")
      : base
    guard draft.isPrivate else {
      return scoped
    }
    return scoped + Text(verbatim: " · ") + Text(verbatim: draft.visibility.localizedDisplayName)
  }
}

struct WritingDraftSkeletonRow: View {
  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .frame(width: 16, height: 16)

      VStack(alignment: .leading, spacing: 4) {
        Text("标题占位")
          .font(.body.weight(.medium))
          .lineLimit(1)

        Text("上次修改占位 · 0000 字/词 · 发布中")
          .font(.caption)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 5)
    .redacted(reason: .placeholder)
    .foregroundStyle(.secondary)
  }
}

private extension ArticleDraft {
  var writingUnitCount: Int {
    MarkdownWritingStatisticsService.statistics(in: bodyMarkdown).writingUnitCount
  }
}
