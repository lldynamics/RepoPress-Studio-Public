import PublishingWorkbenchCore
import SwiftUI

struct ContentHealthDetailView: View {
  @ObservedObject var store: WorkbenchStore
  let filter: ContentHealthContextFilter
  @State private var isMaintenanceReportLoaded = false
  @State private var healthSnapshot: ContentHealthSnapshot?
  @State private var severityFilter: ContentHealthSeverityFilter = .all
  @State private var selectedDraftID: UUID?
  @State private var healthSnapshotTask: Task<Void, Never>?

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
    .onChange(of: filter) { _, _ in
      selectedDraftID = nil
    }
    .onChange(of: severityFilter) { _, _ in
      selectedDraftID = nil
    }
    .onDisappear {
      healthSnapshotTask?.cancel()
      healthSnapshotTask = nil
    }
  }

  private func content(_ snapshot: ContentHealthSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("内容健康")
            .font(.title2.weight(.semibold))
          Text("\(snapshot.profileName) · 一次扫描派生总览、文章分组与问题详情")
            .foregroundStyle(.secondary)
        }
        Spacer()
      }

      HStack(spacing: 12) {
        Picker("严重级别", selection: $severityFilter) {
          ForEach(ContentHealthSeverityFilter.allCases) { severity in
            Text(severity.title).tag(severity)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 280)
        .accessibilityLabel("严重级别筛选")

        Spacer(minLength: 0)
        recommendedAction(snapshot)
      }

      LazyVGrid(
        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
        spacing: 12
      ) {
        MetricTile(title: "错误", value: "\(snapshot.errorCount)", semantic: .blocking)
        MetricTile(title: "警告", value: "\(snapshot.warningCount)", semantic: .warning)
        MetricTile(title: "AI 可修复", value: "\(snapshot.aiFixQueueItems.count)", systemImage: "sparkles", tint: WorkbenchTheme.inventory)
        MetricTile(title: "通过文章", value: "\(snapshot.passingDraftCount)", semantic: .passed)
      }

      filteredSections(snapshot)
    }
    .padding(20)
  }

  @ViewBuilder
  private func filteredSections(_ snapshot: ContentHealthSnapshot) -> some View {
    switch filter {
    case .overview:
      healthOverview(snapshot)
      articleHealthFlow(snapshot)
    case .publicRisks:
      articleHealthFlow(snapshot)
    case .aiFixes:
      articleHealthFlow(snapshot)
    case .siteIssues:
      siteIssuesSection(snapshot)
    case .maintenance:
      maintenanceReportSection
    case .draftIssues:
      articleHealthFlow(snapshot)
    }
  }

  private func refreshContentHealthSnapshotIfNeeded() {
    guard healthSnapshot == nil else { return }
    refreshContentHealthSnapshot()
  }

  private func refreshContentHealthSnapshot() {
    healthSnapshotTask?.cancel()
    let expectedVersion = store.contentHealthSnapshotVersion
    healthSnapshotTask = Task { @MainActor in
      let snapshot = await ContentHealthSnapshot.make(store: store)
      guard !Task.isCancelled, store.contentHealthSnapshotVersion == expectedVersion else { return }
      healthSnapshot = snapshot
    }
  }

  private func healthOverview(_ snapshot: ContentHealthSnapshot) -> some View {
    HStack(spacing: 12) {
      Label("站点问题 \(snapshot.sitePreflightIssues.count)", systemImage: "building.2")
      Label("公开风险 \(snapshot.publicRiskSummary.issueCount)", systemImage: "lock.shield")
      Label("待 AI 修复 \(snapshot.aiFixQueueItems.count)", systemImage: "sparkles")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 4)
  }

  @ViewBuilder
  private func recommendedAction(_ snapshot: ContentHealthSnapshot) -> some View {
    if let item = recommendedAIFixItem(in: snapshot) {
      Button {
        runAIFixQueueItem(item)
      } label: {
        Label("推荐：用 AI 修复 \(item.draftTitle)", systemImage: item.recommendedAction.promptLibrarySystemImage)
          .lineLimit(1)
      }
      .disabled(store.ai.isActionRunning)
    } else if let summary = filteredDraftSummaries(in: snapshot).first {
      Button {
        _ = store.focusDraft(summary.draftID, section: .writing)
      } label: {
        Label("推荐：处理 \(summary.draftTitle)", systemImage: "arrow.right.circle")
          .lineLimit(1)
      }
    } else {
      Button {
        store.runPreflight()
      } label: {
        Label("重新检查", systemImage: "arrow.clockwise")
      }
    }
  }

  private func articleHealthFlow(_ snapshot: ContentHealthSnapshot) -> some View {
    let summaries = filteredDraftSummaries(in: snapshot)

    return VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("文章分组")
          .font(.headline)
        Spacer()
        Text("\(summaries.count) 篇")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if summaries.isEmpty {
        Label("当前筛选下没有待处理的文章问题。", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
          .padding(.vertical, 12)
      } else {
        ForEach(summaries) { summary in
          Button {
            selectedDraftID = summary.draftID
          } label: {
            articleSummaryRow(summary, isSelected: selectedSummary(in: snapshot)?.draftID == summary.draftID)
          }
          .buttonStyle(.plain)
        }
      }

      articleIssueDetails(in: snapshot)
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func articleSummaryRow(_ summary: DraftPreflightSummary, isSelected: Bool) -> some View {
    let issues = matchingIssues(for: summary)
    let errorCount = issues.filter { $0.severity == .error }.count
    let warningCount = issues.filter { $0.severity == .warning }.count

    return HStack(alignment: .firstTextBaseline, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(summary.draftTitle)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        Text(summary.markdownPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 12)

      Label("\(errorCount)", systemImage: "xmark.octagon")
        .foregroundStyle(errorCount > 0 ? .red : .secondary)
      Label("\(warningCount)", systemImage: "exclamationmark.triangle")
        .foregroundStyle(warningCount > 0 ? .orange : .secondary)
      if isSelected {
        Image(systemName: "chevron.right")
          .foregroundStyle(WorkbenchTheme.primary)
          .font(.caption.weight(.semibold))
      } else {
        Image(systemName: "chevron.right")
          .foregroundStyle(.tertiary)
          .font(.caption.weight(.semibold))
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        .fill(isSelected ? AnyShapeStyle(WorkbenchTheme.primary.opacity(WorkbenchOpacity.accentBackground)) : WorkbenchBackgroundStyle.subtle)
    }
  }

  @ViewBuilder
  private func articleIssueDetails(in snapshot: ContentHealthSnapshot) -> some View {
    if let summary = selectedSummary(in: snapshot) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("问题详情")
            .font(.headline)
          Spacer()
          Text(summary.draftTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        ForEach(matchingIssues(for: summary)) { issue in
          ContentHealthIssueCard(issue: issue)
        }
      }
      .padding(.top, 6)
    }
  }

  private func filteredDraftSummaries(in snapshot: ContentHealthSnapshot) -> [DraftPreflightSummary] {
    let aiFixDraftIDs = Set(snapshot.aiFixQueueItems.map(\.draftID))
    let summaries: [DraftPreflightSummary]
    switch filter {
    case .overview, .draftIssues:
      summaries = snapshot.contentHealthSummaries
    case .publicRisks:
      summaries = snapshot.contentHealthSummaries.filter { !$0.publicRiskIssues.isEmpty }
    case .aiFixes:
      summaries = snapshot.contentHealthSummaries.filter { aiFixDraftIDs.contains($0.draftID) }
    case .siteIssues, .maintenance:
      summaries = []
    }
    return summaries.filter { !matchingIssues(for: $0).isEmpty }
  }

  private func selectedSummary(in snapshot: ContentHealthSnapshot) -> DraftPreflightSummary? {
    let summaries = filteredDraftSummaries(in: snapshot)
    return summaries.first { $0.draftID == selectedDraftID } ?? summaries.first
  }

  private func matchingIssues(for summary: DraftPreflightSummary) -> [PreflightIssue] {
    let issues: [PreflightIssue]
    switch filter {
    case .publicRisks:
      issues = summary.publicRiskIssues
    case .overview, .aiFixes, .draftIssues, .siteIssues, .maintenance:
      issues = summary.blockingIssues
    }
    return severityFilter.filter(issues)
  }

  private func recommendedAIFixItem(in snapshot: ContentHealthSnapshot) -> AIPublishingFixQueueItem? {
    let visibleDraftIDs = Set(filteredDraftSummaries(in: snapshot).map(\.draftID))
    return snapshot.aiFixQueueItems.first { visibleDraftIDs.contains($0.draftID) }
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

}

private enum ContentHealthSeverityFilter: String, CaseIterable, Identifiable {
  case all
  case errors
  case warnings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all:
      return "全部"
    case .errors:
      return "错误"
    case .warnings:
      return "警告"
    }
  }

  func filter(_ issues: [PreflightIssue]) -> [PreflightIssue] {
    switch self {
    case .all:
      return issues
    case .errors:
      return issues.filter { $0.severity == .error }
    case .warnings:
      return issues.filter { $0.severity == .warning }
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
  static func make(store: WorkbenchStore) async -> ContentHealthSnapshot {
    let profileName = store.activeProfile.name
    let visibleDraftCount = store.visibleDrafts.count
    let report = await store.contentHealthReportAsync()
    return ContentHealthSnapshot(
      profileName: profileName,
      visibleDraftCount: visibleDraftCount,
      publicRiskSummary: report.publicRiskSummary,
      publicRiskDraftSummaries: report.publicRiskDraftSummaries,
      aiFixQueueItems: report.aiFixQueueItems,
      sitePreflightIssues: report.sitePreflightIssues,
      contentHealthSummaries: report.draftSummaries
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
