import PublishingWorkbenchCore
import SwiftUI

@MainActor
final class PublishDrawerOperationController: ObservableObject {
  @Published private(set) var isRunning = false

  private var operationTask: Task<Void, Never>?
  private var operationID = UUID()

  func start(_ operation: @escaping @MainActor () async -> Void) {
    cancel()
    let currentOperationID = UUID()
    operationID = currentOperationID
    isRunning = true
    operationTask = Task { @MainActor [weak self] in
      await operation()
      guard let self, self.operationID == currentOperationID else { return }
      self.operationTask = nil
      self.isRunning = false
    }
  }

  func cancel() {
    operationID = UUID()
    operationTask?.cancel()
    operationTask = nil
    isRunning = false
  }
}

struct PublishDrawerView: View {
  @ObservedObject var publishingFacade: WorkbenchPublishingFeatureFacade
  @ObservedObject private var drawerObservation: WorkbenchPublishDrawerObservationFacade
  @Environment(\.openSettings) private var openNativeSettings
  @Environment(\.settingsWorkspaceCommandAction) private var settingsWorkspaceCommandAction
  // 部分属性尚未迁移到 Facade，保留 store 访问，但去除 @ObservedObject 以避免全局不相关事件触发重绘
  let store: WorkbenchStore
  let onOpenReleaseHistory: () -> Void
  @Binding var isPresented: Bool
  @State private var pendingWorktreeReview: RepositoryWorktreePublishConfirmation?
  @State private var pendingBatchReview: BatchPublishReviewSnapshot?
  @State private var pendingSingleOnlinePublishReview: RemoteArticlePublicationReview?
  @State private var isOtherPublishActionsExpanded = false
  @State private var isAdvancedFlowExpanded = false
  @State private var isRemoteConflictResolverPresented = false
  @StateObject private var operationController = PublishDrawerOperationController()

  init(
    publishingFacade: WorkbenchPublishingFeatureFacade,
    store: WorkbenchStore,
    isPresented: Binding<Bool>,
    onOpenReleaseHistory: @escaping () -> Void = {}
  ) {
    self.publishingFacade = publishingFacade
    _drawerObservation = ObservedObject(wrappedValue: store.publishDrawerObservation)
    self.store = store
    self.onOpenReleaseHistory = onOpenReleaseHistory
    _isPresented = isPresented
  }

  var body: some View {
    drawerContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onAppear {
        if store.remoteRepositoryConflictSession?.isEmpty == false {
          isRemoteConflictResolverPresented = true
        }
        publishingFacade.ensureEditableDraftSelected()
        publishingFacade.runPreflight()
        if let draft = publishingFacade.selectedDraft {
          store.prepareSEOSocialPreview(for: draft)
          store.scheduleImageWorkbenchReportRefresh(for: draft)
          publishingFacade.refreshPublishPreviewInBackground(for: draft)
          store.refreshBatchPublishPlanInBackground()
          if draft.siteProfileID == store.activeProfileID,
            store.activeProfile.siteAnalytics?.isEnabled == true
          {
            store.refreshSiteAnalytics(for: draft)
          }
        }
      }
      .sheet(item: $pendingSingleOnlinePublishReview) { review in
        singleArticleOnlinePublishConfirmation(review: review)
      }
      .sheet(item: $pendingWorktreeReview) { confirmation in
        RepositoryWorktreePublishConfirmationView(
          confirmation: confirmation,
          isPublishing: store.isRemoteRepositoryPublishing,
          cancelAction: { pendingWorktreeReview = nil },
          confirmAction: {
            pendingWorktreeReview = nil
            operationController.start {
              await publishRepositoryWorktree(confirmation)
            }
          }
        )
      }
      .sheet(item: $pendingBatchReview) { review in
        RemotePublishConfirmationView(
          targetLabel: String(localized: "完整批次"),
          targetTitle: String(format: String(localized: "%d 篇文章"), review.items.count),
          preview: review.preview,
          reviewDraft: review.reviewDraft,
          batchReview: review,
          isPublishing: store.isRemoteRepositoryPublishing,
          cancelAction: { pendingBatchReview = nil },
          confirmAction: {
            pendingBatchReview = nil
            operationController.start { await publishAllChangesOnline(review: review) }
          }
        )
      }
      .sheet(isPresented: $isRemoteConflictResolverPresented) {
        if let session = store.remoteRepositoryConflictSession {
          RemoteRepositoryConflictResolverView(session: session) { path, choice, document in
            await store.resolveRemoteRepositoryConflict(
              repositoryPath: path,
              choice: choice,
              mergedDocument: document
            )
          }
          .id(session.id)
        }
      }
      .onChange(of: store.remoteRepositoryConflictSession?.id) { _, sessionID in
        if sessionID != nil {
          isRemoteConflictResolverPresented = true
        }
      }
      .onChange(of: store.canUseProtectedWorkbench) { _, allowed in
        if !allowed { dismissDrawer() }
      }
      .onChange(of: store.activeProfileID) { _, _ in dismissDrawer() }
      .onChange(of: store.selectedDraftID) { _, _ in
        operationController.cancel()
        pendingWorktreeReview = nil
        pendingSingleOnlinePublishReview = nil
        pendingBatchReview = nil
      }
      .onDisappear {
        operationController.cancel()
      }
  }

