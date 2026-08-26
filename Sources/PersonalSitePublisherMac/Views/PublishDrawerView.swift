import PublishingWorkbenchCore
import SwiftUI

struct PublishDrawerView: View {
  @ObservedObject var publishingFacade: WorkbenchPublishingFeatureFacade
  // 部分属性尚未迁移到 Facade，保留 store 访问，但去除 @ObservedObject 以避免全局不相关事件触发重绘
  let store: WorkbenchStore
  @Binding var isPresented: Bool
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @State private var isAllChangesPublishConfirmationPresented = false
  @State private var reviewedAllChangesPaths: Set<String> = []
  @State private var pendingSingleOnlinePublishDraft: ArticleDraft?
  @State private var isAdvancedFlowExpanded = false

  var body: some View {
    drawerContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      publishingFacade.ensureEditableDraftSelected()
      publishingFacade.runPreflight()
      if let draft = publishingFacade.selectedDraft {
        store.prepareSEOSocialPreview(for: draft)
        store.scheduleImageWorkbenchReportRefresh(for: draft)
        publishingFacade.refreshPublishPreviewInBackground(for: draft)
        store.refreshBatchPublishPlanInBackground()
        if draft.siteProfileID == store.activeProfileID,
           store.activeProfile.siteAnalytics?.isEnabled == true {
          store.refreshSiteAnalytics(for: draft)
        }
      }
    }
    .sheet(isPresented: $isAllChangesPublishConfirmationPresented) {
      allChangesOnlinePublishConfirmation
    }
    .sheet(item: $pendingSingleOnlinePublishDraft) { draft in
      singleArticleOnlinePublishConfirmation(draft: draft)
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
          isPresented = false
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
           store.activeProfile.siteAnalytics?.isEnabled == true {
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

  private func publishPrimaryActions(
    draft: ArticleDraft,
    issues: [PreflightIssue]
  ) -> some View {
    let blockingCount = issues.filter { $0.severity == .error }.count
    let localReadiness = store.localPublishReadiness
    let singleArticlePreview = store.cachedRemotePublishPreview(for: draft)
    let previewBranchPreview = store.remoteRepositoryDraftPreview(for: draft)
    let remotePreview = store.batchRemotePublishPreviewSnapshot
    let batchPlan = store.batchPublishPlan
    let batchActionState = batchActionState(plan: batchPlan, preview: remotePreview)
    let canSaveLocally = blockingCount == 0
      && localReadiness?.canWrite == true
      && !store.isLocalRepositoryMutationRunning
    let canPublishOnline = PublishDrawerBatchActionPresentation.isEnabled(batchActionState)
    let canPublishCurrentArticle = singleArticlePreview?.canPublish == true
      && !store.isRemoteRepositoryChecking
      && !store.isRemoteRepositoryPublishing
    let canPushPreviewBranch = previewBranchPreview.canPublish
      && !store.isRemoteRepositoryChecking
      && !store.isRemoteRepositoryPublishing
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
          title: PublishDrawerBatchActionPresentation.title,
          detail: PublishDrawerBatchActionPresentation.detail,
          status: PublishDrawerBatchActionPresentation.status(batchActionState),
          systemImage: "globe",
          tint: WorkbenchTheme.success,
          isEnabled: canPublishOnline,
          isPrimary: true,
          actionStyle: .formalRelease,
          targetBadge: String(
            format: String(localized: "正式发布 · %@"),
            store.activeProfile.branch.nilIfEmpty ?? "main"
          ),
          targetBadgeTint: WorkbenchTheme.success,
          actionTitle: PublishDrawerBatchActionPresentation.actionTitle,
          actionSystemImage: "paperplane.fill",
          actionIdentifier: "publish-drawer-action-publish-all"
        ) {
          prepareAllChangesOnlinePublish()
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
          publishSingleArticlePreviewBranch(draft)
        }
      }

      Button {
        pendingSingleOnlinePublishDraft = draft
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
      isPublishing: store.isRemoteRepositoryPublishing
    )
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
    let disclosureValue = isAdvancedFlowExpanded
      ? String(localized: "已展开")
      : String(localized: "已折叠")
    let disclosureHint = isAdvancedFlowExpanded
      ? String(localized: "收起检查结果和文件差异")
      : String(localized: "展开检查结果和文件差异")

    return VStack(alignment: .leading, spacing: 0) {
      Button {
        if accessibilityReduceMotion {
          isAdvancedFlowExpanded.toggle()
        } else {
          withAnimation(WorkbenchMotion.deliberate) {
            isAdvancedFlowExpanded.toggle()
          }
        }
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
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(WorkbenchSpacing.section)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private var drawerFooter: some View {
    HStack(spacing: 12) {
      Button("关闭") {
        isPresented = false
      }
      .keyboardShortcut(.cancelAction)

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
      } else if let message = store.publishActionMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func diffCard(draft: ArticleDraft) -> some View {
    let preview = store.cachedLocalPublishPreview(for: draft)
    let changedDiffs = preview?.changedFileDiffs ?? []

    return PublishDrawerCard(title: "差异", systemImage: "doc.text.magnifyingglass") {
      HStack(spacing: 8) {
        PublishDrawerStat(title: "文件", value: preview.map { "\($0.fileDiffs.count)" } ?? "—", systemImage: "doc.on.doc", color: .secondary)
        PublishDrawerStat(title: "变化", value: "\(changedDiffs.count)", systemImage: "arrow.left.arrow.right", color: changedDiffs.isEmpty ? .secondary : WorkbenchTheme.warning)
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
    Task {
      await store.writeSelectedDraftToLocalRepository()
      publishingFacade.selectSection(currentSection)
      publishingFacade.refreshPublishPreviewInBackground(for: draft)
    }
  }

  private func prepareAllChangesOnlinePublish() {
    Task {
      await store.refreshBatchPublishPlanAsync()
      guard let preview = store.batchRemotePublishPreviewSnapshot,
            preview.canPublish,
            let plan = store.batchPublishPlan,
            !plan.remotePublishableItems.isEmpty
              || !store.pendingRemoteRepositoryCleanupRequests.isEmpty else {
        return
      }
      reviewedAllChangesPaths = Set(preview.changedPaths)
      isAllChangesPublishConfirmationPresented = true
    }
  }

  private func publishAllChangesOnline() {
    let currentSection = publishingFacade.selectedSection
    Task {
      await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy(
        expectedChangedPaths: reviewedAllChangesPaths
      )
      publishingFacade.selectSection(currentSection)
      store.refreshBatchPublishPlanInBackground()
      if let draft = publishingFacade.selectedDraft {
        publishingFacade.refreshPublishPreviewInBackground(for: draft)
      }
    }
  }

  private func publishSingleArticleOnline(_ draft: ArticleDraft) {
    let currentSection = publishingFacade.selectedSection
    _ = publishingFacade.focusDraft(draft.id)
    Task {
      await store.publishSelectedDraftOnlineUsingPreferredStrategy()
      publishingFacade.selectSection(currentSection)
      publishingFacade.refreshPublishPreviewInBackground(for: draft)
      store.refreshBatchPublishPlanInBackground()
    }
  }

  private func publishSingleArticlePreviewBranch(_ draft: ArticleDraft) {
    let currentSection = publishingFacade.selectedSection
    _ = publishingFacade.focusDraft(draft.id)
    Task {
      await store.publishSelectedDraftToPreviewBranch()
      publishingFacade.selectSection(currentSection)
      publishingFacade.refreshPublishPreviewInBackground(for: draft)
      store.refreshBatchPublishPlanInBackground()
    }
  }

  @ViewBuilder
  private var allChangesOnlinePublishConfirmation: some View {
    if let preview = store.batchRemotePublishPreviewSnapshot,
       let plan = store.batchPublishPlan {
      RemotePublishConfirmationView(
        targetLabel: String(localized: "发布范围"),
        targetTitle: allChangesTargetTitle(plan: plan),
        preview: preview,
        reviewDraft: store.batchRemoteReviewDraft,
        isPublishing: store.isRemoteRepositoryPublishing,
        cancelAction: {
          isAllChangesPublishConfirmationPresented = false
        },
        confirmAction: {
          isAllChangesPublishConfirmationPresented = false
          publishAllChangesOnline()
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
          isAllChangesPublishConfirmationPresented = false
        }
      }
      .frame(minWidth: 420, minHeight: 260)
      .padding(WorkbenchSpacing.spacious)
    }
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

  private func allChangesTargetTitle(plan: BatchPublishPlan) -> String {
    let publishCount = plan.remotePublishableItems.count
    let cleanupCount = store.pendingRemoteRepositoryCleanupRequests.count
    if cleanupCount == 0 {
      return String(
        format: String(localized: "全部可发布文章（%d 篇）"),
        publishCount
      )
    }
    if publishCount == 0 {
      return String(
        format: String(localized: "全部待下线文章（%d 篇）"),
        cleanupCount
      )
    }
    return String(
      format: String(localized: "发布 %d 篇并下线 %d 篇文章"),
      publishCount,
      cleanupCount
    )
  }

}
