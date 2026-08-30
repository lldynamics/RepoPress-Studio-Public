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
  // 部分属性尚未迁移到 Facade，保留 store 访问，但去除 @ObservedObject 以避免全局不相关事件触发重绘
  let store: WorkbenchStore
  @Binding var isPresented: Bool
  @State private var reviewedAllChangesPaths: Set<String> = []
  @State private var reviewedAllChangesTarget: RemoteRepositoryPublishTargetSnapshot?
  @State private var pendingSingleOnlinePublishDraft: ArticleDraft?
  @State private var isAdvancedFlowExpanded = false
  @State private var isRemoteConflictResolverPresented = false
  @StateObject private var operationController = PublishDrawerOperationController()

  init(
    publishingFacade: WorkbenchPublishingFeatureFacade,
    store: WorkbenchStore,
    isPresented: Binding<Bool>
  ) {
    self.publishingFacade = publishingFacade
    _drawerObservation = ObservedObject(wrappedValue: store.publishDrawerObservation)
    self.store = store
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
      .sheet(item: $pendingSingleOnlinePublishDraft) { draft in
        singleArticleOnlinePublishConfirmation(draft: draft)
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
            unifiedPublishSummary
            publishDecisionSummary(draft: draft, issues: issues)
            publishPrimaryActions(draft: draft, issues: issues)
            postPublishAnalytics(draft: draft)
            advancedPublishOptions(draft: draft)
          }
          .padding(16)
        }
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
        Label("审阅文件差异", systemImage: "doc.text.magnifyingglass")
      }
      .buttonStyle(.link)
      .accessibilityHint("展开发布文件差异")
    }
  }

  private var unifiedPublishSummary: some View {
    let summary = UnifiedPublishSummaryPresentation.make(
      plan: store.batchPublishPlan,
      preview: store.batchRemotePublishPreviewSnapshot,
      profile: store.activeProfile,
      pendingDeletionCount: store.pendingRemoteRepositoryCleanupRequests.count
    )

    return PublishDrawerCard(title: "本次发布清单", systemImage: "list.clipboard") {
      VStack(alignment: .leading, spacing: 9) {
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
              format: String(localized: "%d 篇文章将下线"),
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

  private func publishPrimaryActions(
    draft: ArticleDraft,
    issues: [PreflightIssue]
  ) -> some View {
    let blockingCount = issues.filter { $0.severity == .error }.count
    let localReadiness = store.localPublishReadiness
    let singleArticlePreview = store.cachedRemotePublishPreview(for: draft)
    let previewBranchPreview = store.remoteRepositoryDraftPreview(for: draft)
    let canSaveLocally =
      blockingCount == 0
      && localReadiness?.canWrite == true
      && !store.isLocalRepositoryMutationRunning
      && !operationController.isRunning
    let canPublishCurrentArticle =
      singleArticlePreview.map(canStartRemotePublish) == true
      && !store.isRemoteRepositoryChecking
      && !store.isRemoteRepositoryPublishing
      && !operationController.isRunning
    let canPushPreviewBranch =
      canStartRemotePublish(previewBranchPreview)
      && !store.isRemoteRepositoryChecking
      && !store.isRemoteRepositoryPublishing
      && !operationController.isRunning
    let singleArticleAction = PublishDrawerSingleArticleActionPresentation.make(
      isWebsiteDraft: draft.draft
    )
    let previewBranchAction = PublishDrawerPreviewBranchActionPresentation.make(
      branchName: previewBranchPreview.branchName,
      targetBranch: previewBranchPreview.targetBranch
    )

    return PublishDrawerCard(title: "选择操作", systemImage: "cursorarrow.click.2") {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 12)],
        spacing: 12
      ) {
        PublishDrawerActionChoice(
          title: String(localized: "保存到本地"),
          detail: String(localized: "只更新站点文件，不提交到 Git，也不会上传到网站。"),
          status: localActionStatus(
            blockingCount: blockingCount,
            readiness: localReadiness
          ),
          systemImage: "folder.badge.plus",
          tint: WorkbenchTheme.navigationSelection,
          isEnabled: canSaveLocally,
          isPrimary: false,
          actionStyle: .localSave,
          targetBadge: String(localized: "本地文件"),
          targetBadgeTint: .secondary,
          actionTitle: String(localized: "保存到本地"),
          actionSystemImage: "square.and.arrow.down",
          actionIdentifier: "publish-drawer-action-save-local"
        ) {
          writeDraftToRepository(draft)
        }

        PublishDrawerActionChoice(
          title: previewBranchAction.title,
          detail: previewBranchAction.detail,
          status: previewBranchActionStatus(preview: previewBranchPreview),
          systemImage: "arrow.triangle.branch",
          tint: WorkbenchTheme.info,
          isEnabled: canPushPreviewBranch,
          isPrimary: false,
          actionStyle: .isolatedPreview,
          targetBadge: String(
            format: String(localized: "隔离预览 · %@"),
            previewBranchPreview.branchName
          ),
          targetBadgeTint: WorkbenchTheme.info,
          actionTitle: previewBranchAction.actionTitle,
          actionSystemImage: "arrow.up.forward.app",
          actionIdentifier: "publish-drawer-action-preview-branch"
        ) {
          prepareSingleArticlePreviewBranch(draft)
        }
      }

      Button {
        prepareSingleArticleOnlinePublish(draft)
      } label: {
        Label(singleArticleAction.actionTitle, systemImage: "doc.badge.arrow.up")
      }
      .buttonStyle(.link)
      .disabled(!canPublishCurrentArticle)
      .accessibilityIdentifier("publish-drawer-action-publish-current")
      .accessibilityLabel(singleArticleAction.accessibilityLabel)
      .accessibilityHint(
        canPublishCurrentArticle
          ? singleArticleAction.enabledHint
          : singleArticleAction.disabledHint
      )
      Text(
        String(
          format: String(localized: "预览分支：%@"),
          previewBranchPreview.branchName
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .textSelection(.enabled)
      .accessibilityLabel("草稿预览分支")
      .accessibilityValue(previewBranchPreview.branchName)
    }
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
    let plan = store.batchPublishPlan
    let preview = store.batchRemotePublishPreviewSnapshot
    let actionState = batchActionState(plan: plan, preview: preview)
    let canPublish = preview != nil && PublishDrawerBatchActionPresentation.isEnabled(actionState)
    let summary = UnifiedPublishSummaryPresentation.make(
      plan: plan,
      preview: preview,
      profile: store.activeProfile,
      pendingDeletionCount: store.pendingRemoteRepositoryCleanupRequests.count
    )

    return HStack(spacing: 12) {
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
      } else {
        Button {
          prepareAllChangesOnlinePublish()
        } label: {
          Label(summary.actionTitle, systemImage: "paperplane.fill")
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!canPublish)
        .help(PublishDrawerBatchActionPresentation.status(actionState))
        .accessibilityIdentifier("publish-drawer-action-publish-all")
        .accessibilityHint(
          PublishDrawerBatchActionPresentation.accessibilityHint(
            isEnabled: canPublish,
            status: PublishDrawerBatchActionPresentation.status(actionState)
          )
        )
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func diffCard(draft: ArticleDraft) -> some View {
    let preview = store.cachedLocalPublishPreview(for: draft)
    let changedDiffs = preview?.changedFileDiffs ?? []

    return PublishDrawerCard(title: "差异", systemImage: "doc.text.magnifyingglass") {
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

  private func prepareAllChangesOnlinePublish() {
    operationController.start {
      guard let reviewedPreview = store.batchRemotePublishPreviewSnapshot else { return }
      let reviewedPaths = Set(reviewedPreview.changedPaths)
      let reviewedTarget = RemoteRepositoryPublishTargetSnapshot(
        profile: store.activeProfile,
        preview: reviewedPreview
      )
      if reviewedPreview.accessCheck == nil {
        guard await store.checkRepositoryTokenAccess()?.canWrite == true else { return }
      }
      guard !Task.isCancelled else { return }
      await store.refreshBatchPublishPlanAsync()
      guard !Task.isCancelled else { return }
      guard let preview = store.batchRemotePublishPreviewSnapshot,
        canStartRemotePublish(preview),
        let plan = store.batchPublishPlan,
        !plan.remotePublishableItems.isEmpty
          || !store.pendingRemoteRepositoryCleanupRequests.isEmpty
      else {
        return
      }
      let refreshedTarget = RemoteRepositoryPublishTargetSnapshot(
        profile: store.activeProfile,
        preview: preview
      )
      guard Set(preview.changedPaths) == reviewedPaths,
        refreshedTarget == reviewedTarget
      else {
        store.setPublishActionMessage(
          String(localized: "发布清单或目标已变化，已停止写入。请审阅刷新后的清单再发布。"),
          status: .warning
        )
        return
      }
      reviewedAllChangesPaths = reviewedPaths
      reviewedAllChangesTarget = reviewedTarget
      await publishAllChangesOnline()
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
      pendingSingleOnlinePublishDraft = draft
    }
  }

  private func publishAllChangesOnline() async {
    let currentSection = publishingFacade.selectedSection
    await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy(
      expectedChangedPaths: reviewedAllChangesPaths,
      expectedTarget: reviewedAllChangesTarget
    )
    reviewedAllChangesTarget = nil
    guard !Task.isCancelled else { return }
    publishingFacade.selectSection(currentSection)
    store.refreshBatchPublishPlanInBackground()
    if let draft = publishingFacade.selectedDraft {
      publishingFacade.refreshPublishPreviewInBackground(for: draft)
    }
  }

  private func publishSingleArticleOnline(_ draft: ArticleDraft) {
    let currentSection = publishingFacade.selectedSection
    _ = publishingFacade.focusDraft(draft.id)
    operationController.start {
      await store.publishSelectedDraftOnlineUsingPreferredStrategy()
      guard !Task.isCancelled else { return }
      publishingFacade.selectSection(currentSection)
      publishingFacade.refreshPublishPreviewInBackground(for: draft)
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
    pendingSingleOnlinePublishDraft = nil
    reviewedAllChangesTarget = nil
    if interruptedOperation {
      store.setPublishActionMessage(
        String(localized: "发布流程已中断；如果远端请求已经发出，请刷新仓库状态确认结果。"),
        status: .warning
      )
    }
    isPresented = false
  }

  @ViewBuilder
  private func singleArticleOnlinePublishConfirmation(draft: ArticleDraft) -> some View {
    if let preview = store.cachedRemotePublishPreview(for: draft) {
      let presentation = PublishDrawerSingleArticleActionPresentation.make(
        isWebsiteDraft: draft.draft
      )
      RemotePublishConfirmationView(
        targetLabel: draft.draft ? String(localized: "网站草稿") : String(localized: "文章"),
        targetTitle: draft.title,
        purpose: presentation.confirmationPurpose,
        preview: preview,
        reviewDraft: store.cachedRemoteReviewDraft(for: draft),
        isPublishing: store.isRemoteRepositoryPublishing,
        cancelAction: {
          pendingSingleOnlinePublishDraft = nil
        },
        confirmAction: {
          pendingSingleOnlinePublishDraft = nil
          publishSingleArticleOnline(draft)
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
          pendingSingleOnlinePublishDraft = nil
        }
      }
      .frame(minWidth: 420, minHeight: 260)
      .padding(WorkbenchSpacing.spacious)
    }
  }

}
