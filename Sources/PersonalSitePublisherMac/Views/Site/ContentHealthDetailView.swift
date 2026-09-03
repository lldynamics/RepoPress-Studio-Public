import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct ContentHealthDetailView: View {
  let store: WorkbenchStore
  let currentDraftID: UUID?
  @Binding var filter: ContentHealthContextFilter
  let sidebarProjection: ContentHealthSidebarProjection
  @Environment(\.structuralDraftRepairCommandAction) private var structuralDraftRepairCommandAction
  @StateObject private var healthState: WorkbenchContentHealthFeatureFacade
  @State private var healthSnapshot: ContentHealthSnapshot?
  @State private var severityFilter: ContentHealthSeverityFilter = .all
  @State private var scope: ContentHealthScope
  @State private var articleGrouping: ContentHealthArticleGrouping = .actionQueue
  @State private var healthSnapshotTask: Task<Void, Never>?
  @State private var articlePresentationTask: Task<Void, Never>?
  @State private var healthSnapshotErrorMessage: String?
  @State private var isHealthSnapshotRefreshing = false
  @State private var wasHealthSnapshotCancelled = false
  @State private var healthSnapshotRequestID = UUID()
  @State private var articlePresentationRequestID = UUID()
  @State var aiFixResultPreview: ContentHealthAIFixResultPreview?
  @State private var selectedHealthDraftID: UUID?
  @State private var articlePresentation: ContentHealthArticlePresentation?
  @State private var expandedActionQueueGroupIDs: Set<String> = []
  @State private var runningQuickFixIssueIDs: Set<UUID> = []
  @State private var quickFixMessagesByIssueID: [UUID: String] = [:]
  @State private var quickFixTasksByIssueID: [UUID: Task<Void, Never>] = [:]

  init(
    store: WorkbenchStore,
    currentDraftID: UUID?,
    filter: Binding<ContentHealthContextFilter>,
    sidebarProjection: ContentHealthSidebarProjection
  ) {
    self.store = store
    self.currentDraftID = currentDraftID
    _filter = filter
    self.sidebarProjection = sidebarProjection
    _healthState = StateObject(
      wrappedValue: WorkbenchContentHealthFeatureFacade(store: store)
    )
    _scope = State(initialValue: ContentHealthScope.initial(selectedDraftID: currentDraftID))
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
      .onChange(of: scope) { _, _ in
        selectedHealthDraftID = nil
        rebuildArticlePresentation()
      }
      .onChange(of: currentDraftID) { _, selectedDraftID in
        guard scope == .currentArticle else { return }
        if selectedDraftID == nil {
          scope = .wholeSite
        } else {
          selectedHealthDraftID = nil
          rebuildArticlePresentation()
        }
      }
      .onDisappear {
        cancelContentHealthWork(showsCancelledState: false)
        for task in quickFixTasksByIssueID.values {
          task.cancel()
        }
        quickFixTasksByIssueID.removeAll()
        runningQuickFixIssueIDs.removeAll()
      }
      .sheet(item: $aiFixResultPreview) { preview in
        ContentHealthAIFixResultPreviewSheet(preview: preview) { selectedFields in
          applySelectedAIFixFields(selectedFields, for: preview)
        }
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
          structuralDraftRepairEntry

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

  private var structuralDraftRepairEntry: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "wrench.and.screwdriver")
          .foregroundStyle(WorkbenchTheme.warning)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 3) {
          Text("修复遗留目录记录")
            .font(.headline)
          Text("先生成只读预览，再选择要保留为素材库草稿的记录和可选文件恢复；不会删除文章，也不会发布或下线站点。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 12)

        Button {
          structuralDraftRepairCommandAction?.open()
        } label: {
          Label(
            structuralDraftRepairCommandAction?.isScanning == true
              ? String(localized: "正在扫描…")
              : String(localized: "检查遗留记录"),
            systemImage: "doc.text.magnifyingglass"
          )
        }
        .buttonStyle(.bordered)
        .disabled(
          structuralDraftRepairCommandAction == nil
            || structuralDraftRepairCommandAction?.isScanning == true
        )
        .keyboardShortcut("r", modifiers: [.command, .option])
        .accessibilityIdentifier("content-health-open-structural-draft-repair")
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchTheme.warning.opacity(WorkbenchOpacity.noticeBackground),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("遗留目录修复")
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
    } else if wasHealthSnapshotCancelled {
      snapshotCancelledState
    } else if let snapshot = healthSnapshot,
      let presentation = articlePresentation,
      presentation.matches(
        snapshotID: snapshot.id,
        filter: filter,
        severityFilter: severityFilter,
        scope: resolvedScope
      )
    {
      content(
        snapshot,
        presentation: presentation,
        usesSplitLayout: usesSplitLayout,
        usesCompactHeader: usesCompactHeader
      )
    } else {
      ContentHealthSkeletonLoadingView(cancel: cancelContentHealthSnapshotRefresh)
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
      contentHeader(snapshot, presentation: presentation, usesCompactLayout: usesCompactHeader)
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
          selectedRow: selectedRow,
          slugChangeImpact: selectedRow.flatMap {
            snapshot.slugChangeImpacts[$0.draftID]
          }
        )
      }
    }
  }

  @ViewBuilder
  private func contentHeader(
    _ snapshot: ContentHealthSnapshot,
    presentation: ContentHealthArticlePresentation,
    usesCompactLayout: Bool
  ) -> some View {
    if usesCompactLayout {
      VStack(alignment: .leading, spacing: 10) {
        contentTitle(snapshot)
        snapshotStatus(snapshot)
        healthSummary(presentation, usesCompactLayout: true)
      }
    } else {
      HStack(alignment: .top, spacing: 16) {
        contentTitle(snapshot)
        Spacer(minLength: 16)
        VStack(alignment: .trailing, spacing: 8) {
          snapshotStatus(snapshot)
          healthSummary(presentation, usesCompactLayout: false)
        }
      }
    }
  }

  private func contentTitle(_ snapshot: ContentHealthSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(filter.title)
        .font(.workbenchPageTitle)
      Text("\(snapshot.profileName) · \(scopeDescription) · \(filterDescription)")
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

  private var resolvedScope: ContentHealthResolvedScope {
    if filter == .siteIssues {
      return .wholeSite
    }
    return scope.resolved(selectedDraftID: currentDraftID)
  }

  private var displayedScope: Binding<ContentHealthScope> {
    Binding(
      get: { filter == .siteIssues ? .wholeSite : scope },
      set: { scope = $0 }
    )
  }

  private var scopeDescription: String {
    switch resolvedScope {
    case .wholeSite:
      return currentDraftID == nil
        ? String(localized: "未选文章，已显示整个站点")
        : String(localized: "整个站点")
    case .currentArticle(let draftID):
      let title = store.draft(for: draftID)?.title.nilIfEmpty ?? String(localized: "未命名文章")
      return String(localized: "当前文章：\(title)")
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
        scopePicker
        severityPicker
        articleGroupingPicker
        Spacer(minLength: 0)
        recommendedAction(presentation)
          .fixedSize(horizontal: true, vertical: false)
      }

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          scopePicker
          severityPicker
          articleGroupingPicker
          Spacer(minLength: 0)
        }
        recommendedAction(presentation)
      }

      VStack(alignment: .leading, spacing: 10) {
        scopePicker
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

  private var scopePicker: some View {
    Picker("检查范围", selection: displayedScope) {
      Text(ContentHealthScope.currentArticle.title)
        .tag(ContentHealthScope.currentArticle)
        .disabled(currentDraftID == nil)
      Text(ContentHealthScope.wholeSite.title)
        .tag(ContentHealthScope.wholeSite)
    }
    .pickerStyle(.menu)
    .fixedSize(horizontal: true, vertical: false)
    .disabled(filter == .siteIssues)
    .accessibilityLabel("检查范围")
    .accessibilityHint(scopeDescription)
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
        selectedDraftID: selectedDraftID,
        profileName: profileName,
        duplicateMarkdownPaths: presentation.duplicateMarkdownPaths,
        siteIssues: presentation.siteIssues,
        scope: presentation.scope,
        wholeSiteErrorCount: presentation.wholeSiteErrorCount,
        wholeSiteWarningCount: presentation.wholeSiteWarningCount,
        globalBlockingSiteIssueCount: presentation.globalBlockingSiteIssueCount
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
    let expectedScope = resolvedScope
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
          severityFilter: expectedSeverityFilter,
          scope: expectedScope
        )
        guard !Task.isCancelled,
          articlePresentationRequestID == requestID,
          self.healthSnapshot?.id == expectedSnapshotID,
          filter == expectedFilter,
          severityFilter == expectedSeverityFilter,
          resolvedScope == expectedScope
        else { return }
        articlePresentation = presentation
        articlePresentationTask = nil
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled,
          articlePresentationRequestID == requestID
        else { return }
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
    let maskedDraftIDs = Set(
      store.visibleDrafts.filter {
        store.privateContentDisplay(for: $0).isMasked
      }.map(\.id))
    let requestID = UUID()
    healthSnapshotRequestID = requestID
    isHealthSnapshotRefreshing = true
    wasHealthSnapshotCancelled = false
    healthSnapshotErrorMessage = nil
    sidebarProjection.beginLoading(profileID: expectedProfileID)
    let service = ContentHealthPresentationService()
    healthSnapshotTask = Task { @MainActor in
      do {
        let report = try await store.contentHealthReportAsync()
        let snapshot = try await service.snapshot(
          profileID: expectedProfileID,
          profileName: expectedProfileName,
          report: report,
          maskedDraftIDs: maskedDraftIDs
        )
        guard !Task.isCancelled,
          healthSnapshotRequestID == requestID,
          healthState.snapshotVersion == expectedVersion,
          snapshot.profileID == expectedProfileID,
          store.activeProfile.id == expectedProfileID
        else { return }
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
        guard healthSnapshotRequestID == requestID else { return }
        isHealthSnapshotRefreshing = false
        healthSnapshotTask = nil
        return
      } catch {
        guard !Task.isCancelled,
          healthSnapshotRequestID == requestID,
          healthState.snapshotVersion == expectedVersion,
          store.activeProfile.id == expectedProfileID
        else { return }
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

  private func cancelContentHealthSnapshotRefresh() {
    cancelContentHealthWork(showsCancelledState: true)
  }

  private func cancelContentHealthWork(showsCancelledState: Bool) {
    healthSnapshotRequestID = UUID()
    articlePresentationRequestID = UUID()
    healthSnapshotTask?.cancel()
    healthSnapshotTask = nil
    articlePresentationTask?.cancel()
    articlePresentationTask = nil
    isHealthSnapshotRefreshing = false
    if showsCancelledState {
      wasHealthSnapshotCancelled = true
    }
  }

  private var snapshotCancelledState: some View {
    VStack(spacing: 12) {
      Image(systemName: "pause.circle")
        .font(.system(size: 38))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("内容健康检查已取消")
        .font(.headline)
      Text("尚未修改任何文章。需要时可以重新生成检查快照。")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button(action: refreshContentHealthSnapshot) {
        Label("重新开始", systemImage: "arrow.clockwise")
      }
      .workbenchProminentActionStyle()
    }
    .frame(maxWidth: .infinity, minHeight: 360)
    .padding(20)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("content-health-loading-cancelled")
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
    _ presentation: ContentHealthArticlePresentation,
    usesCompactLayout: Bool
  ) -> some View {
    return LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(minimum: 108), spacing: 8),
        count: usesCompactLayout ? 2 : 4
      ),
      alignment: .leading,
      spacing: 8
    ) {
      healthSummaryBadge(
        title: "错误",
        value: presentation.scopeErrorCount,
        systemImage: "xmark.octagon",
        color: WorkbenchTheme.risk
      )
      healthSummaryBadge(
        title: "警告",
        value: presentation.scopeWarningCount,
        systemImage: "exclamationmark.triangle",
        color: WorkbenchTheme.warning
      )
      healthSummaryBadge(
        title: "AI",
        value: presentation.rows.filter { $0.aiFixItem != nil }.count,
        systemImage: "sparkles",
        color: WorkbenchTheme.inventoryForeground
      )
      healthSummaryBadge(
        title: "文章",
        value: presentation.scopeDraftCount,
        systemImage: "doc.text",
        color: WorkbenchTheme.inventoryForeground
      )
    }
    .frame(maxWidth: usesCompactLayout ? 300 : 552, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("内容健康摘要")
    .accessibilityValue(contentHealthScopeAccessibilityValue(presentation))
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

  private func contentHealthScopeAccessibilityValue(
    _ presentation: ContentHealthArticlePresentation
  ) -> String {
    return [
      scopeDescription,
      "\(presentation.scopeErrorCount) 个错误",
      "\(presentation.scopeWarningCount) 个警告",
      "\(presentation.rows.filter { $0.aiFixItem != nil }.count) 项可用 AI 修复",
      "涉及 \(presentation.scopeDraftCount) 篇文章",
    ].joined(separator: "，")
  }

  @ViewBuilder
  private func recommendedAction(
    _ presentation: ContentHealthArticlePresentation
  ) -> some View {
    if articleGrouping == .actionQueue,
      let row = nextActionQueueRow(in: presentation.actionQueue)
    {
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
    selectedRow: ContentHealthArticleRowModel?,
    slugChangeImpact: SlugChangeImpact?
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
            let quickFix = store.draft(for: selectedRow.draftID).flatMap {
              issue.contentHealthQuickFix(for: $0)
            }
            ContentHealthIssueCard(
              issue: issue,
              onFocus: {
                focusContentHealthIssue(issue, draftID: selectedRow.draftID)
              },
              quickFix: quickFix,
              isQuickFixRunning: runningQuickFixIssueIDs.contains(issue.id),
              quickFixMessage: quickFixMessagesByIssueID[issue.id],
              onQuickFix: quickFix.map { quickFix in
                {
                  runContentHealthQuickFix(
                    quickFix,
                    issue: issue,
                    draftID: selectedRow.draftID
                  )
                }
              }
            )
          }
        }

        if let impact = slugChangeImpact {
          slugChangeResolutionCard(impact)
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
        Label(emptyScopeMessage, systemImage: "checkmark.circle")
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

  private func slugChangeResolutionCard(_ impact: SlugChangeImpact) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("Slug 变更处理", systemImage: "arrow.triangle.branch")
        .font(.callout.weight(.semibold))
      Text("\(impact.oldRoutes.joined(separator: "、")) → \(impact.newRoute)")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      Text(
        impact.referenceCount == 0
          ? "站内未检测到旧引用；仍可保留旧地址，承接搜索引擎和站外来路。"
          : "检测到 \(impact.affectedDraftCount) 篇文章、\(impact.referenceCount) 处旧引用。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Button {
        _ = store.updateReferencesForPendingSlugChange(draftID: impact.targetDraftID)
      } label: {
        Label(
          impact.referenceCount == 0
            ? "确认无需更新站内引用"
            : "一键更新 \(impact.referenceCount) 处引用",
          systemImage: "link.badge.plus"
        )
      }
      .workbenchProminentActionStyle()
      .accessibilityIdentifier("content-health-update-slug-references")

      Button {
        _ = store.addAliasesForPendingSlugChange(draftID: impact.targetDraftID)
      } label: {
        Label("写入 aliases 保留旧地址", systemImage: "arrowshape.turn.up.right")
      }
      .buttonStyle(.bordered)
      .disabled(!impact.conflictingAliasRoutes.isEmpty)
      .accessibilityIdentifier("content-health-add-slug-aliases")

      if !impact.conflictingAliasRoutes.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          AccessibleStatusMessage(
            message:
              "旧地址与其他文章冲突，不能写入 aliases：\(impact.conflictingAliasRoutes.joined(separator: "、"))",
            severity: .error
          )

          let conflicts = conflictingDrafts(
            for: impact.conflictingAliasRoutes, targetDraftID: impact.targetDraftID)
          ForEach(conflicts) { draft in
            Button {
              _ = store.focusDraft(draft.id, section: .writing)
            } label: {
              Label(
                "查看冲突文章：《\(draft.title.nilIfEmpty ?? draft.slug)》",
                systemImage: "arrow.right.circle")
            }
            .buttonStyle(.link)
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.risk)
            .accessibilityIdentifier("content-health-view-conflicting-draft-\(draft.id.uuidString)")
          }
        }
      } else {
        Text(String(localized: "aliases 会写入 Front Matter；是否生成 HTTP 跳转取决于当前框架或重定向插件。"))
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .background(
      WorkbenchTheme.warning.opacity(WorkbenchOpacity.noticeBackground),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
  }

  private func selectedHealthRow(
    in presentation: ContentHealthArticlePresentation
  ) -> ContentHealthArticleRowModel? {
    if let selectedHealthDraftID,
      let selected = presentation.rowByDraftID[selectedHealthDraftID]
    {
      return selected
    }
    if let selectedDraftID = store.selectedDraftID,
      let selected = presentation.rowByDraftID[selectedDraftID]
    {
      return selected
    }
    if articleGrouping == .actionQueue {
      return nextActionQueueRow(in: presentation.actionQueue)
    }
    return presentation.rows.first
  }

  private func runContentHealthQuickFix(
    _ quickFix: ContentHealthQuickFixPresentation,
    issue: PreflightIssue,
    draftID: UUID
  ) {
    guard !runningQuickFixIssueIDs.contains(issue.id) else { return }
    runningQuickFixIssueIDs.insert(issue.id)
    quickFixMessagesByIssueID[issue.id] = nil

    let task = Task { @MainActor in
      defer {
        runningQuickFixIssueIDs.remove(issue.id)
        quickFixTasksByIssueID[issue.id] = nil
      }

      switch quickFix.kind {
      case .generateImageAlt(let attachmentID):
        await generateAndApplyImageAlt(
          attachmentID: attachmentID,
          issueID: issue.id,
          draftID: draftID
        )

      case .normalizeSlug(let proposedSlug):
        normalizeDraftSlug(
          proposedSlug,
          issueID: issue.id,
          draftID: draftID
        )

      case .repairRelativePath(let target):
        repairBrokenRelativePath(
          target,
          issueID: issue.id,
          draftID: draftID
        )
      }
    }
    quickFixTasksByIssueID[issue.id] = task
  }

  private func generateAndApplyImageAlt(
    attachmentID: UUID,
    issueID: UUID,
    draftID: UUID
  ) async {
    guard let draft = store.draft(for: draftID) else {
      quickFixMessagesByIssueID[issueID] = String(localized: "文章已不存在，未执行修复。")
      return
    }

    _ = await store.generateAIImageTextSuggestions(
      draft: draft,
      targetAttachmentIDs: [attachmentID]
    )
    guard !Task.isCancelled else { return }
    guard
      var suggestion = store.aiImageTextSuggestions(for: draftID).first(where: {
        $0.attachmentID == attachmentID && !$0.altText.trimmedForPublishing.isEmpty
      })
    else {
      quickFixMessagesByIssueID[issueID] =
        store.imageActionMessage ?? String(localized: "视觉模型没有返回可用的 Alt，文章未更改。")
      return
    }

    // This QuickFix is intentionally Alt-only. Caption remains an explicit
    // editorial choice in the image workbench.
    suggestion.caption = ""
    store.applyAIImageTextSuggestion(suggestion)
    guard
      let appliedAlt = store.draft(for: draftID)?.attachments.first(where: {
        $0.id == attachmentID
      })?.altText.trimmedForPublishing.nilIfEmpty
    else {
      quickFixMessagesByIssueID[issueID] = String(localized: "Alt 回填未通过写后校验，文章未被标记为已修复。")
      return
    }

    quickFixMessagesByIssueID[issueID] = String(localized: "已回填 Alt：\(appliedAlt)")
    refreshContentHealthSnapshot()
  }

  private func normalizeDraftSlug(
    _ proposedSlug: String,
    issueID: UUID,
    draftID: UUID
  ) {
    guard var draft = store.draft(for: draftID) else {
      quickFixMessagesByIssueID[issueID] = String(localized: "文章已不存在，未执行修复。")
      return
    }
    let profile = store.profile(for: draft)
    let candidate = proposedSlug.trimmedForPublishing
    guard
      !candidate.isEmpty,
      SlugService.isValid(candidate, rule: profile.slugValidationRule)
    else {
      quickFixMessagesByIssueID[issueID] = String(localized: "生成的 Slug 不符合当前站点规则，未写入。")
      return
    }

    var candidateDraft = draft
    candidateDraft.slug = candidate
    let candidatePath = profile.markdownPath(for: candidateDraft)
    let hasConflict = store.drafts.contains { other in
      guard other.id != draft.id, other.belongs(toSiteProfileID: draft.siteProfileID) else {
        return false
      }
      return profile.markdownPath(for: other) == candidatePath
    }
    guard !hasConflict else {
      quickFixMessagesByIssueID[issueID] = String(
        localized: "标准化结果 \(candidate) 已被另一篇文章占用，未更改当前 Slug。"
      )
      return
    }

    draft.slug = candidate
    guard store.updateDraftFromEditor(draft) else {
      quickFixMessagesByIssueID[issueID] = String(localized: "文章已在另一窗口更新，本次 Slug 修复被安全拒绝。")
      return
    }
    quickFixMessagesByIssueID[issueID] = String(localized: "Slug 已标准化为 \(candidate)。")
    refreshContentHealthSnapshot()
  }

  private func repairBrokenRelativePath(
    _ target: String,
    issueID: UUID,
    draftID: UUID
  ) {
    guard let draft = store.draft(for: draftID) else {
      quickFixMessagesByIssueID[issueID] = String(localized: "文章已不存在，未执行修复。")
      return
    }
    let profile = store.profile(for: draft)
    guard let repositoryRootURL = profile.localRepositoryRootURL else {
      quickFixMessagesByIssueID[issueID] = String(localized: "请先为当前站点选择本地仓库。")
      return
    }
    guard
      let selectedURL = ContentHealthResourceSelectionPanel.chooseResource(
        repositoryRootURL: repositoryRootURL
      )
    else {
      quickFixMessagesByIssueID[issueID] = String(localized: "已取消资源选择，文章未更改。")
      return
    }

    let bodyBuffer = store.draftBodyEditorBuffer(for: draftID)
    var currentDraft = draft
    currentDraft.bodyMarkdown = bodyBuffer.bodyMarkdown
    let sameSiteDrafts = store.drafts
      .filter { $0.belongs(toSiteProfileID: draft.siteProfileID) }
      .map { source -> ArticleDraft in
        var overlaid = source
        overlaid.bodyMarkdown = store.draftBodyEditorBuffer(for: source.id).bodyMarkdown
        return overlaid
      }
    let auditDrafts = sameSiteDrafts.map { $0.id == draftID ? currentDraft : $0 }
    let report = SiteLinkAuditService().report(drafts: auditDrafts, profile: profile)
    let service = ContentHealthBrokenLinkQuickFixService()

    do {
      let resource = try service.resourcePlan(
        selectedURL: selectedURL,
        repositoryRootURL: repositoryRootURL,
        sourceRepositoryPath: draft.repositoryPath?.nilIfEmpty ?? profile.markdownPath(for: draft)
      )
      let plan = try service.replacementPlan(
        bodyMarkdown: bodyBuffer.bodyMarkdown,
        references: report.references,
        sourceDraftID: draftID,
        oldTarget: target,
        newTarget: resource.replacementTarget
      )
      let result = try service.apply(plan, to: bodyBuffer.bodyMarkdown)
      guard
        let stage = store.replaceDraftBody(
          result.bodyMarkdown,
          for: draftID,
          expectedRevision: bodyBuffer.revision
        ),
        stage.wasAccepted
      else {
        quickFixMessagesByIssueID[issueID] = String(
          localized: "正文已在另一窗口更新，本次路径修复被安全拒绝。"
        )
        return
      }
      store.flushDraftBodyEditorBuffer(for: draftID)
      guard store.draft(for: draftID)?.bodyMarkdown == result.bodyMarkdown else {
        quickFixMessagesByIssueID[issueID] = String(
          localized: "路径写回未通过校验，未标记为已修复。"
        )
        return
      }
      quickFixMessagesByIssueID[issueID] = String(
        localized:
          "已将 \(result.replacementCount) 处失效路径修复为 \(result.replacementTarget)。"
      )
      refreshContentHealthSnapshot()
    } catch let error as ContentHealthBrokenLinkQuickFixError {
      quickFixMessagesByIssueID[issueID] = brokenLinkQuickFixMessage(for: error)
    } catch {
      quickFixMessagesByIssueID[issueID] = String(
        localized: "路径修复失败：\(error.localizedDescription)"
      )
    }
  }

  private func brokenLinkQuickFixMessage(
    for error: ContentHealthBrokenLinkQuickFixError
  ) -> String {
    switch error {
    case .selectedResourceOutsideRepository:
      return String(localized: "所选文件不在当前仓库内，或符号链接指向仓库外；文章未更改。")
    case .selectedResourceDoesNotExist:
      return String(localized: "所选文件已经不存在，文章未更改。")
    case .selectedResourceIsNotRegularFile:
      return String(localized: "请选择仓库内的普通文件，而不是目录或特殊文件。")
    case .noMatchingBrokenReferences, .targetRangeDoesNotMatch, .invalidTargetRange:
      return String(localized: "正文已发生变化，原失效链接无法安全定位；请重新检查后再试。")
    case .targetIsNotRepairable, .replacementTargetIsNotLocalRelativePath:
      return String(localized: "该链接不是可由资源选择器修复的本地相对路径。")
    case .invalidSourceRepositoryPath:
      return String(localized: "文章的仓库路径无效，无法计算安全的相对资源路径。")
    }
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
    selectedDraftID: UUID?,
    profileName: String,
    duplicateMarkdownPaths: Set<String>,
    siteIssues: [PreflightIssue],
    scope: ContentHealthResolvedScope,
    wholeSiteErrorCount: Int,
    wholeSiteWarningCount: Int,
    globalBlockingSiteIssueCount: Int
  ) -> some View {
    let groups =
      articleGrouping == .actionQueue
      ? ContentHealthRootCausePresentation.groups(
        rows: rows,
        duplicateMarkdownPaths: duplicateMarkdownPaths
      )
      : articleGrouping.groups(
        rows: rows,
        profileName: profileName,
        duplicateMarkdownPaths: duplicateMarkdownPaths
      )
    let showsSiteIssuesInList = scope == .wholeSite
    let hasActionableSiteIssue =
      showsSiteIssuesInList
      && siteIssues.contains {
        $0.severity == .error || $0.severity == .warning
      }
    return VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(
          articleGrouping == .actionQueue
            ? String(localized: "按共同问题归类")
            : String(localized: "文章分组")
        )
        .font(.headline)
        Spacer()
        Text("\(rows.count) 篇")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if scope.isCurrentArticle, wholeSiteErrorCount > 0 || wholeSiteWarningCount > 0 {
        let siteSummary = String(
          localized:
            "全站检查仍会完整执行：全站汇总 \(wholeSiteErrorCount) 个错误、\(wholeSiteWarningCount) 个警告；切换到“整个站点”可查看全部。"
        )
        Label(
          siteSummary,
          systemImage: "globe.badge.chevron.backward"
        )
        .font(.callout)
        .foregroundStyle(wholeSiteErrorCount > 0 ? WorkbenchTheme.risk : WorkbenchTheme.warning)
      }

      if scope.isCurrentArticle, globalBlockingSiteIssueCount > 0 {
        let blockingMessage = String(
          localized: "其中 \(globalBlockingSiteIssueCount) 项是站点层级阻断问题；发布检查会继续阻止。"
        )
        Label(
          blockingMessage,
          systemImage: "xmark.octagon"
        )
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.risk)
      }

      if rows.isEmpty && (articleGrouping != .actionQueue || !hasActionableSiteIssue) {
        Label(emptyScopeMessage, systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
          .padding(.vertical, 12)
      } else {
        LazyVStack(alignment: .leading, spacing: 8) {
          if articleGrouping == .actionQueue, showsSiteIssuesInList {
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
                group.prioritizedCount > 0
              {
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
    .background(
      WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private var emptyScopeMessage: String {
    switch resolvedScope {
    case .currentArticle:
      return String(localized: "当前文章在此筛选下没有待处理的问题。")
    case .wholeSite:
      return String(localized: "当前筛选下没有待处理的文章问题。")
    }
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
      !expandedActionQueueGroupIDs.contains(group.id)
    else {
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
          if expandedActionQueueGroupIDs.contains(group.id) {
            expandedActionQueueGroupIDs.remove(group.id)
          } else {
            expandedActionQueueGroupIDs.insert(group.id)
          }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
      }
    }

    if group.kind == .automaticFix,
      group.totalCount > group.rows.count
    {
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

  private func conflictingDrafts(for routes: [String], targetDraftID: UUID) -> [ArticleDraft] {
    let normalized = Set(routes.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
    return store.publishing.visibleDrafts.filter { draft in
      guard draft.id != targetDraftID, !draft.isGeneralDraft else { return false }
      let slug = draft.slug.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      let aliases = Set(
        draft.aliases.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
      return normalized.contains(slug) || !aliases.isDisjoint(with: normalized)
    }
  }

  private func applySelectedAIFixFields(
    _ fields: [FrontMatterFixFieldItem],
    for preview: ContentHealthAIFixResultPreview
  ) -> ContentHealthAIFixApplyFeedback {
    guard let draftID = preview.draftID,
      var draft = store.publishing.visibleDrafts.first(where: { $0.id == draftID })
    else {
      return .failed(String(localized: "未能找到原文章，未应用任何字段。"))
    }

    let result = ContentHealthAIFixFieldPolicy.apply(fields, to: &draft)
    guard result.didApplyChanges else {
      return .failed(String(localized: "所选字段当前不能应用，文章未更改。"))
    }

    store.updateDraft(draft)
    refreshContentHealthSnapshot()
    return .applied(result)
  }
}

private struct ContentHealthSkeletonLoadingView: View {
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            skeletonBar(width: 140, height: 22)
            skeletonBar(width: 260, height: 14)
          }
          Spacer()
          skeletonBar(width: 110, height: 16)
        }

        HStack(alignment: .top, spacing: 10) {
          ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text("正在生成内容健康快照")
              .font(.caption.weight(.semibold))
            Text("正在检查 Front Matter、链接、SEO 与内容风险。当前分析未提供可显示的分阶段进度。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          Button("取消", action: cancel)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("content-health-loading-cancel")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          WorkbenchBackgroundStyle.card,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        )
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
        ForEach(0..<4) { _ in
          VStack(alignment: .leading, spacing: 8) {
            skeletonBar(width: 60, height: 12)
            skeletonBar(width: 40, height: 20)
          }
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            WorkbenchBackgroundStyle.card,
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
          )
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        ForEach(0..<3) { _ in
          HStack(spacing: 12) {
            Circle()
              .fill(Color.primary.opacity(0.08))
              .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 4) {
              skeletonBar(width: 220, height: 14)
              skeletonBar(width: 140, height: 10)
            }
            Spacer()
            skeletonBar(width: 50, height: 14)
          }
          .padding(12)
          .background(
            WorkbenchBackgroundStyle.card,
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
          )
        }
      }
    }
    .padding(WorkbenchSpacing.card)
    .frame(maxWidth: .infinity, minHeight: 360, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("正在生成内容健康快照，进度未知")
  }

  private func skeletonBar(width: CGFloat, height: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 4)
      .fill(Color.primary.opacity(0.08))
      .frame(width: width, height: height)
  }

}
