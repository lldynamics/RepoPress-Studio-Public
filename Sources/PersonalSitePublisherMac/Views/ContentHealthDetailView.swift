import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct ContentHealthDetailView: View {
  @ObservedObject var store: WorkbenchStore
  let filter: ContentHealthContextFilter
  @State private var healthSnapshot: ContentHealthSnapshot?
  @State private var severityFilter: ContentHealthSeverityFilter = .all
  @State private var issueScope: ContentHealthIssueScopeFilter = .all
  @State private var healthSnapshotTask: Task<Void, Never>?
  @State private var healthSnapshotErrorMessage: String?
  @State private var pageMode: ContentHealthPageMode
  @State private var isHealthSnapshotRefreshing = false
  @State private var healthSnapshotRequestID = UUID()
  @State private var aiFixResultPreview: ContentHealthAIFixResultPreview?

  init(store: WorkbenchStore, filter: ContentHealthContextFilter) {
    self.store = store
    self.filter = filter
    _pageMode = State(initialValue: filter == .maintenance ? .maintenance : .issues)
  }

  var body: some View {
    detailContent
    .task {
      issueScope = ContentHealthIssueScopeFilter(legacyFilter: filter)
      if filter != .maintenance {
        refreshContentHealthSnapshotIfNeeded()
      }
    }
    .onChange(of: store.contentHealthSnapshotVersion) { _, _ in
      refreshContentHealthSnapshot()
    }
    .onChange(of: filter) { _, newFilter in
      pageMode = newFilter == .maintenance ? .maintenance : .issues
      issueScope = ContentHealthIssueScopeFilter(legacyFilter: newFilter)
      if newFilter != .maintenance {
        refreshContentHealthSnapshotIfNeeded()
      }
    }
    .onChange(of: pageMode) { _, newMode in
      if newMode == .issues {
        refreshContentHealthSnapshotIfNeeded()
      }
    }
    .onDisappear {
      healthSnapshotTask?.cancel()
      healthSnapshotTask = nil
      isHealthSnapshotRefreshing = false
    }
    .sheet(item: $aiFixResultPreview) { preview in
      ContentHealthAIFixResultPreviewSheet(preview: preview)
    }
  }

  @ViewBuilder
  private var detailContent: some View {
    ScrollView(.vertical, showsIndicators: true) {
      VStack(alignment: .leading, spacing: 16) {
        pageModePicker
        if pageMode == .maintenance {
          SiteMaintenanceDetailView(store: store, isEmbedded: true)
        } else {
          healthSnapshotContent
        }
      }
      .workbenchPageLayout()
    }
  }

  private var pageModePicker: some View {
    Picker("内容健康页面", selection: $pageMode) {
      ForEach(ContentHealthPageMode.allCases) { mode in
        Label(mode.title, systemImage: mode.systemImage).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: 360)
    .accessibilityLabel("内容健康页面")
  }

  @ViewBuilder
  private var healthSnapshotContent: some View {
    if let snapshot = healthSnapshot {
      content(snapshot)
    } else if let healthSnapshotErrorMessage {
      snapshotFailureState(healthSnapshotErrorMessage)
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

  private func content(_ snapshot: ContentHealthSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("内容健康")
            .font(.title2.weight(.semibold))
          Text("\(snapshot.profileName) · 一次扫描派生总览、文章分组与问题详情")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Label(
          isHealthSnapshotRefreshing
            ? "正在更新"
            : "上次检查 \(snapshot.generatedAt.workbenchShortText)",
          systemImage: isHealthSnapshotRefreshing ? "arrow.clockwise" : "clock"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        healthSummary(snapshot)
      }

      HStack(spacing: 12) {
        Picker("问题类型", selection: $issueScope) {
          ForEach(ContentHealthIssueScopeFilter.allCases) { scope in
            Label(scope.title, systemImage: scope.systemImage).tag(scope)
          }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("问题类型筛选")

        Picker("严重级别", selection: $severityFilter) {
          ForEach(ContentHealthSeverityFilter.allCases) { severity in
            Text(severity.title).tag(severity)
          }
        }
        .pickerStyle(.segmented)
        .tint(WorkbenchTheme.navigationSelection)
        .labelsHidden()
        .frame(maxWidth: 280)
        .accessibilityLabel("严重级别筛选")

        Spacer(minLength: 0)
        recommendedAction(snapshot)
      }

      filteredSections(snapshot)
    }
  }

  @ViewBuilder
  private func filteredSections(_ snapshot: ContentHealthSnapshot) -> some View {
    if issueScope == .siteIssues {
      siteIssuesSection(snapshot)
    } else {
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
    let requestID = UUID()
    healthSnapshotRequestID = requestID
    isHealthSnapshotRefreshing = true
    healthSnapshotErrorMessage = nil
    healthSnapshotTask = Task { @MainActor in
      do {
        let snapshot = try await ContentHealthSnapshot.make(store: store)
        guard !Task.isCancelled,
              healthSnapshotRequestID == requestID,
              store.contentHealthSnapshotVersion == expectedVersion else { return }
        healthSnapshot = snapshot
        healthSnapshotErrorMessage = nil
        isHealthSnapshotRefreshing = false
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled,
              healthSnapshotRequestID == requestID,
              store.contentHealthSnapshotVersion == expectedVersion else { return }
        healthSnapshot = nil
        healthSnapshotErrorMessage = error.localizedDescription
        isHealthSnapshotRefreshing = false
      }
    }
  }

  private func snapshotFailureState(_ errorMessage: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "xmark.octagon")
        .font(.system(size: 38))
        .foregroundStyle(WorkbenchTheme.risk)
        .accessibilityHidden(true)
      Text("无法生成检查快照")
        .font(.headline)
      AccessibleStatusMessage(message: errorMessage, severity: .error)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
      Button(action: refreshContentHealthSnapshot) {
        Label(String(localized: "重试"), systemImage: "arrow.clockwise")
      }
      .workbenchProminentActionStyle()
    }
    .frame(maxWidth: .infinity, minHeight: 360)
    .padding(20)
  }

  private func healthSummary(_ snapshot: ContentHealthSnapshot) -> some View {
    HStack(spacing: 10) {
      Label("错误 \(snapshot.errorCount)", systemImage: "xmark.octagon")
        .foregroundStyle(snapshot.errorCount > 0 ? WorkbenchTheme.risk : Color.secondary)
      Label("警告 \(snapshot.warningCount)", systemImage: "exclamationmark.triangle")
        .foregroundStyle(snapshot.warningCount > 0 ? WorkbenchTheme.warning : Color.secondary)
      Label("AI \(snapshot.aiFixQueueItems.count)", systemImage: "sparkles")
        .foregroundStyle(WorkbenchTheme.inventoryForeground)
      Label("通过 \(snapshot.passingDraftCount)", systemImage: "checkmark.circle")
        .foregroundStyle(WorkbenchTheme.success)
    }
    .font(.callout.weight(.medium))
    .monospacedDigit()
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(
      WorkbenchBackgroundStyle.subtle,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("内容健康摘要")
    .accessibilityValue(
      "\(snapshot.errorCount) 个错误，\(snapshot.warningCount) 个警告，"
        + "\(snapshot.aiFixQueueItems.count) 项可用 AI 修复，\(snapshot.passingDraftCount) 篇文章通过"
    )
  }

  @ViewBuilder
  private func recommendedAction(_ snapshot: ContentHealthSnapshot) -> some View {
    if let item = recommendedAIFixItem(in: snapshot) {
      let recommendationTitle = "推荐：用 AI 修复 \(item.draftTitle)"
      Button {
        runAIFixQueueItem(item)
      } label: {
        Label(recommendationTitle, systemImage: item.recommendedAction.promptLibrarySystemImage)
          .workbenchTruncatedIdentity(recommendationTitle)
      }
      .disabled(store.ai.isActionRunning)
    } else if let summary = filteredDraftSummaries(in: snapshot).first {
      let recommendationTitle = "推荐：处理 \(summary.draftTitle)"
      Button {
        _ = store.focusDraft(summary.draftID, section: .writing)
      } label: {
        Label(recommendationTitle, systemImage: "arrow.right.circle")
          .workbenchTruncatedIdentity(recommendationTitle)
      }
    } else {
      Button {
        refreshContentHealthSnapshot()
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
          let isSelected = store.selectedDraftID == summary.draftID
          Button {
            store.selectDraft(summary.draftID)
            store.setInspectorPresented(true)
          } label: {
            articleSummaryRow(summary, isSelected: isSelected)
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
      }

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
          .workbenchTruncatedIdentity(summary.draftTitle)
        Text(summary.markdownPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(summary.markdownPath)
      }

      Spacer(minLength: 12)

      Label("\(errorCount)", systemImage: "xmark.octagon")
        .foregroundStyle(errorCount > 0 ? WorkbenchTheme.risk : Color.secondary)
      Label("\(warningCount)", systemImage: "exclamationmark.triangle")
        .foregroundStyle(warningCount > 0 ? WorkbenchTheme.warning : Color.secondary)
      if isSelected {
        Image(systemName: "sidebar.right")
        .foregroundStyle(WorkbenchTheme.navigationSelection)
          .font(.caption.weight(.semibold))
          .accessibilityHidden(true)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        .fill(
          isSelected
            ? AnyShapeStyle(WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.selectionBackground))
            : WorkbenchBackgroundStyle.subtle
        )
    }
  }

  private func filteredDraftSummaries(in snapshot: ContentHealthSnapshot) -> [DraftPreflightSummary] {
    let aiFixDraftIDs = Set(snapshot.aiFixQueueItems.map(\.draftID))
    let summaries: [DraftPreflightSummary]
    switch issueScope {
    case .all:
      summaries = snapshot.contentHealthSummaries
    case .publicRisks:
      summaries = snapshot.contentHealthSummaries.filter { !$0.publicRiskIssues.isEmpty }
    case .aiFixes:
      summaries = snapshot.contentHealthSummaries.filter { aiFixDraftIDs.contains($0.draftID) }
    case .siteIssues:
      summaries = []
    }
    return summaries.filter { !matchingIssues(for: $0).isEmpty }
  }

  private func matchingIssues(for summary: DraftPreflightSummary) -> [PreflightIssue] {
    let issues: [PreflightIssue]
    switch issueScope {
    case .publicRisks:
      issues = summary.publicRiskIssues
    case .all, .aiFixes, .siteIssues:
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
      guard let result = await store.ai.performAction(item.recommendedAction, draft: draft) else { return }
      aiFixResultPreview = ContentHealthAIFixResultPreview(
        draftTitle: draft.title.nilIfEmpty ?? String(localized: "未命名文章"),
        result: result
      )
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

}

private enum ContentHealthIssueScopeFilter: String, CaseIterable, Identifiable {
  case all
  case publicRisks
  case aiFixes
  case siteIssues

  var id: String { rawValue }

  init(legacyFilter: ContentHealthContextFilter) {
    switch legacyFilter {
    case .publicRisks:
      self = .publicRisks
    case .aiFixes:
      self = .aiFixes
    case .siteIssues:
      self = .siteIssues
    case .overview, .maintenance:
      self = .all
    }
  }

  var title: String {
    switch self {
    case .all:
      return String(localized: "全部问题")
    case .publicRisks:
      return String(localized: "公开风险")
    case .aiFixes:
      return String(localized: "AI 可修复")
    case .siteIssues:
      return String(localized: "站点级问题")
    }
  }

  var systemImage: String {
    switch self {
    case .all:
      return "checklist"
    case .publicRisks:
      return "exclamationmark.shield"
    case .aiFixes:
      return "sparkles"
    case .siteIssues:
      return "globe.badge.chevron.backward"
    }
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
      return String(localized: "全部")
    case .errors:
      return String(localized: "错误")
    case .warnings:
      return String(localized: "警告")
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
  var generatedAt: Date
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
  static func make(store: WorkbenchStore) async throws -> ContentHealthSnapshot {
    let profileName = store.activeProfile.name
    let visibleDraftCount = store.visibleDrafts.count
    let report = try await store.contentHealthReportAsync()
    return ContentHealthSnapshot(
      generatedAt: Date(),
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

private enum ContentHealthPageMode: String, CaseIterable, Identifiable {
  case issues
  case maintenance

  var id: String { rawValue }

  var title: String {
    switch self {
    case .issues: String(localized: "问题")
    case .maintenance: String(localized: "站点维护")
    }
  }

  var systemImage: String {
    switch self {
    case .issues: "checklist"
    case .maintenance: "wrench.and.screwdriver"
    }
  }
}

private struct ContentHealthAIFixResultPreview: Identifiable {
  let id = UUID()
  let draftTitle: String
  let result: AIPublishingActionResult
}

private struct ContentHealthAIFixResultPreviewSheet: View {
  @Environment(\.dismiss) private var dismiss
  let preview: ContentHealthAIFixResultPreview

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("AI 修复结果预览", systemImage: "sparkles.rectangle.stack")
          .font(.headline)
        Spacer()
        Button("关闭") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(14)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(preview.draftTitle)
            .font(.title3.weight(.semibold))
          if !preview.result.providerName.isEmpty || !preview.result.model.isEmpty {
            Text([preview.result.providerName, preview.result.model].filter { !$0.isEmpty }.joined(separator: " · "))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Text(preview.result.content)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
      }
    }
    .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 620)
    .accessibilityLabel("AI 修复结果预览")
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