  @ViewBuilder
  private var drawerContent: some View {
    if let draft = publishingFacade.selectedDraft {
      let issues = store.preflightIssues
      VStack(spacing: 0) {
        header(draft: draft)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            publishPrimaryActions(draft: draft, issues: issues)
            unifiedPublishSummary
            publishDecisionSummary(draft: draft, issues: issues)
            postPublishAnalytics(draft: draft)
            advancedPublishOptions(draft: draft)
          }
          .padding(16)
        }
        .accessibilityIdentifier("publish-drawer-scroll")
        Divider()
        drawerFooter
      }
    } else {
      VStack(spacing: 12) {
        Image(systemName: "paperplane")
          .font(.system(size: 30))
          .foregroundStyle(.secondary)
        Text("没有可发布文章")
          .font(.headline)
        Button("关闭") {
          dismissDrawer()
        }
        .accessibilityLabel("关闭发布流程")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func header(draft: ArticleDraft) -> some View {
    HStack(spacing: 12) {
      Label("发布", systemImage: "paperplane")
        .font(.headline)

      Text(draft.title)
        .font(.callout.weight(.medium))
        .workbenchTruncatedIdentity(draft.title)

      Spacer()

      if publishingFacade.isPublishPreviewRefreshing {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("正在刷新发布预览")
      }

      Button {
        publishingFacade.runPreflight()
        store.prepareSEOSocialPreview(for: draft)
        store.scheduleImageWorkbenchReportRefresh(for: draft, force: true)
        publishingFacade.refreshPublishPreviewInBackground(for: draft)
        store.refreshBatchPublishPlanInBackground()
        if draft.siteProfileID == store.activeProfileID,
          store.activeProfile.siteAnalytics?.isEnabled == true
        {
          store.refreshSiteAnalytics(for: draft)
        }
      } label: {
        Label("刷新", systemImage: "arrow.clockwise")
      }
      .accessibilityLabel("刷新发布检查和差异")

    }
    .padding(.horizontal, WorkbenchSpacing.section)
    .padding(.vertical, 10)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("publish-drawer-header")
    .accessibilityLabel("发布流程")
    .accessibilityValue(draft.title)
  }

  private func publishDecisionSummary(
    draft: ArticleDraft,
    issues: [PreflightIssue]
  ) -> some View {
    let imageReport = store.cachedImageWorkbenchReport(for: draft)
    return VStack(alignment: .leading, spacing: 8) {
      PublishDrawerReadinessChecklist(
        preflightIssues: issues,
        imageReport: imageReport,
        isImageReportLoading: imageReport == nil || store.isImageWorkbenchReportLoading(for: draft),
        seoReport: store.seoReport(for: draft),
        socialSnapshot: store.seoSocialPreviewSnapshot(for: draft),
        isSocialPreviewStale: store.isSEOSocialPreviewStale(for: draft)
      )

      Button {
        isAdvancedFlowExpanded = true
      } label: {
        Label("查看当前文章差异", systemImage: "doc.text.magnifyingglass")
      }
      .buttonStyle(.link)
      .accessibilityHint("展开当前文章差异；完整批次会在发布确认页显示")
    }
  }

  private var unifiedPublishSummary: some View {
    let summary = UnifiedPublishSummaryPresentation.make(
      plan: store.batchPublishPlan,
      preview: store.batchRemotePublishPreviewSnapshot,
      profile: store.activeProfile,
      pendingDeletionCount: store.pendingRemoteRepositoryCleanupRequests.count
    )

    return PublishDrawerCard(title: "应用管理的文章清单", systemImage: "list.clipboard") {
      VStack(alignment: .leading, spacing: 9) {
        Text("这是单篇与仅文章批次的辅助摘要；默认的全文件发布以 Git 工作区确认页为准。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Label(
          String(
            format: String(localized: "%d 篇变更文章（含 %d 篇新建）"),
            summary.articleCount,
            summary.newArticleCount
          ),
          systemImage: "doc.on.doc"
        )

        Label(
          summary.imageChangeCount == 0
            ? String(localized: "未包含图片变更")
            : String(
              format: String(localized: "%d 张图片变更（%d 张新增，已纳入发布包）"),
              summary.imageChangeCount,
              summary.newImageCount
            ),
          systemImage: "photo.on.rectangle"
        )

        if summary.deletionCount > 0 {
          Label(
            String(
              format: String(localized: "%d 个待下线请求未纳入本次发布，请到回收站单独处理。"),
              summary.deletionCount
            ),
            systemImage: "trash"
          )
        }

        Divider()

        Label(summary.preflightTitle, systemImage: summary.preflightSystemImage)
          .foregroundStyle(
            summary.preflightSystemImage.hasPrefix("xmark")
              ? WorkbenchTheme.risk
              : WorkbenchTheme.success
          )

        Label(
          String(localized: "目标分支：\(summary.targetTitle)"),
          systemImage: "arrow.triangle.branch"
        )

        Text(summary.pipelineTitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.callout)
    }
    .accessibilityIdentifier("publish-drawer-unified-summary")
  }

  @ViewBuilder
  private func publishPrimaryActions(
    draft: ArticleDraft,
    issues: [PreflightIssue]
  ) -> some View {
    let blockingCount = issues.filter { $0.severity == .error }.count
    let localReadiness = store.localPublishReadiness
    let previewBranchPreview = store.remoteRepositoryDraftPreview(for: draft)
    let canSaveLocally =
      blockingCount == 0
      && localReadiness?.canWrite == true
      && !store.isLocalRepositoryMutationRunning
      && !operationController.isRunning
    let canPushPreviewBranch =
      canStartRemotePublish(previewBranchPreview)
      && !store.isRemoteRepositoryChecking
      && !store.isRemoteRepositoryPublishing
      && !operationController.isRunning
    let previewBranchAction = PublishDrawerPreviewBranchActionPresentation.make(
      branchName: previewBranchPreview.branchName,
      targetBranch: previewBranchPreview.targetBranch
    )

    repositoryWorktreePrimaryAction

    secondaryPublishActions(
      draft: draft,
      blockingCount: blockingCount,
      localReadiness: localReadiness,
      previewBranchPreview: previewBranchPreview,
      previewBranchAction: previewBranchAction,
      canSaveLocally: canSaveLocally,
      canPushPreviewBranch: canPushPreviewBranch
    )
  }

  private func secondaryPublishActions(
    draft: ArticleDraft,
    blockingCount: Int,
    localReadiness: LocalPublishReadiness?,
    previewBranchPreview: RemoteRepositoryPublishPreview,
    previewBranchAction: PublishDrawerPreviewBranchActionPresentation,
    canSaveLocally: Bool,
    canPushPreviewBranch: Bool
  ) -> some View {
    let plan = store.batchPublishPlan
    let batchPreview = store.batchRemotePublishPreviewSnapshot
    let batchState = batchActionState(plan: plan, preview: batchPreview)
    let canPublishBatch =
      batchPreview != nil
      && PublishDrawerBatchActionPresentation.isEnabled(batchState)

    return DisclosureGroup(isExpanded: $isOtherPublishActionsExpanded) {
      VStack(alignment: .leading, spacing: 10) {
        singleArticleSecondaryAction(draft: draft)

        Divider()

        Button {
          writeDraftToRepository(draft)
        } label: {
          Label("保存到本地", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.bordered)
        .disabled(!canSaveLocally)
        .help(localActionStatus(blockingCount: blockingCount, readiness: localReadiness))
        .accessibilityIdentifier("publish-drawer-action-save-local")

        Button {
          prepareSingleArticlePreviewBranch(draft)
        } label: {
          Label(previewBranchAction.actionTitle, systemImage: "arrow.up.forward.app")
        }
        .buttonStyle(.bordered)
        .disabled(!canPushPreviewBranch)
        .help(previewBranchActionStatus(preview: previewBranchPreview))
        .accessibilityIdentifier("publish-drawer-action-preview-branch")

        Button {
          prepareAllChangesOnlinePublish()
        } label: {
          Label("仅发布应用管理的全部文章…", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .disabled(!canPublishBatch)
        .help(PublishDrawerBatchActionPresentation.status(batchState))
        .accessibilityIdentifier("publish-drawer-action-publish-articles")

        Text(
          String(
            format: String(localized: "预览分支：%@"),
            previewBranchPreview.branchName
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

        if let promotionRecord = store.activeProfileReleaseRecords.first(where: {
          $0.draftID == draft.id
            && PreviewPromotionPresentation.eligibility(for: $0).isEligible
        }) {
          PreviewPromotionEntryButton(store: store, record: promotionRecord)
            .buttonStyle(.link)
        }
      }
      .padding(.top, 10)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Label("其他发布方式", systemImage: "ellipsis.circle")
          .font(.headline)
        Text("单篇发布、本地保存、预览分支和仅文章批次保留为次级操作。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityIdentifier("publish-drawer-secondary-actions")
  }

  private var repositoryWorktreePrimaryAction: some View {
    let profile = store.activeProfile
    let repositoryConfigured =
      profile.localRepositoryRootURL != nil
      && !profile.repoOwner.trimmedForPublishing.isEmpty
      && !profile.repoName.trimmedForPublishing.isEmpty
    let branch = profile.branch.trimmedForPublishing.nilIfEmpty ?? "main"
    let detectedChangeCount = store.repositoryReport?.changedFiles.count
    let isBusy = operationController.isRunning || store.isRemoteRepositoryPublishing

    return PublishDrawerCard(title: "发布仓库全部文件", systemImage: "shippingbox.and.arrow.backward") {
      VStack(alignment: .leading, spacing: 10) {
        Text("默认发布会审阅当前 Git 工作区的全部待提交文件，包括文章、图片、主题、配置、脚本与删除。确认后创建一次提交并推送到目标分支。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Label("目标：origin/\(branch)", systemImage: "arrow.triangle.branch")
          .font(.callout.weight(.medium))

        if let detectedChangeCount, detectedChangeCount > 0 {
          Label(
            String(format: String(localized: "当前扫描检测到 %d 个变更；确认页会重新完整扫描。"), detectedChangeCount),
            systemImage: "doc.on.doc"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          Label("打开确认页时会完整扫描所有未忽略变更。", systemImage: "magnifyingglass")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if repositoryConfigured {
          Button {
            prepareRepositoryWorktreePublish()
          } label: {
            Label("审阅并发布所有文件…", systemImage: "paperplane.fill")
          }
          .workbenchProminentActionStyle()
          .disabled(isBusy)
          .accessibilityIdentifier("publish-drawer-action-publish-all")
          .accessibilityHint("先打开完整文件清单；确认后才会提交并推送")
        } else {
          Button {
            openPublishingSettings(.repository)
          } label: {
            Label("配置代码仓库", systemImage: "gearshape")
          }
          .workbenchProminentActionStyle()
          .accessibilityIdentifier("publish-worktree-open-settings")
          .accessibilityHint("打开代码仓库设置，配置本地仓库与远端目标")
        }

        Label(
          "为保护现有 Git 状态，已有暂存内容、分支未同步、冲突、敏感文件或确认后发生变化时会停止发布。",
          systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityIdentifier("publish-worktree-primary")
  }

  @ViewBuilder
  private func singleArticleSecondaryAction(draft: ArticleDraft) -> some View {
    if let preview = store.cachedRemotePublishPreview(for: draft) {
      // A prior release must not make new local edits look already published.
      let latestRecord =
        preview.changedPaths.isEmpty
        ? latestRemoteReleaseRecord(for: draft, matching: preview.mode)
        : nil
      let journey = PublishJourneyPresentation.make(
        profile: store.profile(for: draft),
        preview: preview,
        isWebsiteDraft: draft.draft,
        isPreparing: publishingFacade.isPublishPreviewRefreshing
          || store.isRemoteRepositoryChecking
          || (operationController.isRunning && !store.isRemoteRepositoryPublishing),
        isPublishing: store.isRemoteRepositoryPublishing,
        progressStage: store.remoteRepositoryPublishProgress?.stage,
        latestRecord: latestRecord,
        deploymentSnapshot: latestRecord.flatMap { store.deploymentStatusSnapshots[$0.id] }
      )

      PublishJourneyView(
        presentation: journey,
        primaryAction: { prepareSingleArticleOnlinePublish(draft) },
        settingsAction: openPublishingSettings,
        releaseHistoryAction: openReleaseHistory
      )
    } else {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("正在准备当前文章的远端发布预览…")
          .foregroundStyle(.secondary)
      }
      .accessibilityIdentifier("publish-journey-loading")
    }
  }

  private func latestRemoteReleaseRecord(
    for draft: ArticleDraft,
    matching mode: RemoteRepositoryPublishMode
  ) -> ReleaseRecord? {
    store.activeProfileReleaseRecords.first { record in
      let includesDraft =
        record.draftID == draft.id
        || record.batchItems.contains(where: { $0.draftID == draft.id })
      guard includesDraft else { return false }
      switch (record.kind, mode) {
      case (.remoteDirectCommit, .directCommit), (.remotePreviewBranch, .previewBranch),
        (.remoteReviewRequest, .reviewRequest), (.remotePublishFailure, _):
        return true
      default:
        return false
      }
    }
  }

  private func openPublishingSettings(_ target: PublishJourneySettingsTarget) {
    let destination: SettingsTokenDestination = target == .repository ? .repository : .deployment
    SettingsNavigation.present(
      destination: .token(destination),
      workspaceAction: settingsWorkspaceCommandAction
    ) {
      openNativeSettings()
    }
  }

  private func openReleaseHistory() {
    dismissDrawer()
    onOpenReleaseHistory()
  }

  private func previewBranchActionStatus(
    preview: RemoteRepositoryPublishPreview
  ) -> String {
    if store.isRemoteRepositoryPublishing {
      return String(localized: "正在推送草稿预览分支")
    }
    if let issue = preview.blockingIssues.first {
      return issue.title
    }
    if preview.tokenAccessFailureMessage != nil {
      return String(localized: "仓库 Token 状态读取失败")
    }
    if !preview.hasToken {
      return String(localized: "请先保存仓库 Token")
    }
    if preview.accessCheck == nil {
      return String(localized: "发布时自动验证仓库权限")
    }
    if preview.accessCheck?.canWrite != true {
      return String(localized: "请先确认仓库写入权限")
    }
    return String(localized: "可推送，不改变正式发布状态")
  }

  private func localActionStatus(
    blockingCount: Int,
    readiness: LocalPublishReadiness?
  ) -> String {
    if blockingCount > 0 {
      return String(localized: "请先处理上方问题")
    }
    if store.isLocalRepositoryMutationRunning {
      return String(localized: "正在保存")
    }
    return readiness?.writeReadiness.localizedDisplayName ?? String(localized: "正在准备")
  }

  private func batchActionState(
    plan: BatchPublishPlan?,
    preview: RemoteRepositoryPublishPreview?
  ) -> PublishDrawerBatchActionPresentation.State {
    let owner = store.activeProfile.repoOwner.trimmedForPublishing
    let repository = store.activeProfile.repoName.trimmedForPublishing
    let permission: PublishDrawerBatchPermissionState
    if let accessCheck = preview?.accessCheck {
      permission = accessCheck.canWrite ? .writable : .readOnly
    } else {
      permission = .unchecked
    }
    return PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: !owner.isEmpty && !repository.isEmpty,
      hasToken: preview?.hasToken ?? store.repositoryTokenAvailability.hasToken,
      tokenAccessFailureMessage: preview?.tokenAccessFailureMessage
        ?? store.repositoryTokenAvailability.accessFailureMessage,
      permission: permission,
      blockingIssueTitle: preview?.blockingIssues.first?.title,
      hasRemoteConflict: preview?.mode == .directCommit
        && preview?.remoteRiskState == .conflict,
      publishableArticleCount: plan?.remotePublishableItems.count,
      draftSyncArticleCount: plan?.draftSyncCount ?? 0,
      pendingDeletionCount: store.pendingRemoteRepositoryCleanupRequests.count,
      changedFileCount: plan.map { preview?.changedPaths.count ?? $0.changedFileCount },
      isPlanRefreshing: store.isBatchPublishPlanRefreshing,
      isPermissionChecking: store.isRemoteRepositoryChecking,
      isPublishing: store.isRemoteRepositoryPublishing || operationController.isRunning
    )
  }

  /// An absent access check is intentionally actionable. The publish action
  /// performs the check immediately before confirmation or remote mutation.
  private func canStartRemotePublish(_ preview: RemoteRepositoryPublishPreview) -> Bool {
    preview.hasToken
      && preview.tokenAccessFailureMessage == nil
      && preview.blockingIssues.isEmpty
      && preview.accessCheck?.canWrite != false
      && (preview.mode != .directCommit || preview.remoteRiskState != .conflict)
  }

  private func postPublishAnalytics(draft: ArticleDraft) -> some View {
    PublishDrawerAnalyticsCard(
      draft: draft,
      settings: store.profile(for: draft).siteAnalytics,
      summary: store.siteAnalyticsSummary(for: draft),
      isLoading: store.isSiteAnalyticsLoading(for: draft),
      tokenAvailability: store.siteAnalyticsTokenAvailability,
      message: store.siteAnalyticsMessage,
      refreshAction: {
        store.refreshSiteAnalytics(for: draft)
      }
    )
  }

  private func advancedPublishOptions(
    draft: ArticleDraft
  ) -> some View {
    let disclosureValue =
      isAdvancedFlowExpanded
      ? String(localized: "已展开")
      : String(localized: "已折叠")
    let disclosureHint =
      isAdvancedFlowExpanded
      ? String(localized: "收起检查结果和文件差异")
      : String(localized: "展开检查结果和文件差异")

    return VStack(alignment: .leading, spacing: 0) {
      Button {
        isAdvancedFlowExpanded.toggle()
      } label: {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            Label("检查文件变化", systemImage: "doc.text.magnifyingglass")
              .font(.headline)
            Text("发布前请审阅本地文件差异。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer(minLength: 12)

          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isAdvancedFlowExpanded ? 90 : 0))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("publish-drawer-review-disclosure")
      .accessibilityLabel("检查文件变化")
      .accessibilityValue(disclosureValue)
      .accessibilityHint(disclosureHint)

      if isAdvancedFlowExpanded {
        VStack(alignment: .leading, spacing: 12) {
          diffCard(draft: draft)
        }
        .padding(.top, 10)
      }
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private var drawerFooter: some View {
    HStack(spacing: 12) {
      Button(
        operationController.isRunning
          ? String(localized: "中断流程")
          : String(localized: "关闭")
      ) {
        dismissDrawer()
      }
      .keyboardShortcut(.cancelAction)
      .accessibilityHint(
        operationController.isRunning
          ? String(localized: "停止当前发布流程并关闭发布抽屉")
          : String(localized: "关闭发布流程")
      )

      if store.isRemoteRepositoryPublishing {
        if let progress = store.remoteRepositoryPublishProgress {
          VStack(alignment: .leading, spacing: 4) {
            if let value = progress.byteProgress {
              ProgressView(value: value)
                .progressViewStyle(.linear)
            } else {
              ProgressView()
                .controlSize(.small)
            }
            Text(progress.statusDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          .frame(minWidth: 190, maxWidth: 300, alignment: .leading)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Git 推送进度")
          .accessibilityValue(progress.byteProgressDescription ?? progress.statusDescription)
        } else {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("正在发布")
          Text(String(localized: "正在发布"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      } else if let feedback = store.publishActionFeedback {
        VStack(alignment: .leading, spacing: 3) {
          Label(
            feedback.status.publishDrawerTitle,
            systemImage: feedback.status.publishDrawerSystemImage
          )
          .font(.caption.weight(.medium))
          .foregroundStyle(feedback.status.publishDrawerColor)

          Text(feedback.message)
            .font(.caption)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("publish-drawer-feedback-message")
        }
        .frame(maxWidth: 360, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("发布反馈，\(feedback.status.publishDrawerTitle)")
        .accessibilityValue(feedback.message)
      }

      Spacer()

      if store.remoteRepositoryConflictSession?.isEmpty == false {
        Button {
          isRemoteConflictResolverPresented = true
        } label: {
          Label("协调远端冲突", systemImage: "arrow.triangle.merge")
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.return, modifiers: [.command])
        .accessibilityIdentifier("publish-drawer-action-resolve-remote-conflicts")
        .accessibilityHint("打开三方对比，不会直接覆盖远端")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func diffCard(draft: ArticleDraft) -> some View {
    let preview = store.cachedLocalPublishPreview(for: draft)
    let changedDiffs = preview?.changedFileDiffs ?? []

    return PublishDrawerCard(title: "当前文章差异", systemImage: "doc.text.magnifyingglass") {
      Text("这里只显示当前文章；默认全文件发布会在确认页显示整个 Git 工作区。")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        PublishDrawerStat(
          title: "文件", value: preview.map { "\($0.fileDiffs.count)" } ?? "—",
          systemImage: "doc.on.doc", color: .secondary)
        PublishDrawerStat(
          title: "变化", value: "\(changedDiffs.count)", systemImage: "arrow.left.arrow.right",
          color: changedDiffs.isEmpty ? .secondary : WorkbenchTheme.warning)
      }

      if preview == nil {
        Label("发布快照待刷新。", systemImage: "clock.arrow.circlepath")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if changedDiffs.isEmpty {
        Label("没有待写入变化。", systemImage: "equal.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Label("已显示全部 \(changedDiffs.count) 个变化，可展开逐文件审阅。", systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)

          ForEach(Array(changedDiffs.enumerated()), id: \.element.id) { index, diff in
            PublishDrawerFileDiffRow(
              diff: diff,
              isExpandedInitially: index == 0
            )
          }
        }
      }
    }
    .accessibilityIdentifier("publish-drawer-diff")
  }

  private func writeDraftToRepository(_ draft: ArticleDraft) {
    let currentSection = publishingFacade.selectedSection
    _ = publishingFacade.focusDraft(draft.id)
    publishingFacade.refreshPublishPreviewInBackground(for: draft)
    operationController.start {
      await store.writeSelectedDraftToLocalRepository()
      guard !Task.isCancelled else { return }
      publishingFacade.selectSection(currentSection)
      publishingFacade.refreshPublishPreviewInBackground(for: draft)
    }
  }

  private func prepareRepositoryWorktreePublish() {
    operationController.start {
      guard let confirmation = await store.prepareRepositoryWorktreePublish(),
        !Task.isCancelled
      else {
        return
      }
      pendingWorktreeReview = confirmation
    }
  }

  private func publishRepositoryWorktree(
    _ confirmation: RepositoryWorktreePublishConfirmation
  ) async {
    let result = await store.publishRepositoryWorktree(confirmation)
    guard !Task.isCancelled, result != nil else { return }
    store.refreshBatchPublishPlanInBackground()
    if let draft = publishingFacade.selectedDraft {
      publishingFacade.refreshPublishPreviewInBackground(for: draft)
    }
  }

  private func prepareAllChangesOnlinePublish() {
    operationController.start {
      if store.batchRemotePublishPreviewSnapshot?.accessCheck == nil {
        guard await store.checkRepositoryTokenAccess()?.canWrite == true else { return }
      }
      guard !Task.isCancelled else { return }
      await store.refreshBatchPublishPlanAsync()
      guard !Task.isCancelled else { return }
      guard let preview = store.batchRemotePublishPreviewSnapshot,
        canStartRemotePublish(preview),
        let plan = store.batchPublishPlan,
        plan.profileID == store.activeProfileID,
        !plan.remotePublishableItems.isEmpty,
        let package = store.remotePublishPackage(for: plan)
      else {
        return
      }
      pendingBatchReview = BatchPublishReviewSnapshot(
        plan: plan,
        package: package,
        profile: store.activeProfile,
        preview: preview,
        reviewDraft: store.batchRemoteReviewDraft,
        excludedCleanupCount: store.pendingRemoteRepositoryCleanupRequests.count
      )
    }
  }

  private func prepareSingleArticleOnlinePublish(_ draft: ArticleDraft) {
    operationController.start {
      let preview = store.cachedRemotePublishPreview(for: draft)
      if preview?.accessCheck == nil {
        guard await store.checkRepositoryTokenAccess()?.canWrite == true else { return }
        guard !Task.isCancelled else { return }
        _ = await store.refreshPublishPreview(for: draft.id)
      }
      guard !Task.isCancelled else { return }
      guard let refreshedPreview = store.cachedRemotePublishPreview(for: draft),
        canStartRemotePublish(refreshedPreview)
      else { return }
      guard let review = await store.reviewRemoteArticlePublication(for: draft), !Task.isCancelled
      else {
        return
      }
      pendingSingleOnlinePublishReview = review
    }
  }

  private func publishAllChangesOnline(review: BatchPublishReviewSnapshot) async {
    let currentSection = publishingFacade.selectedSection
    await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy(
      expectedChangedPaths: Set(review.preview.changedPaths),
      expectedTarget: review.target,
      expectedReview: review.expectation
    )
    guard !Task.isCancelled else { return }
    publishingFacade.selectSection(currentSection)
    store.refreshBatchPublishPlanInBackground()
    if let draft = publishingFacade.selectedDraft {
      publishingFacade.refreshPublishPreviewInBackground(for: draft)
    }
  }

  private func publishSingleArticleOnline(_ review: RemoteArticlePublicationReview) {
    let currentSection = publishingFacade.selectedSection
    _ = publishingFacade.focusDraft(review.package.draftID)
    operationController.start {
      await store.publishReviewedRemoteArticlePublication(review)
      guard !Task.isCancelled else { return }
      publishingFacade.selectSection(currentSection)
      if let draft = store.draft(for: review.package.draftID) {
        publishingFacade.refreshPublishPreviewInBackground(for: draft)
      }
      store.refreshBatchPublishPlanInBackground()
    }
  }

  private func publishSingleArticlePreviewBranch(_ draft: ArticleDraft) async {
    let currentSection = publishingFacade.selectedSection
    _ = publishingFacade.focusDraft(draft.id)
    await store.publishSelectedDraftToPreviewBranch()
    guard !Task.isCancelled else { return }
    publishingFacade.selectSection(currentSection)
    publishingFacade.refreshPublishPreviewInBackground(for: draft)
    store.refreshBatchPublishPlanInBackground()
  }

  private func prepareSingleArticlePreviewBranch(_ draft: ArticleDraft) {
    operationController.start {
      if store.remoteRepositoryDraftPreview(for: draft).accessCheck == nil {
        guard await store.checkRepositoryTokenAccess()?.canWrite == true else { return }
        guard !Task.isCancelled else { return }
        _ = await store.refreshPublishPreview(for: draft.id)
      }
      guard !Task.isCancelled else { return }
      guard canStartRemotePublish(store.remoteRepositoryDraftPreview(for: draft)) else { return }
      await publishSingleArticlePreviewBranch(draft)
    }
  }

  private func dismissDrawer() {
    let interruptedOperation = operationController.isRunning
    operationController.cancel()
    pendingWorktreeReview = nil
    pendingSingleOnlinePublishReview = nil
    pendingBatchReview = nil
    if interruptedOperation {
      store.setPublishActionMessage(
        String(localized: "发布流程已中断；如果远端请求已经发出，请刷新仓库状态确认结果。"),
        status: .warning
      )
    }
    isPresented = false
  }

  @ViewBuilder
  private func singleArticleOnlinePublishConfirmation(review: RemoteArticlePublicationReview)
    -> some View
  {
    if let draft = store.draft(for: review.package.draftID),
      let preview = store.cachedRemotePublishPreview(for: draft)
    {
      let presentation = PublishDrawerSingleArticleActionPresentation.make(
        isWebsiteDraft: draft.draft
      )
      RemotePublishConfirmationView(
        targetLabel: draft.draft ? String(localized: "网站草稿") : String(localized: "文章"),
        targetTitle: draft.title,
        purpose: presentation.confirmationPurpose,
        preview: preview,
        reviewDraft: store.cachedRemoteReviewDraft(for: draft),
        articleReview: review,
        isPublishing: store.isRemoteRepositoryPublishing,
        cancelAction: {
          pendingSingleOnlinePublishReview = nil
        },
        confirmAction: {
          pendingSingleOnlinePublishReview = nil
          publishSingleArticleOnline(review)
        },
        synchronizedAction: {
          pendingSingleOnlinePublishReview = nil
          dismissDrawer()
          onOpenReleaseHistory()
        }
      )
    } else {
      VStack(spacing: 12) {
        Image(systemName: "clock.arrow.circlepath")
          .font(.system(size: 28))
          .foregroundStyle(.secondary)
        Text("发布预览已失效")
          .font(.headline)
        Text("请关闭确认页，刷新发布快照后重新审阅。")
          .foregroundStyle(.secondary)
        Button("关闭") {
          pendingSingleOnlinePublishReview = nil
        }
      }
      .frame(minWidth: 420, minHeight: 260)
      .padding(WorkbenchSpacing.spacious)
    }
  }

}
