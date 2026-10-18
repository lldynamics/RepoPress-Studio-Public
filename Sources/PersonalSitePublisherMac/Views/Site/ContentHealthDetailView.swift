import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct ContentHealthDetailView: View {
  @Environment(\.workbenchAccentColor) var workbenchAccentColor
  let store: WorkbenchStore
  @Binding var filter: ContentHealthContextFilter
  let sidebarProjection: ContentHealthSidebarProjection
  let inspectorActions: ContentHealthInspectorActions?
  @StateObject private var healthState: WorkbenchContentHealthFeatureFacade
  @StateObject private var aiActionState: WorkbenchMetadataSummaryFeatureFacade
  @ObservedObject private var maintenanceState: WorkbenchSiteMaintenanceFeatureFacade
  @State private var healthSnapshot: ContentHealthSnapshot?
  @State private var severityFilter: ContentHealthSeverityFilter = .all
  @State private var sourceFilter: ContentHealthSourceFilter = .all
  @State private var aiFixFilter: ContentHealthAIFixFilter = .all
  @State private var articleGrouping: ContentHealthArticleGrouping = .actionQueue
  @State private var healthSnapshotTask: Task<Void, Never>?
  @State private var articlePresentationTask: Task<Void, Never>?
  @State private var healthSnapshotErrorMessage: String?
  @State private var isHealthSnapshotRefreshing = false
  @State private var wasHealthSnapshotCancelled = false
  @State private var healthSnapshotRequestID = UUID()
  @State private var articlePresentationRequestID = UUID()
  @State var aiFixTask: Task<Void, Never>?
  @State var aiFixRequestID: UUID?
  @State var aiFixResultPreview: ContentHealthAIFixResultPreview?
  @State private var articlePresentation: ContentHealthArticlePresentation?
  @State private var issueSearch = ""
  @State private var localIssueSelection: ContentHealthIssueSelection?
  private let boundIssueSelection: Binding<ContentHealthIssueSelection?>?
  @State private var inspectorActionOwnerID = UUID()
  @State private var slugReferenceReview: SlugReferenceUpdateReview?
  @State private var slugReferenceResult: SlugReferenceUpdateResult?
  @State private var showsSlugRecoveryVersions = false
  @State private var showsSuppressionSettings = false
  @State private var suppressionErrorMessage: String?
  @State private var scannedHealthVersion: Int?

  init(
    store: WorkbenchStore,
    filter: Binding<ContentHealthContextFilter>,
    sidebarProjection: ContentHealthSidebarProjection,
    selectedIssue: Binding<ContentHealthIssueSelection?>? = nil,
    inspectorActions: ContentHealthInspectorActions? = nil
  ) {
    self.store = store
    _filter = filter
    self.sidebarProjection = sidebarProjection
    boundIssueSelection = selectedIssue
    self.inspectorActions = inspectorActions
    _healthState = StateObject(
      wrappedValue: WorkbenchContentHealthFeatureFacade(store: store)
    )
    _aiActionState = StateObject(wrappedValue: WorkbenchMetadataSummaryFeatureFacade(store: store))
    _maintenanceState = ObservedObject(wrappedValue: store.siteMaintenance)
    _articleGrouping = State(initialValue: Self.preferredGrouping(for: filter.wrappedValue))
    _sourceFilter = State(initialValue: Self.preferredSource(for: filter.wrappedValue))
    _aiFixFilter = State(initialValue: Self.preferredAIFixFilter(for: filter.wrappedValue))
  }

  var body: some View {
    detailContent
      .onAppear { installInspectorActions() }
      .onChange(of: healthSnapshot?.id) { _, _ in installInspectorActions() }
      .onChange(of: aiActionState.isActionRunning) { _, _ in
        inspectorActions?.updateAIState(ownerID: inspectorActionOwnerID)
      }
      .onChange(of: maintenanceState.isAIChatRunning) { _, _ in
        inspectorActions?.updateAIState(ownerID: inspectorActionOwnerID)
      }
      .task {
        refreshContentHealthSnapshotIfNeeded()
        await store.refreshSiteMaintenanceSnapshot()
      }
      .onChange(of: healthState.snapshotVersion) { _, _ in
        refreshContentHealthSnapshot()
      }
      .onChange(of: filter) { _, newFilter in
        applyPreferredGrouping(for: newFilter)
        if newFilter != .overview {
          sourceFilter = Self.preferredSource(for: newFilter)
          aiFixFilter = Self.preferredAIFixFilter(for: newFilter)
        }
        rebuildArticlePresentation()
        refreshContentHealthSnapshotIfNeeded()
      }
      .onChange(of: severityFilter) { _, _ in
        rebuildArticlePresentation()
      }
      .onChange(of: sourceFilter) { _, source in
        if source == .maintenance {
          severityFilter = .all
        }
      }
      .onDisappear {
        inspectorActions?.clear(ownerID: inspectorActionOwnerID)
        cancelContentHealthWork(showsCancelledState: false)
      }
      .sheet(item: $aiFixResultPreview) { preview in
        ContentHealthAIFixResultPreviewSheet(preview: preview) { selectedFields in
          applySelectedAIFixFields(selectedFields, for: preview)
        }
      }
      .sheet(item: $slugReferenceReview) { review in
        SlugReferenceUpdateReviewSheet(review: review) {
          applyReviewedSlugReferences(review)
        }
      }
      .sheet(isPresented: $showsSlugRecoveryVersions) {
        DraftLifecycleCenterView(store: store)
      }
      .sheet(isPresented: $showsSuppressionSettings) {
        ContentHealthSuppressionSheet(
          store: store, profileID: store.activeProfileID,
          healthState: healthState
        )
      }
      .onChange(of: store.activeProfileID) {
        showsSuppressionSettings = false
        suppressionErrorMessage = nil
        issueSelection.wrappedValue = nil
        issueSearch = ""
        slugReferenceReview = nil
        slugReferenceResult = nil
        cancelAIFixTask()
        inspectorActions?.clear(ownerID: inspectorActionOwnerID)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("内容健康")
      .accessibilityIdentifier("content-health-workspace")
  }

  private func applyPreferredGrouping(for newFilter: ContentHealthContextFilter) {
    articleGrouping = Self.preferredGrouping(for: newFilter)
  }

  @ViewBuilder
  private var detailContent: some View {
    ScrollView(.vertical, showsIndicators: true) {
      VStack(alignment: .leading, spacing: WorkbenchSpacing.content) {
        if let result = slugReferenceResult {
          SlugReferenceUpdateResultView(result: result) { draftID in
            guard store.focusDraft(draftID, section: .contentHealth) else { return }
            showsSlugRecoveryVersions = true
          }
        }
        healthSnapshotContent
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("content-health-stage-overview")
      }
      .workbenchOperationalPageLayout()
    }
  }

  @ViewBuilder
  private var healthSnapshotContent: some View {
    if let healthSnapshotErrorMessage {
      snapshotFailureState(healthSnapshotErrorMessage)
    } else if wasHealthSnapshotCancelled {
      snapshotCancelledState
    } else if let snapshot = healthSnapshot, snapshot.profileID == store.activeProfileID,
      let presentation = articlePresentation,
      presentation.matches(
        snapshotID: snapshot.id,
        filter: filter,
        severityFilter: severityFilter
      )
    {
      content(snapshot, presentation: presentation)
    } else {
      ContentHealthSkeletonLoadingView(cancel: cancelContentHealthSnapshotRefresh)
    }
  }

  private var issueSelection: Binding<ContentHealthIssueSelection?> {
    boundIssueSelection ?? $localIssueSelection
  }

  private func content(
    _ snapshot: ContentHealthSnapshot,
    presentation: ContentHealthArticlePresentation
  ) -> some View {
    let visibleRows =
      sourceFilter.includesArticles
      ? presentation.rows.filter { aiFixFilter.includes(canUseAI: $0.aiFixItem != nil) } : []
    let visibleSiteIssues =
      sourceFilter.includesSite && aiFixFilter != .fixable
      ? presentation.siteIssues : []
    let maintenanceItems = visibleMaintenanceItems
    let summary = ContentHealthSiteSummary(
      snapshot: snapshot, maintenanceSnapshot: currentMaintenanceSnapshot)
    let issueRows = ContentHealthIssueListProjection.rows(
      articles: visibleRows, siteIssues: visibleSiteIssues, maintenanceItems: maintenanceItems,
      grouping: articleGrouping, profileName: snapshot.profileName, search: issueSearch
    )
    let isAllClear =
      maintenanceScanPresentation == .ready
      && ContentHealthAllClear.isAllClear(
        errorCount: snapshot.errorCount, warningCount: snapshot.warningCount,
        siteIssueCount: snapshot.sitePreflightIssues.count,
        aiFixCount: snapshot.aiFixQueueItems.count,
        maintenanceItemCount: currentMaintenanceSnapshot?.report.actionItems.count
      )

    return VStack(alignment: .leading, spacing: WorkbenchSpacing.content) {
      ContentHealthPrimaryHeader(
        snapshot: snapshot, summary: summary, isRefreshing: isHealthSnapshotRefreshing,
        showsFilters: !isAllClear, contextFilter: $filter,
        severity: $severityFilter, source: $sourceFilter, aiFix: $aiFixFilter,
        grouping: $articleGrouping, search: $issueSearch,
        recheck: {
          refreshContentHealthSnapshot()
          Task { await store.refreshSiteMaintenanceSnapshot() }
        },
        recheckExternalLinks: {
          refreshContentHealthSnapshot()
          Task { await store.refreshSiteMaintenanceSnapshot(force: true) }
        }
      )

      ContentHealthSuppressionControls(
        configuredCount: store.contentHealthSuppressions.count,
        matchedCount: snapshot.suppressedIssues.count,
        canSaveBaseline: !isHealthSnapshotRefreshing
          && scannedHealthVersion == healthState.snapshotVersion
          && snapshot.contentHealthSummaries.contains {
            $0.issues.contains(where: \.canSuppressInContentHealth)
          },
        manage: { showsSuppressionSettings = true },
        saveBaseline: {
          applySuppressionChange {
            store.saveContentHealthBaseline(
              profileID: snapshot.profileID, expectedVersion: scannedHealthVersion ?? -1
            )
          }
        }
      )
      if let suppressionErrorMessage {
        AccessibleStatusMessage(message: suppressionErrorMessage, severity: .error)
      }

      if severityFilter == .all && sourceFilter.includesArticles {
        ContentHealthOptionalNotices(summaries: snapshot.contentHealthSummaries) {
          issue, draftID, mode in
          applySuppressionChange {
            store.suppressContentHealthIssue(
              issue, draftID: draftID, profileID: snapshot.profileID,
              mode: mode, expectedVersion: scannedHealthVersion ?? -1
            )
          }
        }
      }

      if issueRows.isEmpty {
        filteredEmptyState(snapshot)
      } else {
        issueList(issueRows)
      }
      if !issueRows.isEmpty { maintenanceScanStatus }
      if severityFilter == .all {
        let notes = visibleSiteIssues.filter {
          $0.severity == .info
            && (issueSearch.isEmpty
              || ($0.title + " " + $0.message).localizedStandardContains(issueSearch))
        }
        if !notes.isEmpty {
          VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
            Label("站点提示", systemImage: "info.circle")
              .font(.workbenchSectionTitle)
            ForEach(notes) { note in
              Text(verbatim: [note.title, note.message].joined(separator: " · "))
                .font(.workbenchSupporting)
                .foregroundStyle(.workbenchSecondary)
            }
          }
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("content-health-site-notes")
        }
      }
    }
    .onChange(of: issueRows, initial: true) { _, rows in
      issueSelection.wrappedValue = ContentHealthIssueListProjection.reconciled(
        issueSelection.wrappedValue, rows: rows
      )
    }
  }

  private func issueList(_ rows: [ContentHealthIssueSelection]) -> some View {
    ContentHealthIssueListView(
      rows: rows, selection: issueSelection,
      locate: focusContentHealthIssue, runAIFix: runAIFixQueueItem,
      isAIRunning: maintenanceState.isAIChatRunning || store.ai.isActionRunning,
      openMaintenanceDraft: { draftID in
        store.selectDraft(draftID)
        store.selectSection(.writing)
      },
      copyMaintenance: { item in
        ClipboardWriter.copy(
          item.clipboardMarkdown, successMessage: String(localized: "已复制维护任务。")
        ) { message, status in store.setPublishActionMessage(message, status: status) }
      },
      recordMaintenance: { store.recordMaintenanceOperation(for: $0) },
      sendMaintenanceToAI: { item in Task { await store.sendMaintenanceActionToAI(item) } },
      suppress: { issue, draftID, mode in
        applySuppressionChange {
          store.suppressContentHealthIssue(
            issue, draftID: draftID, profileID: healthSnapshot?.profileID ?? store.activeProfileID,
            mode: mode, expectedVersion: scannedHealthVersion ?? -1
          )
        }
      }
    )
  }

  @ViewBuilder
  private func filteredEmptyState(_ snapshot: ContentHealthSnapshot) -> some View {
    ContentHealthFilteredEmptyState(
      snapshot: snapshot,
      isMaintenancePending: sourceFilter.includesMaintenance && severityFilter == .all
        && maintenanceScanPresentation != .ready,
      isFiltered: severityFilter != .all || sourceFilter != .all
        || aiFixFilter != .all || !issueSearch.isEmpty,
      maintenanceContent: maintenanceScanStatus
    )
  }

  private var maintenanceScanPresentation: ContentHealthMaintenanceScanPresentation.Status {
    ContentHealthMaintenanceScanPresentation.status(
      hasSnapshot: currentMaintenanceSnapshot != nil,
      isRefreshing: maintenanceState.isRefreshing,
      isStale: maintenanceState.isStale,
      errorMessage: maintenanceState.errorMessage
    )
  }

  @ViewBuilder
  private var maintenanceScanStatus: some View {
    if sourceFilter.includesMaintenance && severityFilter == .all {
      switch maintenanceScanPresentation {
      case .ready:
        EmptyView()
      case .failed(let errorMessage):
        WorkbenchStateView(
          presentation: WorkbenchStatePresentation(kind: .failure(reason: errorMessage)),
          density: .inline,
          actions: WorkbenchStateActions(
            primary: WorkbenchStateAction(
              title: "重试维护扫描", systemImage: "arrow.clockwise",
              action: { Task { await store.refreshSiteMaintenanceSnapshot(force: true) } }
            ))
        )
      case .stale:
        HStack(spacing: WorkbenchSpacing.control) {
          Text("维护扫描结果已过期，请重新检查。")
            .font(.workbenchSupporting)
            .foregroundStyle(.workbenchSecondary)
          Button("重试维护扫描") {
            Task { await store.refreshSiteMaintenanceSnapshot(force: true) }
          }
        }
      case .loading:
        Label("正在后台扫描维护事项…", systemImage: "arrow.clockwise")
          .font(.workbenchSupporting)
          .foregroundStyle(.workbenchSecondary)
      }
      if currentMaintenanceSnapshot != nil && maintenanceScanPresentation != .ready {
        Text("维护事项为上次扫描结果。")
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
      }
    }
  }

  private var visibleMaintenanceItems: [MaintenanceActionItem] {
    guard sourceFilter.includesMaintenance && severityFilter == .all,
      maintenanceState.snapshot?.profileID == store.activeProfileID
    else { return [] }
    return currentMaintenanceSnapshot?.report.actionItems.filter {
      aiFixFilter.includes(canUseAI: $0.draftID != nil)
    } ?? []
  }

  private var currentMaintenanceSnapshot: SiteMaintenanceSnapshot? {
    guard let snapshot = maintenanceState.snapshot, snapshot.profileID == store.activeProfileID
    else { return nil }
    return snapshot
  }

  private func applySuppressionChange(_ change: () -> Bool) {
    suppressionErrorMessage = nil
    if !change() {
      suppressionErrorMessage = String(localized: "忽略设置未能保存，请重新检查或确认存储状态后重试。")
    }
  }

  private func refreshContentHealthSnapshotIfNeeded() {
    guard !wasHealthSnapshotCancelled else { return }
    if healthSnapshot == nil {
      refreshContentHealthSnapshot()
    } else if articlePresentation == nil && articlePresentationTask == nil {
      rebuildArticlePresentation()
    }
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
          severityFilter == expectedSeverityFilter
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
        issueSelection.wrappedValue = nil
        healthSnapshotErrorMessage = error.localizedDescription
      }
    }
  }

  func refreshContentHealthSnapshot() {
    healthSnapshotTask?.cancel()
    let expectedProfileID = store.activeProfile.id
    let expectedProfileName = store.activeProfile.name
    let expectedVersion = healthState.snapshotVersion
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
          report: report
        )
        guard !Task.isCancelled,
          healthSnapshotRequestID == requestID,
          healthState.snapshotVersion == expectedVersion,
          snapshot.profileID == expectedProfileID,
          store.activeProfile.id == expectedProfileID
        else { return }
        healthSnapshot = snapshot
        scannedHealthVersion = expectedVersion
        sidebarProjection.replace(
          profileID: snapshot.profileID,
          aiFixQueueItems: snapshot.aiFixQueueItems,
          issueCount: ContentHealthSiteSummary(
            snapshot: snapshot, maintenanceSnapshot: nil
          ).issueCount
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
        sidebarProjection.cancelLoading()
        wasHealthSnapshotCancelled = true
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
        issueSelection.wrappedValue = nil
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
    issueSelection.wrappedValue = nil
    cancelAIFixTask()
    sidebarProjection.cancelLoading()
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

  func cancelAIFixTask() {
    aiFixRequestID = UUID()
    aiFixTask?.cancel()
    aiFixTask = nil
    aiFixResultPreview = nil
  }

  private var snapshotCancelledState: some View {
    ContentHealthSnapshotCancelledState(refresh: refreshContentHealthSnapshot)
  }

  private func snapshotFailureState(_ errorMessage: String) -> some View {
    ContentHealthSnapshotFailureState(
      errorMessage: errorMessage, retry: refreshContentHealthSnapshot)
  }

  private func prepareSlugReferenceReview(draftID: UUID) {
    guard let target = store.draft(for: draftID),
      let impact = store.slugChangeImpact(for: draftID)
    else { return }
    var sources: [UUID: (draft: ArticleDraft, body: String, path: String)] = [:]
    for sourceID in Set(impact.references.map(\.sourceDraftID)) {
      guard let draft = store.draft(for: sourceID) else { continue }
      sources[sourceID] = (
        draft, store.draftBodyEditorBuffer(for: sourceID).bodyMarkdown,
        store.profile(for: draft).markdownPath(for: draft)
      )
    }
    guard
      let review = SlugReferenceUpdateReview(
        profileID: store.activeProfileID,
        impact: impact, targetSlug: target.slug, sources: sources)
    else {
      slugReferenceResult = SlugReferenceUpdateResult(
        application: SlugChangeApplicationResult(
          wasApplied: false, message: String(localized: "引用已发生变化，请重新检查后再审阅。")), review: nil)
      return
    }
    slugReferenceReview = review
  }

  private func applyReviewedSlugReferences(_ review: SlugReferenceUpdateReview) {
    slugReferenceReview = nil
    guard store.activeProfileID == review.profileID else { return }
    let result = store.updateReferencesForPendingSlugChange(
      draftID: review.impact.targetDraftID,
      expectedImpact: review.impact,
      expectedTargetSlug: review.targetSlug
    )
    slugReferenceResult = SlugReferenceUpdateResult(application: result, review: review)
    if result.wasApplied {
      refreshContentHealthSnapshot()
    }
  }

  private func slugChangeResolutionCard(_ impact: SlugChangeImpact) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("Slug 变更处理", systemImage: "arrow.triangle.branch")
        .font(.workbenchBody.weight(.semibold))
      Text("\(impact.oldRoutes.joined(separator: "、")) → \(impact.newRoute)")
        .font(.workbenchMetadata.monospaced())
        .foregroundStyle(.workbenchSecondary)
        .textSelection(.enabled)
      Text(
        impact.referenceCount == 0
          ? "站内未检测到旧引用；仍可保留旧地址，承接搜索引擎和站外来路。"
          : "检测到 \(impact.affectedDraftCount) 篇文章、\(impact.referenceCount) 处旧引用。"
      )
      .font(.workbenchMetadata)
      .foregroundStyle(.workbenchSecondary)

      Button {
        prepareSlugReferenceReview(draftID: impact.targetDraftID)
      } label: {
        Label(
          impact.referenceCount == 0
            ? String(localized: "确认无需更新站内引用")
            : String(localized: "审阅 \(impact.referenceCount) 处引用更新…"),
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
            .font(.workbenchMetadata)
            .foregroundStyle(WorkbenchTheme.risk)
            .accessibilityIdentifier("content-health-view-conflicting-draft-\(draft.id.uuidString)")
          }
        }
      } else {
        Text(String(localized: "aliases 会写入 Front Matter；是否生成 HTTP 跳转取决于当前框架或重定向插件。"))
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
      }
    }
    .padding(WorkbenchSpacing.card)
    .background(
      WorkbenchTheme.warning.opacity(WorkbenchOpacity.noticeBackground),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
  }

  private func installInspectorActions() {
    guard let inspectorActions else { return }
    guard let snapshot = healthSnapshot, snapshot.profileID == store.activeProfileID else {
      inspectorActions.clear(ownerID: inspectorActionOwnerID)
      return
    }
    inspectorActions.install(
      ownerID: inspectorActionOwnerID, generatedAt: snapshot.generatedAt,
      handlers: ContentHealthInspectorActions.Handlers(
        isCurrent: { store.activeProfileID == snapshot.profileID },
        isAIRunning: { maintenanceState.isAIChatRunning || store.ai.isActionRunning },
        locate: focusContentHealthIssue,
        runAIFix: runAIFixQueueItem,
        openMaintenanceDraft: { draftID in
          _ = store.focusDraft(draftID, section: .writing)
          store.setInspectorPresented(true)
        },
        copyMaintenance: { item in
          ClipboardWriter.copy(
            item.clipboardMarkdown, successMessage: String(localized: "已复制维护任务。")
          ) { message, status in store.setPublishActionMessage(message, status: status) }
        },
        recordMaintenance: { _ = store.recordMaintenanceOperation(for: $0) },
        sendMaintenanceToAI: { item in Task { await store.sendMaintenanceActionToAI(item) } },
        slugResolution: { draftID in
          let hasDuplicatePath =
            articlePresentation.map { presentation in
              guard let row = presentation.rowByDraftID[draftID] else { return false }
              return presentation.duplicateMarkdownPaths.contains(row.normalizedMarkdownPath)
            } ?? false
          let impact = snapshot.slugChangeImpacts[draftID]
          guard hasDuplicatePath || impact != nil else { return nil }
          return AnyView(
            VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
              if hasDuplicatePath {
                AccessibleStatusMessage(
                  message: "多篇文章映射到同一路径，请先修正路径冲突再发布。", severity: .warning)
              }
              if let impact { slugChangeResolutionCard(impact) }
            })
        }
      )
    )
  }

}
