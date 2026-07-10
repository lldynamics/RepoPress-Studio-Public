import PublishingWorkbenchCore
import SwiftUI

struct ContentHealthDetailView: View {
  @ObservedObject var store: WorkbenchStore
  @State private var isMaintenanceReportLoaded = false
  @State private var healthSnapshot: ContentHealthSnapshot?

  var body: some View {
    ScrollView {
      if let snapshot = healthSnapshot {
        content(snapshot)
      } else {
        EmptyStateView(
          title: "正在准备检查快照",
          message: "内容健康页会先生成一次快照，再渲染公开风险、AI 修复队列和文章级问题。",
          systemImage: "checklist"
        )
        .frame(maxWidth: .infinity, minHeight: 360)
        .padding(20)
      }
    }
    .task {
      refreshContentHealthSnapshotIfNeeded()
    }
    .onChange(of: store.contentHealthSnapshotVersion) { _, _ in
      refreshContentHealthSnapshot()
    }
  }

  private func content(_ snapshot: ContentHealthSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("全站发布检查")
            .font(.title2.weight(.semibold))
          Text("\(snapshot.profileName) · \(snapshot.visibleDraftCount) 篇草稿")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          store.runPreflight()
        } label: {
          Label("重新检查", systemImage: "checklist")
        }
      }

      LazyVGrid(
        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
        spacing: 12
      ) {
        MetricTile(title: "错误", value: "\(snapshot.errorCount)", semantic: .blocking)
        MetricTile(title: "警告", value: "\(snapshot.warningCount)", semantic: .warning)
        MetricTile(title: "AI 可修复", value: "\(snapshot.aiFixQueueItems.count)", systemImage: "sparkles", tint: .purple)
        MetricTile(title: "通过文章", value: "\(snapshot.passingDraftCount)", semantic: .passed)
      }

      publicRiskSection(snapshot)
      aiFixQueueSection(snapshot)
      siteIssuesSection(snapshot)
      maintenanceReportSection
      draftIssuesSection(snapshot)
    }
    .padding(20)
  }

  private func refreshContentHealthSnapshotIfNeeded() {
    guard healthSnapshot == nil else { return }
    refreshContentHealthSnapshot()
  }

  private func refreshContentHealthSnapshot() {
    healthSnapshot = ContentHealthSnapshot.make(store: store)
  }

  private func publicRiskSection(_ snapshot: ContentHealthSnapshot) -> some View {
    let riskSummary = snapshot.publicRiskSummary

    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("公开风险")
          .font(.headline)
        Spacer()
        Text(riskSummary.statusTitle)
          .font(.caption)
          .foregroundStyle(riskSummary.isClear ? Color.secondary : (riskSummary.errorCount > 0 ? Color.red : Color.orange))
      }

      if riskSummary.isClear {
        Label(riskSummary.statusMessage, systemImage: "lock.open")
          .foregroundStyle(.secondary)
      } else {
        Text(riskSummary.statusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)

        ForEach(snapshot.publicRiskDraftSummaries.prefix(6)) { summary in
          Button {
            store.selectDraft(summary.draftID)
            store.selectSection(.writing)
          } label: {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(summary.draftTitle)
                  .font(.callout.weight(.medium))
                  .lineLimit(1)
                Spacer()
                Label("\(summary.publicRiskErrorCount)", systemImage: "xmark.octagon")
                  .foregroundStyle(summary.publicRiskErrorCount > 0 ? .red : .secondary)
                Label("\(summary.publicRiskWarningCount)", systemImage: "exclamationmark.triangle")
                  .foregroundStyle(summary.publicRiskWarningCount > 0 ? .orange : .secondary)
              }

              Text(summary.markdownPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

              ForEach(summary.publicRiskIssues.prefix(2)) { issue in
                Text("\(issue.severity.displayName) · \(issue.title)")
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func aiFixQueueSection(_ snapshot: ContentHealthSnapshot) -> some View {
    let items = snapshot.aiFixQueueItems

    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("AI 修复队列")
          .font(.headline)
        Spacer()
        Text("\(items.count) 篇")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if items.isEmpty {
        Label("没有发现适合 AI 批量处理的摘要、Tags 或 Front Matter 问题。", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      } else {
        Text("按手机版的 AI 修复队列逻辑，优先处理缺摘要、缺 Tags 和可由 AI 辅助判断的元数据问题。")
          .font(.caption)
          .foregroundStyle(.secondary)

        ForEach(items.prefix(6)) { item in
          aiFixQueueRow(item)
        }
      }

      if let message = store.ai.actionMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func aiFixQueueRow(_ item: AIPublishingFixQueueItem) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "sparkles")
        .foregroundStyle(aiFixQueuePriorityColor(item.priority))
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(item.draftTitle)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
          Text(item.priority.displayName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(aiFixQueuePriorityColor(item.priority))
        }

        Text(item.markdownPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Text("\(item.requestSummary) · 建议动作：\(item.recommendedAction.displayName)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)

        if !item.issueTitles.isEmpty {
          Text(item.issueTitles.joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 12)

      VStack(spacing: 6) {
        Button {
          store.selectDraft(item.draftID)
          store.selectSection(.writing)
        } label: {
          Label("定位", systemImage: "arrow.right.circle")
        }

        Button {
          runAIFixQueueItem(item)
        } label: {
          Label("用 AI 修复", systemImage: item.recommendedAction.promptLibrarySystemImage)
        }
        .disabled(store.ai.isActionRunning)
      }
      .controlSize(.small)
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func runAIFixQueueItem(_ item: AIPublishingFixQueueItem) {
    guard let draft = store.publishing.visibleDrafts.first(where: { $0.id == item.draftID }) else {
      return
    }
    store.publishing.selectDraft(item.draftID)
    Task {
      await store.ai.performAction(item.recommendedAction, draft: draft)
    }
  }

  private func aiFixQueuePriorityColor(_ priority: AIPublishingFixQueuePriority) -> Color {
    switch priority {
    case .high:
      return .red
    case .medium:
      return .orange
    case .low:
      return .secondary
    }
  }

  private func siteIssuesSection(_ snapshot: ContentHealthSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("站点级问题")
          .font(.headline)
        Spacer()
        Text("\(snapshot.sitePreflightIssues.count) 项")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if snapshot.sitePreflightIssues.isEmpty {
        Label("站点路径和仓库状态没有阻塞问题。", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      } else {
        ForEach(snapshot.sitePreflightIssues) { issue in
          ContentHealthIssueCard(issue: issue)
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private var maintenanceReportSection: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 10) {
        if isMaintenanceReportLoaded {
          SiteMaintenanceDetailView(store: store, isEmbedded: true)
        } else {
          Text("维护报告包含内容日历、标签治理、旧文整理、内链机会和链接审计。为避免打开健康页时立即重算，点击后再加载详情。")
            .font(.caption)
            .foregroundStyle(.secondary)

          Button {
            if store.siteMaintenanceSnapshot == nil {
              store.refreshSiteMaintenanceSnapshot()
            }
            isMaintenanceReportLoaded = true
          } label: {
            Label(store.siteMaintenanceSnapshot == nil ? "生成并加载维护报告" : "加载维护报告", systemImage: "arrow.clockwise")
          }
        }
      }
      .padding(.top, 8)
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        Label("定期维护报告", systemImage: WorkspaceSection.maintenance.systemImage)
          .font(.headline)
        Text("内容日历、标签治理、旧文整理、内链机会和链接提示已并入全站检查，作为低频治理报告查看。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func draftIssuesSection(_ snapshot: ContentHealthSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("文章级问题")
          .font(.headline)
        Spacer()
        Text("\(snapshot.contentHealthSummaries.count) 篇")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if snapshot.contentHealthSummaries.isEmpty {
        EmptyStateView(
          title: "当前 Profile 没有草稿",
          message: "新建文章后，这里会按文章聚合 Front Matter、正文、图片和发布路径问题。",
          systemImage: "doc.badge.plus"
        )
        .frame(height: 220)
      } else {
        ForEach(snapshot.contentHealthSummaries) { summary in
          VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
              VStack(alignment: .leading, spacing: 4) {
                Text(summary.draftTitle)
                  .font(.headline)
                Text(summary.markdownPath)
                  .font(.callout.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer()
              Button {
                store.selectDraft(summary.draftID)
                store.selectSection(.writing)
              } label: {
                Label("定位", systemImage: "arrow.right.circle")
              }
            }

            HStack(spacing: 10) {
              Label("\(summary.errorCount) 错误", systemImage: "xmark.octagon")
                .foregroundStyle(summary.errorCount > 0 ? .red : .secondary)
              Label("\(summary.warningCount) 警告", systemImage: "exclamationmark.triangle")
                .foregroundStyle(summary.warningCount > 0 ? .orange : .secondary)
            }
            .font(.caption)

            ForEach(summary.blockingIssues.prefix(5)) { issue in
              ContentHealthIssueCard(issue: issue)
            }

            if summary.blockingIssues.isEmpty {
              Label("检查通过", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(14)
          .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
        }
      }
    }
  }
}

private struct ContentHealthSnapshot {
  var profileName: String
  var visibleDraftCount: Int
  var publicRiskSummary: PublicRiskSummary
  var publicRiskDraftSummaries: [DraftPreflightSummary]
  var aiFixQueueItems: [AIPublishingFixQueueItem]
  var sitePreflightIssues: [PreflightIssue]
  var contentHealthSummaries: [DraftPreflightSummary]

  var errorCount: Int {
    sitePreflightIssues.filter { $0.severity == .error }.count
      + contentHealthSummaries.reduce(0) { $0 + $1.errorCount }
  }

  var warningCount: Int {
    sitePreflightIssues.filter { $0.severity == .warning }.count
      + contentHealthSummaries.reduce(0) { $0 + $1.warningCount }
  }

  var passingDraftCount: Int {
    contentHealthSummaries.filter(\.isPassing).count
  }

  @MainActor
  static func make(store: WorkbenchStore) -> ContentHealthSnapshot {
    ContentHealthSnapshot(
      profileName: store.activeProfile.name,
      visibleDraftCount: store.visibleDrafts.count,
      publicRiskSummary: store.publicRiskSummary,
      publicRiskDraftSummaries: store.publicRiskDraftSummaries,
      aiFixQueueItems: store.aiFixQueueItems,
      sitePreflightIssues: store.sitePreflightIssues,
      contentHealthSummaries: store.contentHealthSummaries
    )
  }
}

private struct ContentHealthIssueCard: View {
  let issue: PreflightIssue

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      SeverityBadge(severity: issue.severity)
      Text(issue.title)
        .font(.callout.weight(.medium))
      Text(issue.message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
