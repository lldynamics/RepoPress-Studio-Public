import PublishingWorkbenchCore
import SwiftUI

extension ContentHealthDetailView {
  func articleSummaryRow(
    _ row: ContentHealthArticleRowModel,
    isSelected: Bool,
    hasDuplicatePath: Bool
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        articleRowIdentity(row)
          .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
        Spacer(minLength: 12)
        articleRowBadges(
          row,
          isSelected: isSelected,
          hasDuplicatePath: hasDuplicatePath
        )
        .fixedSize(horizontal: true, vertical: false)
      }

      VStack(alignment: .leading, spacing: 8) {
        articleRowIdentity(row)
        articleRowBadges(
          row,
          isSelected: isSelected,
          hasDuplicatePath: hasDuplicatePath
        )
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        .fill(
          isSelected
            ? AnyShapeStyle(
              WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.selectionBackground))
            : WorkbenchBackgroundStyle.subtle
        )
    }
  }

  private func articleRowIdentity(
    _ row: ContentHealthArticleRowModel
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(row.draftTitle)
        .font(.workbenchItemTitle)
        .workbenchTruncatedIdentity(row.draftTitle)
      Text(row.markdownPath)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .workbenchTruncatedIdentity(row.markdownPath)
    }
  }

  private func articleRowBadges(
    _ row: ContentHealthArticleRowModel,
    isSelected: Bool,
    hasDuplicatePath: Bool
  ) -> some View {
    HStack(spacing: 8) {
      healthIssueCountBadge(
        count: row.errorCount,
        systemImage: "xmark.octagon",
        color: WorkbenchTheme.risk,
        label: "错误"
      )
      if hasDuplicatePath {
        Label("路径重复", systemImage: "arrow.triangle.branch")
          .font(.caption.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.warning)
          .help("多篇文章映射到了同一仓库路径")
      }
      healthIssueCountBadge(
        count: row.warningCount,
        systemImage: "exclamationmark.triangle",
        color: WorkbenchTheme.warning,
        label: "警告"
      )
      if row.aiFixItem != nil {
        Label("AI", systemImage: "sparkles")
          .font(.caption.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.inventoryForeground)
          .help(String(localized: "可使用 AI 协助修复"))
      }
      if isSelected {
        Image(systemName: "sidebar.right")
          .foregroundStyle(WorkbenchTheme.navigationSelection)
          .font(.caption.weight(.semibold))
          .accessibilityHidden(true)
      }
    }
  }

  private func healthIssueCountBadge(
    count: Int,
    systemImage: String,
    color: Color,
    label: LocalizedStringKey
  ) -> some View {
    Label("\(count)", systemImage: systemImage)
      .font(.caption.weight(.semibold))
      .monospacedDigit()
      .foregroundStyle(count > 0 ? color : Color.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .background(
        count > 0
          ? AnyShapeStyle(color.opacity(WorkbenchOpacity.noticeBackground))
          : WorkbenchBackgroundStyle.control,
        in: Capsule()
      )
      .accessibilityLabel(label)
      .accessibilityValue("\(count)")
  }

  func runAIFixQueueItem(_ item: AIPublishingFixQueueItem) {
    guard let draft = store.publishing.visibleDrafts.first(where: { $0.id == item.draftID }) else {
      return
    }
    store.publishing.selectDraft(item.draftID)
    Task {
      guard let result = await store.ai.performAction(item.recommendedAction, draft: draft) else {
        return
      }
      aiFixResultPreview = ContentHealthAIFixResultPreview(
        draftTitle: draft.title.nilIfEmpty ?? String(localized: "未命名文章"),
        result: result
      )
    }
  }

  func contentHealthSummaryAccessibilityValue(
    _ snapshot: ContentHealthSnapshot
  ) -> String {
    var parts = [
      "\(snapshot.errorCount) 个错误",
      "\(snapshot.warningCount) 个警告",
    ]
    parts.append("\(snapshot.aiFixQueueItems.count) 项可用 AI 修复")
    parts.append("\(snapshot.passingDraftCount) 篇文章通过")
    return parts.joined(separator: "，")
  }

  func siteIssuesSection(_ issues: [PreflightIssue]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("站点级问题")
          .font(.headline)
        Spacer()
        Text("\(issues.count) 项")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if issues.isEmpty {
        Label("站点路径和仓库状态没有阻塞问题。", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      } else {
        ForEach(issues) { issue in
          ContentHealthIssueCard(issue: issue)
        }
      }
    }
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}
