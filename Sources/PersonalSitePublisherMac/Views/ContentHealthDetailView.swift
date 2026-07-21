import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct ContentHealthDetailView: View {
  let store: WorkbenchStore
  let filter: ContentHealthContextFilter
  @StateObject private var healthState: WorkbenchContentHealthFeatureFacade
  @State private var healthSnapshot: ContentHealthSnapshot?
  @State private var severityFilter: ContentHealthSeverityFilter = .all
  @State private var issueScope: ContentHealthIssueScopeFilter = .all
  @State private var articleGrouping: ContentHealthArticleGrouping = .automaticFix
  @State private var healthSnapshotTask: Task<Void, Never>?
  @State private var healthSnapshotErrorMessage: String?
  @State private var pageMode: ContentHealthPageMode
  @State private var isHealthSnapshotRefreshing = false
  @State private var healthSnapshotRequestID = UUID()
  @State private var aiFixResultPreview: ContentHealthAIFixResultPreview?
  @State private var selectedHealthDraftID: UUID?
  @State private var articlePresentation: ContentHealthArticlePresentation?

  init(store: WorkbenchStore, filter: ContentHealthContextFilter) {
    self.store = store
    self.filter = filter
    _healthState = StateObject(
      wrappedValue: WorkbenchContentHealthFeatureFacade(store: store)
    )
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
    .onChange(of: healthState.snapshotVersion) { _, _ in
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
    .onChange(of: issueScope) { _, _ in
      rebuildArticlePresentation()
    }
    .onChange(of: severityFilter) { _, _ in
      rebuildArticlePresentation()
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
    GeometryReader { geometry in
      ScrollView(.vertical, showsIndicators: true) {
        VStack(alignment: .leading, spacing: 16) {
          pageModePicker
          if pageMode == .maintenance {
            SiteMaintenanceDetailView(store: store, isEmbedded: true)
          } else {
            healthSnapshotContent(
              usesSplitLayout: WorkbenchPageMetrics.usesOperationalSplit(for: geometry.size.width)
            )
          }
        }
        .workbenchOperationalPageLayout()
      }
    }
  }

  private var pageModePicker: some View {
    Picker("内容健康页面", selection: $pageMode) {
      ForEach(ContentHealthPageMode.allCases) { mode in
        Label(mode.title, systemImage: mode.systemImage).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(maxWidth: 360)
    .accessibilityLabel("内容健康页面")
  }

  @ViewBuilder
  private func healthSnapshotContent(usesSplitLayout: Bool) -> some View {
    if let snapshot = healthSnapshot {
      content(snapshot, usesSplitLayout: usesSplitLayout)
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

  private func content(
    _ snapshot: ContentHealthSnapshot,
    usesSplitLayout: Bool
  ) -> some View {
    let presentation = currentArticlePresentation(for: snapshot)
    let selectedRow = selectedHealthRow(in: presentation)

    return VStack(alignment: .leading, spacing: 16) {
      contentHeader(snapshot)
      contentFilters(presentation)

      WorkbenchOperationalSplitLayout(usesSplitLayout: usesSplitLayout) {
        filteredSections(
          presentation,
          selectedDraftID: selectedRow?.draftID,
          profileName: snapshot.profileName
        )
      } context: {
        contentHealthOperationalContextPanel(
          presentation,
          selectedRow: selectedRow
        )
      }
    }
  }

  private func contentHeader(_ snapshot: ContentHealthSnapshot) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 16) {
        contentTitle(snapshot)
        Spacer(minLength: 16)
        VStack(alignment: .trailing, spacing: 8) {
          snapshotStatus(snapshot)
          healthSummary(snapshot)
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        contentTitle(snapshot)
        snapshotStatus(snapshot)
        healthSummary(snapshot)
      }
    }
  }

  private func contentTitle(_ snapshot: ContentHealthSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("内容健康")
        .font(.title2.weight(.semibold))
      Text("\(snapshot.profileName) · 一次扫描派生总览、文章分组与问题详情")
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
  }

  private func snapshotStatus(_ snapshot: ContentHealthSnapshot) -> some View {
    Label(
      isHealthSnapshotRefreshing
        ? "正在更新"
        : "上次检查 \(snapshot.generatedAt.workbenchShortText)",
      systemImage: isHealthSnapshotRefreshing ? "arrow.clockwise" : "clock"
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: true, vertical: false)
  }

  private func contentFilters(
    _ presentation: ContentHealthArticlePresentation
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        issueScopePicker
        severityPicker
        articleGroupingPicker
        Spacer(minLength: 0)
        recommendedAction(presentation)
          .fixedSize(horizontal: true, vertical: false)
      }

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          issueScopePicker
          severityPicker
          articleGroupingPicker
          Spacer(minLength: 0)
        }
        recommendedAction(presentation)
      }

      VStack(alignment: .leading, spacing: 10) {
        issueScopePicker
        severityPicker
        articleGroupingPicker
        recommendedAction(presentation)
      }
    }
  }

  private var issueScopePicker: some View {
    Picker("问题类型", selection: $issueScope) {
      ForEach(ContentHealthIssueScopeFilter.allCases) { scope in
        Label(scope.title, systemImage: scope.systemImage).tag(scope)
      }
    }
    .pickerStyle(.menu)
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityLabel("问题类型筛选")
  }

  private var severityPicker: some View {
    Picker("严重级别", selection: $severityFilter) {
      ForEach(ContentHealthSeverityFilter.allCases) { severity in
        Text(severity.title).tag(severity)
      }
    }
    .pickerStyle(.segmented)
    .tint(WorkbenchTheme.navigationSelection)
    .labelsHidden()
    .frame(minWidth: 220, maxWidth: 280)
    .accessibilityLabel("严重级别筛选")
  }

  private var articleGroupingPicker: some View {
    Picker("文章分组方式", selection: $articleGrouping) {
      ForEach(ContentHealthArticleGrouping.allCases) { grouping in
        Label(grouping.title, systemImage: grouping.systemImage).tag(grouping)
      }
    }
    .pickerStyle(.menu)
    .fixedSize(horizontal: true, vertical: false)
    .disabled(issueScope == .siteIssues)
    .accessibilityLabel("文章分组方式")
  }

  @ViewBuilder
  private func filteredSections(
    _ presentation: ContentHealthArticlePresentation,
    selectedDraftID: UUID?,
    profileName: String
  ) -> some View {
    if issueScope == .siteIssues {
      siteIssuesSection(presentation.siteIssues)
    } else {
      articleHealthFlow(
        presentation.rows,
        selectedDraftID: selectedDraftID,
        profileName: profileName,
        duplicateMarkdownPaths: presentation.duplicateMarkdownPaths
      )
    }
  }

  private func refreshContentHealthSnapshotIfNeeded() {
    guard healthSnapshot == nil else { return }
    refreshContentHealthSnapshot()
  }

  private func currentArticlePresentation(
    for snapshot: ContentHealthSnapshot
  ) -> ContentHealthArticlePresentation {
    if let articlePresentation,
       articlePresentation.matches(
         snapshotID: snapshot.id,
         issueScope: issueScope,
         severityFilter: severityFilter
       ) {
      return articlePresentation
    }
    return ContentHealthArticlePresentation(
      snapshot: snapshot,
      issueScope: issueScope,
      severityFilter: severityFilter
    )
  }

  private func rebuildArticlePresentation() {
    guard let healthSnapshot else {
      articlePresentation = nil
      return
    }
    articlePresentation = ContentHealthArticlePresentation(
      snapshot: healthSnapshot,
      issueScope: issueScope,
      severityFilter: severityFilter
    )
  }

  private func refreshContentHealthSnapshot() {
    healthSnapshotTask?.cancel()
    let expectedVersion = healthState.snapshotVersion
    let requestID = UUID()
    healthSnapshotRequestID = requestID
    isHealthSnapshotRefreshing = true
    healthSnapshotErrorMessage = nil
    healthSnapshotTask = Task { @MainActor in
      do {
        let snapshot = try await ContentHealthSnapshot.make(store: store)
        guard !Task.isCancelled,
              healthSnapshotRequestID == requestID,
              healthState.snapshotVersion == expectedVersion else { return }
        healthSnapshot = snapshot
        articlePresentation = ContentHealthArticlePresentation(
          snapshot: snapshot,
          issueScope: issueScope,
          severityFilter: severityFilter
        )
        healthSnapshotErrorMessage = nil
        isHealthSnapshotRefreshing = false
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled,
              healthSnapshotRequestID == requestID,
              healthState.snapshotVersion == expectedVersion else { return }
        healthSnapshot = nil
        articlePresentation = nil
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
    LazyVGrid(
      columns: [
        GridItem(
          .adaptive(minimum: 108, maximum: 132),
          spacing: 8,
          alignment: .leading
        )
      ],
      alignment: .leading,
      spacing: 8
    ) {
      healthSummaryBadge(
        title: "错误",
        value: snapshot.errorCount,
        systemImage: "xmark.octagon",
        color: WorkbenchTheme.risk
      )
      healthSummaryBadge(
        title: "警告",
        value: snapshot.warningCount,
        systemImage: "exclamationmark.triangle",
        color: WorkbenchTheme.warning
      )
      healthSummaryBadge(
        title: "AI",
        value: snapshot.aiFixQueueItems.count,
        systemImage: "sparkles",
        color: WorkbenchTheme.inventoryForeground
      )
      healthSummaryBadge(
        title: "通过",
        value: snapshot.passingDraftCount,
        systemImage: "checkmark.circle",
        color: WorkbenchTheme.success
      )
    }
    .frame(maxWidth: 552, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("内容健康摘要")
    .accessibilityValue(
      "\(snapshot.errorCount) 个错误，\(snapshot.warningCount) 个警告，"
        + "\(snapshot.aiFixQueueItems.count) 项可用 AI 修复，\(snapshot.passingDraftCount) 篇文章通过"
    )
  }

  private func healthSummaryBadge(
    title: LocalizedStringKey,
    value: Int,
    systemImage: String,
    color: Color
  ) -> some View {
    HStack(spacing: 5) {
      Image(systemName: systemImage)
        .accessibilityHidden(true)
      Text(title)
      Text("\(value)")
        .fontWeight(.semibold)
        .monospacedDigit()
    }
    .font(.callout.weight(.medium))
    .foregroundStyle(value > 0 ? color : Color.secondary)
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .center)
    .background(
      value > 0
        ? AnyShapeStyle(color.opacity(WorkbenchOpacity.noticeBackground))
        : WorkbenchBackgroundStyle.control,
      in: Capsule()
    )
  }

  @ViewBuilder
  private func recommendedAction(
    _ presentation: ContentHealthArticlePresentation
  ) -> some View {
    if let item = presentation.recommendedAIFixItem {
      let recommendationTitle = "推荐：用 AI 修复 \(item.draftTitle)"
      Button {
        runAIFixQueueItem(item)
      } label: {
        Label(recommendationTitle, systemImage: item.recommendedAction.promptLibrarySystemImage)
          .workbenchTruncatedIdentity(recommendationTitle)
      }
      .disabled(store.ai.isActionRunning)
    } else if let row = presentation.rows.first {
      let recommendationTitle = "推荐：处理 \(row.draftTitle)"
      Button {
        _ = store.focusDraft(row.draftID, section: .writing)
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

  private func contentHealthOperationalContextPanel(
    _ presentation: ContentHealthArticlePresentation,
    selectedRow: ContentHealthArticleRowModel?
  ) -> some View {
    return VStack(alignment: .leading, spacing: 12) {
      Label("问题详情", systemImage: "sidebar.right")
        .font(.headline)

      if issueScope == .siteIssues {
        if let siteIssue = presentation.siteIssues.first {
          ContentHealthIssueCard(issue: siteIssue)
        } else {
          Label("站点路径和仓库状态没有阻塞问题。", systemImage: "checkmark.circle")
            .foregroundStyle(WorkbenchTheme.success)
        }
      } else if let selectedRow {
        Text(selectedRow.draftTitle)
          .font(.callout.weight(.semibold))
          .workbenchTruncatedIdentity(selectedRow.draftTitle)
        Text(selectedRow.markdownPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(selectedRow.markdownPath)

        if presentation.duplicateMarkdownPaths.contains(selectedRow.normalizedMarkdownPath) {
          AccessibleStatusMessage(
            message: "多篇文章映射到同一路径，请先修正路径冲突再发布。",
            severity: .warning
          )
        }

        InspectorStatRow(
          title: "错误",
          value: "\(selectedRow.errorCount)",
          systemImage: "xmark.octagon"
        )
        InspectorStatRow(
          title: "警告",
          value: "\(selectedRow.warningCount)",
          systemImage: "exclamationmark.triangle"
        )

        if !selectedRow.issues.isEmpty {
          Divider()
          ForEach(selectedRow.issues.prefix(4)) { issue in
            ContentHealthIssueCard(issue: issue)
          }
        }

        if let aiItem = selectedRow.aiFixItem {
          Button {
            runAIFixQueueItem(aiItem)
          } label: {
            Label("AI 修复", systemImage: "sparkles")
          }
          .disabled(store.ai.isActionRunning)
          .workbenchProminentActionStyle()
        }

        HStack(spacing: 8) {
          Button {
            _ = store.focusDraft(selectedRow.draftID, section: .writing)
          } label: {
            Label("前往写作", systemImage: "square.and.pencil")
          }
          .buttonStyle(.bordered)

          Button {
            guard store.focusDraft(selectedRow.draftID, section: .contentHealth) else {
              return
            }
            store.setInspectorPresented(true)
          } label: {
            Label("Inspector", systemImage: "sidebar.right")
          }
          .buttonStyle(.bordered)
        }
      } else {
        Label("当前筛选下没有待处理的文章问题。", systemImage: "checkmark.circle")
          .foregroundStyle(WorkbenchTheme.success)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("问题详情")
  }

  private func selectedHealthRow(
    in presentation: ContentHealthArticlePresentation
  ) -> ContentHealthArticleRowModel? {
    if let selectedHealthDraftID,
       let selected = presentation.rowByDraftID[selectedHealthDraftID] {
      return selected
    }
    if let selectedDraftID = store.selectedDraftID,
       let selected = presentation.rowByDraftID[selectedDraftID] {
      return selected
    }
    return presentation.rows.first
  }

  private func articleHealthFlow(
    _ rows: [ContentHealthArticleRowModel],
    selectedDraftID: UUID?,
    profileName: String,
    duplicateMarkdownPaths: Set<String>
  ) -> some View {
    let groups = articleGrouping.groups(rows: rows, profileName: profileName)
    return VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("文章分组")
          .font(.headline)
        Spacer()
        Text("\(rows.count) 篇")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if rows.isEmpty {
        Label("当前筛选下没有待处理的文章问题。", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
          .padding(.vertical, 12)
      } else {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(groups) { group in
            VStack(alignment: .leading, spacing: 8) {
              HStack(spacing: 6) {
                Image(systemName: group.systemImage)
                  .foregroundStyle(.secondary)
                Text(group.title)
                  .font(.callout.weight(.semibold))
                  .workbenchTruncatedIdentity(group.title)
                Spacer(minLength: 8)
                Text("\(group.rows.count) 篇")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }

              ForEach(group.rows) { row in
                let isSelected = selectedDraftID == row.draftID
                Button {
                  selectedHealthDraftID = row.draftID
                } label: {
                  articleSummaryRow(
                    row,
                    isSelected: isSelected,
                    hasDuplicatePath: duplicateMarkdownPaths.contains(row.normalizedMarkdownPath)
                  )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择 \(row.draftTitle) 查看问题详情")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
              }
            }
          }
        }
      }

    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func articleSummaryRow(
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
            ? AnyShapeStyle(WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.selectionBackground))
            : WorkbenchBackgroundStyle.subtle
        )
    }
  }

  private func articleRowIdentity(
    _ row: ContentHealthArticleRowModel
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(row.draftTitle)
        .font(.callout.weight(.medium))
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

  private func siteIssuesSection(_ issues: [PreflightIssue]) -> some View {
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

private enum ContentHealthArticleGrouping: String, CaseIterable, Identifiable {
  case automaticFix
  case site
  case file

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automaticFix: String(localized: "按处理方式")
    case .site: String(localized: "按站点")
    case .file: String(localized: "按文件")
    }
  }

  var systemImage: String {
    switch self {
    case .automaticFix: "wand.and.stars"
    case .site: "globe"
    case .file: "doc.text"
    }
  }

  func groups(
    rows: [ContentHealthArticleRowModel],
    profileName: String
  ) -> [ContentHealthArticleGroup] {
    switch self {
    case .automaticFix:
      let automaticRows = rows.filter { $0.aiFixItem != nil }
      let manualRows = rows.filter { $0.aiFixItem == nil }
      return [
        ContentHealthArticleGroup(
          id: "automatic",
          title: String(localized: "可用 AI 修复"),
          systemImage: "sparkles",
          rows: automaticRows
        ),
        ContentHealthArticleGroup(
          id: "manual",
          title: String(localized: "需要手动处理"),
          systemImage: "hand.raised",
          rows: manualRows
        ),
      ].filter { !$0.rows.isEmpty }
    case .site:
      return [ContentHealthArticleGroup(
        id: "site",
        title: profileName,
        systemImage: "globe",
        rows: rows
      )]
    case .file:
      return rows.map { row in
        ContentHealthArticleGroup(
          id: row.draftID.uuidString,
          title: row.markdownPath,
          systemImage: "doc.text",
          rows: [row]
        )
      }
    }
  }
}

private struct ContentHealthArticleGroup: Identifiable {
  let id: String
  let title: String
  let systemImage: String
  let rows: [ContentHealthArticleRowModel]
}

private struct ContentHealthArticleRowModel: Identifiable {
  let draftID: UUID
  let draftTitle: String
  let markdownPath: String
  let issues: [PreflightIssue]
  let errorCount: Int
  let warningCount: Int
  let aiFixItem: AIPublishingFixQueueItem?

  var id: UUID { draftID }
  var normalizedMarkdownPath: String { markdownPath.normalizedRelativePath() }

  init(
    summary: DraftPreflightSummary,
    issues: [PreflightIssue],
    aiFixItem: AIPublishingFixQueueItem?
  ) {
    var errorCount = 0
    var warningCount = 0
    for issue in issues {
      switch issue.severity {
      case .error:
        errorCount += 1
      case .warning:
        warningCount += 1
      case .info:
        break
      }
    }

    draftID = summary.draftID
    draftTitle = summary.draftTitle
    markdownPath = summary.markdownPath
    self.issues = issues
    self.errorCount = errorCount
    self.warningCount = warningCount
    self.aiFixItem = aiFixItem
  }
}

private struct ContentHealthArticlePresentation {
  let snapshotID: UUID
  let issueScope: ContentHealthIssueScopeFilter
  let severityFilter: ContentHealthSeverityFilter
  let rows: [ContentHealthArticleRowModel]
  let rowByDraftID: [UUID: ContentHealthArticleRowModel]
  let siteIssues: [PreflightIssue]
  let recommendedAIFixItem: AIPublishingFixQueueItem?
  let duplicateMarkdownPaths: Set<String>

  init(
    snapshot: ContentHealthSnapshot,
    issueScope: ContentHealthIssueScopeFilter,
    severityFilter: ContentHealthSeverityFilter
  ) {
    var aiFixItemByDraftID: [UUID: AIPublishingFixQueueItem] = [:]
    for item in snapshot.aiFixQueueItems where aiFixItemByDraftID[item.draftID] == nil {
      aiFixItemByDraftID[item.draftID] = item
    }

    let sourceSummaries: [DraftPreflightSummary]
    switch issueScope {
    case .all:
      sourceSummaries = snapshot.contentHealthSummaries
    case .publicRisks:
      sourceSummaries = snapshot.publicRiskDraftSummaries
    case .aiFixes:
      sourceSummaries = snapshot.contentHealthSummaries.filter {
        aiFixItemByDraftID[$0.draftID] != nil
      }
    case .siteIssues:
      sourceSummaries = []
    }

    let rows = sourceSummaries.compactMap { summary -> ContentHealthArticleRowModel? in
      let sourceIssues: [PreflightIssue]
      switch issueScope {
      case .publicRisks:
        sourceIssues = summary.publicRiskIssues
      case .all, .aiFixes, .siteIssues:
        sourceIssues = summary.blockingIssues
      }
      let issues = severityFilter.filter(sourceIssues)
      guard !issues.isEmpty else { return nil }
      return ContentHealthArticleRowModel(
        summary: summary,
        issues: issues,
        aiFixItem: aiFixItemByDraftID[summary.draftID]
      )
    }

    var rowByDraftID: [UUID: ContentHealthArticleRowModel] = [:]
    for row in rows {
      rowByDraftID[row.draftID] = row
    }
    let visibleDraftIDs = Set(rowByDraftID.keys)
    let pathCounts = Dictionary(grouping: rows, by: \.normalizedMarkdownPath)
      .mapValues(\.count)

    snapshotID = snapshot.id
    self.issueScope = issueScope
    self.severityFilter = severityFilter
    self.rows = rows
    self.rowByDraftID = rowByDraftID
    duplicateMarkdownPaths = Set(
      pathCounts.compactMap { path, count in count > 1 ? path : nil }
    )
    siteIssues = severityFilter.filter(snapshot.sitePreflightIssues)
    recommendedAIFixItem = snapshot.aiFixQueueItems.first {
      visibleDraftIDs.contains($0.draftID)
    }
  }

  func matches(
    snapshotID: UUID,
    issueScope: ContentHealthIssueScopeFilter,
    severityFilter: ContentHealthSeverityFilter
  ) -> Bool {
    self.snapshotID == snapshotID
      && self.issueScope == issueScope
      && self.severityFilter == severityFilter
  }
}

private struct ContentHealthSnapshot {
  var id: UUID
  var generatedAt: Date
  var profileName: String
  var publicRiskDraftSummaries: [DraftPreflightSummary]
  var aiFixQueueItems: [AIPublishingFixQueueItem]
  var sitePreflightIssues: [PreflightIssue]
  var contentHealthSummaries: [DraftPreflightSummary]
  var errorCount: Int
  var warningCount: Int
  var passingDraftCount: Int

  @MainActor
  static func make(store: WorkbenchStore) async throws -> ContentHealthSnapshot {
    let profileName = store.activeProfile.name
    let report = try await store.contentHealthReportAsync()
    var errorCount = report.sitePreflightIssues.reduce(into: 0) { count, issue in
      if issue.severity == .error { count += 1 }
    }
    var warningCount = report.sitePreflightIssues.reduce(into: 0) { count, issue in
      if issue.severity == .warning { count += 1 }
    }
    var passingDraftCount = 0
    for summary in report.draftSummaries {
      var draftHasBlockingIssue = false
      for issue in summary.issues {
        switch issue.severity {
        case .error:
          errorCount += 1
          draftHasBlockingIssue = true
        case .warning:
          warningCount += 1
          draftHasBlockingIssue = true
        case .info:
          break
        }
      }
      if !draftHasBlockingIssue {
        passingDraftCount += 1
      }
    }
    return ContentHealthSnapshot(
      id: UUID(),
      generatedAt: Date(),
      profileName: profileName,
      publicRiskDraftSummaries: report.publicRiskDraftSummaries,
      aiFixQueueItems: report.aiFixQueueItems,
      sitePreflightIssues: report.sitePreflightIssues,
      contentHealthSummaries: report.draftSummaries,
      errorCount: errorCount,
      warningCount: warningCount,
      passingDraftCount: passingDraftCount
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
