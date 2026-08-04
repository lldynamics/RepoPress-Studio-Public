import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct ContentHealthDetailView: View {
  let store: WorkbenchStore
  @Binding var filter: ContentHealthContextFilter
  let sidebarProjection: ContentHealthSidebarProjection
  @StateObject private var healthState: WorkbenchContentHealthFeatureFacade
  @State private var healthSnapshot: ContentHealthSnapshot?
  @State private var severityFilter: ContentHealthSeverityFilter = .all
  @State private var articleGrouping: ContentHealthArticleGrouping = .actionQueue
  @State private var healthSnapshotTask: Task<Void, Never>?
  @State private var articlePresentationTask: Task<Void, Never>?
  @State private var healthSnapshotErrorMessage: String?
  @State private var isHealthSnapshotRefreshing = false
  @State private var healthSnapshotRequestID = UUID()
  @State private var articlePresentationRequestID = UUID()
  @State var aiFixResultPreview: ContentHealthAIFixResultPreview?
  @State private var selectedHealthDraftID: UUID?
  @State private var articlePresentation: ContentHealthArticlePresentation?
  @State private var expandedActionQueueGroupIDs: Set<String> = []

  init(
    store: WorkbenchStore,
    filter: Binding<ContentHealthContextFilter>,
    sidebarProjection: ContentHealthSidebarProjection
  ) {
    self.store = store
    _filter = filter
    self.sidebarProjection = sidebarProjection
    _healthState = StateObject(
      wrappedValue: WorkbenchContentHealthFeatureFacade(store: store)
    )
    _articleGrouping = State(initialValue: Self.preferredGrouping(for: filter.wrappedValue))
  }

  var body: some View {
    detailContent
    .task {
      refreshContentHealthSnapshotIfNeeded()
    }
    .onChange(of: healthState.snapshotVersion) { _, _ in
      refreshContentHealthSnapshot()
    }
    .onChange(of: filter) { _, newFilter in
      applyPreferredGrouping(for: newFilter)
      rebuildArticlePresentation()
      refreshContentHealthSnapshotIfNeeded()
    }
    .onChange(of: severityFilter) { _, _ in
      rebuildArticlePresentation()
    }
    .onDisappear {
      healthSnapshotTask?.cancel()
      healthSnapshotTask = nil
      articlePresentationTask?.cancel()
      articlePresentationTask = nil
      isHealthSnapshotRefreshing = false
    }
    .sheet(item: $aiFixResultPreview) { preview in
      ContentHealthAIFixResultPreviewSheet(preview: preview)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("内容健康")
    .accessibilityIdentifier("content-health-workspace")
  }

  private func applyPreferredGrouping(for newFilter: ContentHealthContextFilter) {
    articleGrouping = Self.preferredGrouping(for: newFilter)
  }

  private static func preferredGrouping(
    for filter: ContentHealthContextFilter
  ) -> ContentHealthArticleGrouping {
    switch filter {
    case .overview, .publicRisks:
      return .actionQueue
    case .aiFixes:
      return .automaticFix
    case .siteIssues:
      return .site
    case .maintenance:
      return .actionQueue
    }
  }

  @ViewBuilder
  private var detailContent: some View {
    GeometryReader { geometry in
      ScrollView(.vertical, showsIndicators: true) {
        VStack(alignment: .leading, spacing: 16) {
          if filter == .maintenance {
            SiteMaintenanceDetailView(store: store, isEmbedded: true)
              .accessibilityElement(children: .contain)
              .accessibilityIdentifier("content-health-stage-maintenance")
          } else {
            healthSnapshotContent(availableWidth: geometry.size.width)
              .accessibilityElement(children: .contain)
              .accessibilityIdentifier("content-health-stage-\(filter.rawValue)")
          }
        }
        .workbenchOperationalPageLayout()
      }
    }
  }

  @ViewBuilder
  private func healthSnapshotContent(availableWidth: CGFloat) -> some View {
    let usesSplitLayout = WorkbenchPageMetrics.usesOperationalSplit(for: availableWidth)
    let usesCompactHeader = ContentHealthLayoutMetrics.usesCompactHeader(
      availableWidth: availableWidth,
      usesSplitLayout: usesSplitLayout
    )
    if let healthSnapshotErrorMessage {
      snapshotFailureState(healthSnapshotErrorMessage)
    } else if let snapshot = healthSnapshot,
              let presentation = articlePresentation,
              presentation.matches(
                snapshotID: snapshot.id,
                filter: filter,
                severityFilter: severityFilter
              ) {
      content(
        snapshot,
        presentation: presentation,
        usesSplitLayout: usesSplitLayout,
        usesCompactHeader: usesCompactHeader
      )
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
    presentation: ContentHealthArticlePresentation,
    usesSplitLayout: Bool,
    usesCompactHeader: Bool
  ) -> some View {
    let selectedRow = selectedHealthRow(in: presentation)

    return VStack(alignment: .leading, spacing: 16) {
      contentHeader(snapshot, usesCompactLayout: usesCompactHeader)
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

  @ViewBuilder
  private func contentHeader(
    _ snapshot: ContentHealthSnapshot,
    usesCompactLayout: Bool
  ) -> some View {
    if usesCompactLayout {
      VStack(alignment: .leading, spacing: 10) {
        contentTitle(snapshot)
        snapshotStatus(snapshot)
        healthSummary(snapshot, usesCompactLayout: true)
      }
    } else {
      HStack(alignment: .top, spacing: 16) {
        contentTitle(snapshot)
        Spacer(minLength: 16)
        VStack(alignment: .trailing, spacing: 8) {
          snapshotStatus(snapshot)
          healthSummary(snapshot, usesCompactLayout: false)
        }
      }
    }
  }

  private func contentTitle(_ snapshot: ContentHealthSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(filter.title)
        .font(.workbenchPageTitle)
      Text("\(snapshot.profileName) · \(filterDescription)")
        .font(.workbenchPageSubtitle)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
  }

  private var filterDescription: String {
    switch filter {
    case .overview:
      return String(localized: "先处理阻止发布、最高风险与可自动修复项")
    case .publicRisks:
      return String(localized: "集中核对发布后可能暴露的内容与配置")
    case .aiFixes:
      return String(localized: "预览并处理可由 AI 协助修复的元数据问题")
    case .siteIssues:
      return String(localized: "检查影响整个站点的路径、配置与发布问题")
    case .maintenance:
      return String(localized: "安排站点的持续维护工作")
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
        severityPicker
        articleGroupingPicker
        Spacer(minLength: 0)
        recommendedAction(presentation)
          .fixedSize(horizontal: true, vertical: false)
      }

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          severityPicker
          articleGroupingPicker
          Spacer(minLength: 0)
        }
        recommendedAction(presentation)
      }

      VStack(alignment: .leading, spacing: 10) {
        severityPicker
        articleGroupingPicker
        recommendedAction(presentation)
      }
    }
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
      ForEach(ContentHealthArticleGrouping.visibleCases) { grouping in
        Label(grouping.title, systemImage: grouping.systemImage).tag(grouping)
      }
    }
    .pickerStyle(.menu)
    .fixedSize(horizontal: true, vertical: false)
    .disabled(filter == .siteIssues)
    .accessibilityLabel("文章分组方式")
  }

  @ViewBuilder
  private func filteredSections(
    _ presentation: ContentHealthArticlePresentation,
    selectedDraftID: UUID?,
    profileName: String
  ) -> some View {
    if filter == .siteIssues {
      siteIssuesSection(presentation.siteIssues)
    } else {
      articleHealthFlow(
        presentation.rows,
        actionQueue: presentation.actionQueue,
        selectedDraftID: selectedDraftID,
        profileName: profileName,
        duplicateMarkdownPaths: presentation.duplicateMarkdownPaths,
        siteIssues: presentation.siteIssues
      )
    }
  }

  private func refreshContentHealthSnapshotIfNeeded() {
    guard healthSnapshot == nil else { return }
    refreshContentHealthSnapshot()
  }

  private func rebuildArticlePresentation() {
    articlePresentationTask?.cancel()
    guard let healthSnapshot else {
      articlePresentation = nil
      return
    }
    let expectedSnapshotID = healthSnapshot.id
    let expectedFilter = filter
    let expectedSeverityFilter = severityFilter
    let requestID = UUID()
    articlePresentationRequestID = requestID
    articlePresentation = nil
    healthSnapshotErrorMessage = nil
    let service = ContentHealthPresentationService()
    articlePresentationTask = Task { @MainActor in
      do {
        let presentation = try await service.articlePresentation(
          snapshot: healthSnapshot,
          filter: expectedFilter,
          severityFilter: expectedSeverityFilter
        )
        guard !Task.isCancelled,
              articlePresentationRequestID == requestID,
              self.healthSnapshot?.id == expectedSnapshotID,
              filter == expectedFilter,
              severityFilter == expectedSeverityFilter else { return }
        articlePresentation = presentation
        articlePresentationTask = nil
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled,
              articlePresentationRequestID == requestID else { return }
        articlePresentationTask = nil
        healthSnapshotErrorMessage = error.localizedDescription
      }
    }
  }

  private func refreshContentHealthSnapshot() {
    healthSnapshotTask?.cancel()
    let expectedProfileID = store.activeProfile.id
    let expectedProfileName = store.activeProfile.name
    let expectedVersion = healthState.snapshotVersion
    let requestID = UUID()
    healthSnapshotRequestID = requestID
    isHealthSnapshotRefreshing = true
    healthSnapshotErrorMessage = nil
    sidebarProjection.beginLoading(profileID: expectedProfileID)
    let service = ContentHealthPresentationService()
    healthSnapshotTask = Task { @MainActor in
      do {
        let report = try await store.contentHealthReportAsync()
        let snapshot = try await service.snapshot(
          profileID: expectedProfileID,
          profileName: expectedProfileName,
          report: report
        )
        guard !Task.isCancelled,
              healthSnapshotRequestID == requestID,
              healthState.snapshotVersion == expectedVersion,
              snapshot.profileID == expectedProfileID,
              store.activeProfile.id == expectedProfileID else { return }
        healthSnapshot = snapshot
        sidebarProjection.replace(
          profileID: snapshot.profileID,
          aiFixQueueItems: snapshot.aiFixQueueItems
        )
        articlePresentation = nil
        healthSnapshotErrorMessage = nil
        isHealthSnapshotRefreshing = false
        healthSnapshotTask = nil
        rebuildArticlePresentation()
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled,
              healthSnapshotRequestID == requestID,
              healthState.snapshotVersion == expectedVersion,
              store.activeProfile.id == expectedProfileID else { return }
        healthSnapshot = nil
        articlePresentationTask?.cancel()
        articlePresentationTask = nil
        articlePresentation = nil
        healthSnapshotErrorMessage = error.localizedDescription
        isHealthSnapshotRefreshing = false
        healthSnapshotTask = nil
        sidebarProjection.markFailed(profileID: expectedProfileID)
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

  private func healthSummary(
    _ snapshot: ContentHealthSnapshot,
    usesCompactLayout: Bool
  ) -> some View {
    LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(minimum: 108), spacing: 8),
        count: usesCompactLayout ? 2 : 4
      ),
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
    .frame(maxWidth: usesCompactLayout ? 300 : 552, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("内容健康摘要")
    .accessibilityValue(contentHealthSummaryAccessibilityValue(snapshot))
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
    if articleGrouping == .actionQueue,
       let row = nextActionQueueRow(in: presentation.actionQueue) {
      let recommendationTitle = "推荐：处理 \(row.draftTitle)"
      Button {
        selectedHealthDraftID = row.draftID
      } label: {
        Label(recommendationTitle, systemImage: "arrow.right.circle")
          .workbenchTruncatedIdentity(recommendationTitle)
      }
    } else if let item = presentation.recommendedAIFixItem {
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
        .font(.workbenchSectionTitle)

      if filter == .siteIssues {
        if let siteIssue = presentation.siteIssues.first {
          ContentHealthIssueCard(issue: siteIssue)
        } else {
          Label("站点路径和仓库状态没有阻塞问题。", systemImage: "checkmark.circle")
            .foregroundStyle(WorkbenchTheme.success)
        }
      } else if let selectedRow {
        Text(selectedRow.draftTitle)
          .font(.workbenchCardTitle)
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
          ForEach(selectedRow.issues) { issue in
            ContentHealthIssueCard(issue: issue) {
              focusContentHealthIssue(issue, draftID: selectedRow.draftID)
            }
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
          .accessibilityIdentifier(
            "content-health-open-article-\(selectedRow.draftID.uuidString)"
          )

          Button {
            guard store.focusDraft(selectedRow.draftID, section: .contentHealth) else {
              return
            }
            store.setInspectorPresented(true)
          } label: {
            Label("检查器", systemImage: "sidebar.right")
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
    if articleGrouping == .actionQueue {
      return nextActionQueueRow(in: presentation.actionQueue)
    }
    return presentation.rows.first
  }

  private func focusContentHealthIssue(_ issue: PreflightIssue, draftID: UUID) {
    switch issue.structuredField {
    case .body:
      _ = store.focusDraft(draftID, section: .writing)
      store.requestEditorFocus(
        draftID: draftID,
        field: issue.field,
        query: issue.editorQuery
      )
    case .attachments, .cover, .coverAlt:
      _ = store.focusDraft(draftID, section: .images)
    default:
      _ = store.focusDraft(draftID, section: .writing)
      store.setInspectorPresented(true)
    }
  }

  private func nextActionQueueRow(
    in queue: ContentHealthActionQueue
  ) -> ContentHealthArticleRowModel? {
    queue.blockingRows.first
      ?? queue.highestRiskRows.first
      ?? queue.automaticFixRows.first
      ?? queue.suggestionRows.first
  }

  private func articleHealthFlow(
    _ rows: [ContentHealthArticleRowModel],
    actionQueue: ContentHealthActionQueue,
    selectedDraftID: UUID?,
    profileName: String,
    duplicateMarkdownPaths: Set<String>,
    siteIssues: [PreflightIssue]
  ) -> some View {
    let groups = articleGrouping == .actionQueue
      ? actionQueue.groups
      : articleGrouping.groups(
          rows: rows,
          profileName: profileName,
          duplicateMarkdownPaths: duplicateMarkdownPaths
        )
    let hasActionableSiteIssue = siteIssues.contains {
      $0.severity == .error || $0.severity == .warning
    }
    return VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(
          articleGrouping == .actionQueue
            ? String(localized: "行动队列")
            : String(localized: "文章分组")
        )
          .font(.headline)
        Spacer()
        Text("\(rows.count) 篇")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if rows.isEmpty && (articleGrouping != .actionQueue || !hasActionableSiteIssue) {
        Label("当前筛选下没有待处理的文章问题。", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
          .padding(.vertical, 12)
      } else {
        LazyVStack(alignment: .leading, spacing: 8) {
          if articleGrouping == .actionQueue {
            actionQueueSiteIssueSections(siteIssues)
          }
          ForEach(groups) { group in
            VStack(alignment: .leading, spacing: 8) {
              articleGroupHeader(group)

              ForEach(visibleRows(in: group)) { row in
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
                .accessibilityIdentifier(
                  "content-health-select-article-\(row.draftID.uuidString)"
                )
                .accessibilityAddTraits(isSelected ? .isSelected : [])
              }

              if group.kind == .automaticFix,
                 group.rows.isEmpty,
                 group.prioritizedCount > 0 {
                let prioritizedMessage = String.localizedStringWithFormat(
                  String(localized: "%@ 项已进入更高优先级队列，并标记为 AI 可修复。"),
                  "\(group.prioritizedCount)"
                )
                Label(
                  prioritizedMessage,
                  systemImage: "arrow.up.circle"
                )
                .font(.workbenchSupporting)
                .foregroundStyle(.secondary)
              }

              if group.kind.isActionQueue {
                actionQueueGroupFooter(group)
              }
            }
            .padding(.vertical, 4)
          }
        }
      }

    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  @ViewBuilder
  private func actionQueueSiteIssueSections(_ siteIssues: [PreflightIssue]) -> some View {
    let blockingIssues = siteIssues.filter { $0.severity == .error }
    let warningIssues = siteIssues.filter { $0.severity == .warning }

    if !blockingIssues.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        actionQueueSiteIssueHeader(
          title: String(localized: "阻止发布的站点问题"),
          count: blockingIssues.count,
          systemImage: "globe.badge.chevron.backward",
          color: WorkbenchTheme.risk
        )
        ForEach(blockingIssues) { issue in
          ContentHealthIssueCard(issue: issue)
        }
      }
      .padding(.vertical, 4)
    }

    if !warningIssues.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        actionQueueSiteIssueHeader(
          title: String(localized: "站点发布建议"),
          count: warningIssues.count,
          systemImage: "globe.badge.chevron.backward",
          color: WorkbenchTheme.warning
        )
        ForEach(warningIssues) { issue in
          ContentHealthIssueCard(issue: issue)
        }
      }
      .padding(.vertical, 4)
    }
  }

  private func actionQueueSiteIssueHeader(
    title: String,
    count: Int,
    systemImage: String,
    color: Color
  ) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .foregroundStyle(color)
      Text(title)
        .font(.callout.weight(.semibold))
      Spacer(minLength: 8)
      Text("\(count) 项")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  private func articleGroupHeader(_ group: ContentHealthArticleGroup) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Image(systemName: group.systemImage)
          .foregroundStyle(articleGroupColor(group.kind))
        Text(group.title)
          .font(.callout.weight(.semibold))
          .workbenchTruncatedIdentity(group.title)
        Spacer(minLength: 8)
        Text("\(group.totalCount) 篇")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      if let detail = group.detail {
        Text(detail)
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if group.prioritizedCount > 0 {
        Text("其中 \(group.prioritizedCount) 项已列入更高优先级队列。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func articleGroupColor(_ kind: ContentHealthArticleGroupKind) -> Color {
    switch kind {
    case .blocking:
      return WorkbenchTheme.risk
    case .highestRisk:
      return WorkbenchTheme.warning
    case .automaticFix:
      return WorkbenchTheme.inventoryForeground
    case .suggestion, .standard:
      return .secondary
    }
  }

  private func visibleRows(
    in group: ContentHealthArticleGroup
  ) -> [ContentHealthArticleRowModel] {
    guard group.kind.isActionQueue,
          !expandedActionQueueGroupIDs.contains(group.id) else {
      return group.rows
    }
    return Array(group.rows.prefix(ContentHealthActionQueue.highestRiskLimit))
  }

  @ViewBuilder
  private func actionQueueGroupFooter(_ group: ContentHealthArticleGroup) -> some View {
    let visibleCount = visibleRows(in: group).count
    if group.rows.count > ContentHealthActionQueue.highestRiskLimit {
      HStack(spacing: 8) {
        Text("已显示 \(visibleCount)/\(group.rows.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Button(
          expandedActionQueueGroupIDs.contains(group.id)
            ? String(localized: "收起")
            : String(localized: "显示全部")
        ) {
          withAnimation(WorkbenchMotion.standard) {
            if expandedActionQueueGroupIDs.contains(group.id) {
              expandedActionQueueGroupIDs.remove(group.id)
            } else {
              expandedActionQueueGroupIDs.insert(group.id)
            }
          }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
      }
    }

    if group.kind == .automaticFix,
       group.totalCount > group.rows.count {
      Button {
        filter = .aiFixes
        articleGrouping = .automaticFix
      } label: {
        Label(String(localized: "查看全部 AI 可修复项"), systemImage: "arrow.right.circle")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
  }


}
