import PublishingWorkbenchCore
import SwiftUI

enum DraftListFilter: String, CaseIterable, Identifiable {
  case all
  case draft
  case checkFailed
  case ready
  case published
  case imageIssues

  var id: String { rawValue }

  static let primaryFilters: [DraftListFilter] = [.all, .draft, .ready]
  static let overflowFilters: [DraftListFilter] = [.checkFailed, .published, .imageIssues]

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
    case .imageIssues:
      return "有图片问题"
    }
  }

  var requiresTaskQueueState: Bool {
    switch self {
    case .checkFailed, .imageIssues:
      return true
    case .all, .draft, .ready, .published:
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
    case .imageIssues:
      return taskState?.hasImageIssues == true
    }
  }
}

enum WritingDraftDensity: String, CaseIterable, Identifiable {
  case compact
  case comfortable

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .compact:
      return "紧凑"
    case .comfortable:
      return "舒适"
    }
  }

  var titleFont: Font {
    switch self {
    case .compact:
      return .callout.weight(.medium)
    case .comfortable:
      return .body.weight(.medium)
    }
  }

  var metadataFont: Font {
    switch self {
    case .compact:
      return .caption2
    case .comfortable:
      return .caption
    }
  }

  var rowSpacing: CGFloat {
    switch self {
    case .compact:
      return 2
    case .comfortable:
      return 4
    }
  }

  var rowVerticalPadding: CGFloat {
    switch self {
    case .compact:
      return 3
    case .comfortable:
      return 5
    }
  }
}

struct WritingDraftRow: View {
  let draft: ArticleDraft
  let profile: SiteProfile
  let display: PrivateContentDisplay
  let density: WritingDraftDensity

  var body: some View {
    VStack(alignment: .leading, spacing: density.rowSpacing) {
      HStack(spacing: 8) {
        Image(systemName: display.isMasked ? "lock.shield" : draft.status.systemImage)
          .foregroundStyle(.secondary)
          .frame(width: 16)

        VStack(alignment: .leading, spacing: 1) {
          Text(display.title)
            .font(density.titleFont)
            .lineLimit(1)

          Text("上次修改：\(draft.updatedAt.workbenchShortText) · \(draft.wordCount) 字 · \(draft.status.localizedDisplayName)")
            .font(density.metadataFont)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }

      if density == .comfortable {
        Text(display.isMasked ? display.summary : profile.markdownPath(for: draft))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, density.rowVerticalPadding)
  }
}

struct WritingDraftSkeletonRow: View {
  let density: WritingDraftDensity

  var body: some View {
    VStack(alignment: .leading, spacing: density.rowSpacing) {
      HStack(spacing: 8) {
        Circle()
          .frame(width: 16, height: 16)

        VStack(alignment: .leading, spacing: 1) {
          Text("标题占位")
            .font(density.titleFont)
            .lineLimit(1)

          Text("上次修改占位 · 0000 字 · 发布中")
            .font(density.metadataFont)
            .lineLimit(1)
        }
      }

      if density == .comfortable {
        Text("路径占位文本内容示例")
          .font(.caption)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, density.rowVerticalPadding)
    .redacted(reason: .placeholder)
    .foregroundStyle(.secondary)
  }
}

private extension ArticleDraft {
  var wordCount: Int {
    bodyMarkdown
      .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
      .filter { !$0.isEmpty }
      .count
  }
}
