import PublishingGitCore
import PublishingWorkbenchCore
import SwiftUI

@MainActor
final class PublishDrawerOperationController: ObservableObject {
  @Published private(set) var isRunning = false

  private var operationTask: Task<Void, Never>?
  private var operationID = UUID()

  @discardableResult
  func startIfIdle(_ operation: @escaping @MainActor () async -> Void) -> Bool {
    guard !isRunning else { return false }
    start(operation)
    return true
  }

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
  @State private var pendingWorktreeReview: RepositoryWorktreePublishConfirmation?
  @State private var pendingWorktreePushRetryReview: RepositoryWorktreePushRetryConfirmation?
  @State private var pendingBatchReview: BatchPublishReviewSnapshot?
  @State private var pendingSingleOnlinePublishDraft: ArticleDraft?
  @State private var scope: PublishScope = .repository
  @State private var completedWorktreeRelease: ReleaseRecord?
  @State private var showsReleaseHistory = false
  @State private var completedDeploymentStatus: DeploymentStatusSnapshot?
  @State private var isAdvancedFlowExpanded = false
  @State private var isAnalyticsSetupExpanded = false
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
          operationController.start {
            await refreshPublishingStateFromRemote(draftID: draft.id)
          }
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
      .sheet(item: $pendingWorktreeReview) { confirmation in
        RepositoryWorktreePublishConfirmationView(
          confirmation: confirmation,
          isPublishing: store.isRemoteRepositoryPublishing || operationController.isRunning,
          cancelAction: { pendingWorktreeReview = nil },
          confirmAction: {
            operationController.start {
              guard await publishRepositoryWorktree(confirmation) else { return }
              pendingWorktreeReview = nil
            }
          },
          feedback: store.publishActionFeedback,
          reviewAgainAction: prepareRepositoryWorktreePublish
        )
      }
      .sheet(item: $pendingWorktreePushRetryReview) { confirmation in
        RepositoryWorktreePushRetryConfirmationView(
          confirmation: confirmation,
          isPublishing: store.isRemoteRepositoryPublishing || operationController.isRunning,
          cancelAction: { pendingWorktreePushRetryReview = nil },
          confirmAction: {
            operationController.start {
              guard await retryRepositoryWorktreePush(confirmation) else { return }
              pendingWorktreePushRetryReview = nil
            }
          },
          feedback: store.publishActionFeedback,
          reviewAgainAction: prepareRepositoryWorktreePushRetry
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
          RemoteRepositoryConflictResolverView(session: session) { plan in
            await store.resolveRemoteRepositoryConflicts(plan: plan)
          }
          .id(session.id)
        }
      }
      .sheet(isPresented: $showsReleaseHistory) {
        VStack(spacing: 0) {
          ReleaseHistoryDetailView(store: store)
          Button("关闭") { showsReleaseHistory = false }.padding()
        }
        .frame(minWidth: 760, minHeight: 600)
      }
      .onChange(of: store.activeProfileID) {
        completedWorktreeRelease = nil
        pendingWorktreeReview = nil
        pendingWorktreePushRetryReview = nil
        pendingBatchReview = nil
        pendingSingleOnlinePublishDraft = nil
        scope = .repository
      }
      .onChange(of: store.remoteRepositoryConflictSession?.id) { _, sessionID in
        isRemoteConflictResolverPresented = sessionID != nil
      }
      .onDisappear {
        operationController.cancel()
        pendingWorktreeReview = nil
        pendingWorktreePushRetryReview = nil
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
            scopePicker
            switch scope {
            case .repository:
              repositoryWorktreePrimaryAction
            case .managedArticles:
              unifiedPublishSummary
              managedArticlesPrimaryAction
            case .currentArticle:
              currentArticlePrimaryAction(draft: draft)
              publishDecisionSummary(draft: draft, issues: issues)
              advancedPublishOptions(draft: draft)
            }
            completedWorktreeResult
            DisclosureGroup(String(localized: "本地保存与隔离预览")) {
              publishPrimaryActions(draft: draft, issues: issues)
            }
            if store.profile(for: draft).siteAnalytics?.isEnabled == true {
              postPublishAnalytics(draft: draft)
            } else {
              DisclosureGroup(String(localized: "发布后阅读回流"), isExpanded: $isAnalyticsSetupExpanded) {
                postPublishAnalytics(draft: draft)
              }
              .accessibilityIdentifier("publish-drawer-analytics-setup")
            }
          }
          .padding(16)
        }
        Divider()
        drawerFooter
      }
    } else {
      VStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            repositoryWorktreePrimaryAction
            completedWorktreeResult
            VStack(alignment: .leading, spacing: 6) {
              Text("没有可发布文章")
                .font(.headline)
              Label("当前没有可选文章；仍可发布图片、配置、主题、CSS/脚本等仓库变更。", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }
          .padding(16)
        }
        Divider()
        drawerFooter
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func header(draft: ArticleDraft) -> some View {
    let title = scope == .currentArticle ? draft.title : store.activeProfile.name
    return HStack(spacing: 12) {
      Label("发布", systemImage: "paperplane")
        .font(.headline)

      Text(title)
        .font(.callout.weight(.medium))
        .workbenchTruncatedIdentity(title)

      Spacer()

      if publishingFacade.isPublishPreviewRefreshing {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("正在刷新发布预览")
      }

      Button {
        guard !store.isRemoteRepositoryPublishing else { return }
        operationController.startIfIdle {
          store.prepareSEOSocialPreview(for: draft)
          store.scheduleImageWorkbenchReportRefresh(for: draft, force: true)
          await refreshPublishingStateFromRemote(draftID: draft.id)
          if draft.siteProfileID == store.activeProfileID,
            store.activeProfile.siteAnalytics?.isEnabled == true
          {
            store.refreshSiteAnalytics(for: draft)
          }
        }
      } label: {
        Label("刷新", systemImage: "arrow.clockwise")
      }
      .disabled(operationController.isRunning || store.isRemoteRepositoryPublishing)
      .help(
        operationController.isRunning || store.isRemoteRepositoryPublishing
          ? String(localized: "当前操作完成后可刷新发布检查和差异")
          : String(localized: "刷新发布检查和差异")
      )
      .accessibilityLabel("刷新发布检查和差异")

    }
    .padding(.horizontal, WorkbenchSpacing.section)
    .padding(.vertical, 10)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("publish-drawer-header")
    .accessibilityLabel("发布流程")
    .accessibilityValue(title)
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

  private var scopePicker: some View {
    Picker("发布范围", selection: $scope) {
      ForEach(PublishScope.allCases) { item in
        Text(item.title).tag(item)
      }
    }
    .pickerStyle(.segmented)
    .disabled(operationController.isRunning || store.isRemoteRepositoryPublishing)
    .accessibilityIdentifier("publish-drawer-scope")
  }

  private var managedArticlesPrimaryAction: some View {
    let state = batchActionState(
      plan: store.batchPublishPlan, preview: store.batchRemotePublishPreviewSnapshot
    )
    return Button {
      prepareAllChangesOnlinePublish()
    } label: {
      Label("审阅并发布文章变更…", systemImage: "doc.on.doc")
    }
    .workbenchProminentActionStyle()
    .disabled(store.batchRemotePublishPreviewSnapshot == nil || !PublishDrawerBatchActionPresentation.isEnabled(state))
    .help(PublishDrawerBatchActionPresentation.status(state))
    .accessibilityIdentifier("publish-drawer-action-publish-articles")
  }

  private func currentArticlePrimaryAction(draft: ArticleDraft) -> some View {
    let preview = store.cachedRemotePublishPreview(for: draft)
    let action = PublishDrawerSingleArticleActionPresentation.make(isWebsiteDraft: draft.draft)
    return PublishDrawerCard(title: "当前文章发布清单", systemImage: "doc.text") {
      Text(draft.title).font(.headline)
      if let preview {
        Label("目标分支：\(preview.targetBranch)", systemImage: "arrow.triangle.branch")
        Text("本次仅包含当前文章及其发布包中的资源；具体文件与发布策略将在确认页展示。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Button {
        prepareSingleArticleOnlinePublish(draft)
      } label: {
        Label(action.actionTitle, systemImage: "doc.badge.arrow.up")
      }
      .workbenchProminentActionStyle()
      .disabled(
        preview.map(canStartRemotePublish) != true || store.isRemoteRepositoryChecking
          || store.isRemoteRepositoryPublishing || operationController.isRunning
      )
      .accessibilityIdentifier("publish-drawer-action-publish-current")
      .accessibilityLabel(action.accessibilityLabel)
    }
  }

  @ViewBuilder
  private var completedWorktreeResult: some View {
    if let record = completedWorktreeRelease, record.siteProfileID == store.activeProfileID {
      PublishDrawerCard(title: "本次发布结果", systemImage: "checkmark.icloud") {
        Label("Git 推送已确认", systemImage: "checkmark.circle")
          .foregroundStyle(WorkbenchTheme.success)
        Text("\(record.branchName ?? "") · \(record.shortCommitSHA ?? "")")
          .font(.caption.monospaced()).textSelection(.enabled)
        Text("网站部署与文章页面需要继续验证。")
          .font(.callout).foregroundStyle(.secondary)
        if record.markdownPath == nil {
          Text("本次没有已确认的文章目标，仅检查站点部署。")
            .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button("检查部署与页面") {
            operationController.start {
              let status = await store.refreshDeploymentStatus(for: record)
              guard !Task.isCancelled, store.activeProfileID == record.siteProfileID else { return }
              completedDeploymentStatus = status
            }
          }
          .disabled(!store.canCheckDeploymentStatus(for: record) || operationController.isRunning)
          .help(store.deploymentStatusReadiness(for: record).nextStep)
          .accessibilityIdentifier("publish-result-check-deployment")
          Button("查看发布记录") { showsReleaseHistory = true }
            .accessibilityIdentifier("publish-result-open-records")
        }
        if !store.canCheckDeploymentStatus(for: record) {
          Text(store.deploymentStatusReadiness(for: record).nextStep)
            .font(.caption).foregroundStyle(.secondary)
        }
        if let status = completedDeploymentStatus, status.releaseRecordID == record.id {
          Label(status.title, systemImage: status.level.systemImage)
            .font(.callout.weight(.medium))
          Text(status.message).font(.caption).textSelection(.enabled)
          ForEach(status.signals) { signal in
            VStack(alignment: .leading, spacing: 4) {
              Label(signal.title, systemImage: signal.level.systemImage)
              Text(signal.message).font(.caption).foregroundStyle(.secondary)
              if let text = signal.urlText, let url = URL(string: text) {
                Button("打开检查页面") { ExternalURLOpener.open(url) }
                  .buttonStyle(.link)
              }
            }
          }
        }
      }
      .accessibilityIdentifier("publish-worktree-result")
    }
  }

  private var unifiedPublishSummary: some View {
    let summary = UnifiedPublishSummaryPresentation.make(
      plan: store.batchPublishPlan,
      preview: store.batchRemotePublishPreviewSnapshot,
      profile: store.activeProfile,
      pendingDeletionCount: store.pendingRemoteRepositoryCleanupRequests.count
    )

    return PublishDrawerCard(title: "应用文章发布清单", systemImage: "list.clipboard") {
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

    PublishDrawerCard(title: "其他发布方式", systemImage: "cursorarrow.click.2") {
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

  private var repositoryWorktreePrimaryAction: some View {
    let profile = store.activeProfile
    let repositoryConfigured =
      profile.localRepositoryRootURL != nil
      && !profile.repoOwner.trimmedForPublishing.isEmpty
      && !profile.repoName.trimmedForPublishing.isEmpty
    let branch = profile.branch.trimmedForPublishing.nilIfEmpty ?? "main"
    let detectedChangeCount = store.repositoryReport?.changedFiles.count
    let isBusy = operationController.isRunning || store.isRemoteRepositoryPublishing

    return PublishDrawerCard(title: "发布仓库全部变更", systemImage: "shippingbox.and.arrow.backward") {
      VStack(alignment: .leading, spacing: 10) {
        Text("默认流程会审阅 Git 工作区的全部待提交变更：文章、图片、配置、主题、CSS/脚本，以及删除和重命名。确认前会冻结并重新扫描完整清单。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Label("目标：origin/\(branch)", systemImage: "arrow.triangle.branch")
          .font(.callout.weight(.medium))

        if let detectedChangeCount, detectedChangeCount > 0 {
          Label("当前扫描检测到 \(detectedChangeCount) 个变更；确认页会重新完整扫描。", systemImage: "doc.on.doc")
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
            Label("审阅并发布仓库全部变更…", systemImage: "paperplane.fill")
          }
          .workbenchProminentActionStyle()
          .disabled(isBusy)
          .accessibilityIdentifier("publish-drawer-action-publish-all")
          .accessibilityLabel("审阅并发布仓库全部变更")
          .accessibilityHint("先冻结完整 Git 工作区清单；确认后创建一次非强制推送的提交")

          Button {
            prepareRepositoryWorktreePushRetry()
          } label: {
            Label("检查并重试未推送提交…", systemImage: "arrow.up.circle")
          }
          .buttonStyle(.link)
          .disabled(isBusy)
          .accessibilityIdentifier("publish-drawer-action-retry-push")
          .accessibilityHint("重新审阅本地领先提交，仅在远端基线未变时非强制重试推送")
        } else {
          Label("请先配置本地仓库与 origin，才能审阅完整工作区。", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.warning)
        }
      }
    }
    .accessibilityIdentifier("publish-worktree-primary")
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
      blockingIssueTitle: preview?.blockingIssues.first(where: {
        !isAuthoritativeRemotePreflightIssue($0)
      })?.title,
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
      && !preview.blockingIssues.contains(where: {
        !isAuthoritativeRemotePreflightIssue($0)
      })
      && preview.accessCheck?.canWrite != false
  }

  private func isAuthoritativeRemotePreflightIssue(_ issue: PreflightIssue) -> Bool {
    issue.field == "remoteBaseline"
      || (issue.field == "repository"
        && (issue.title == String(localized: "远端同路径变更")
          || issue.title == String(localized: "远端状态待确认")))
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
    return HStack(spacing: 12) {
      Button(
        operationController.isRunning
          ? String(localized: "中断流程")
          : String(localized: "关闭")
      ) {
        dismissDrawer()
      }
      .keyboardShortcut(.cancelAction)
      .disabled(store.isRemoteRepositoryPublishing)
      .accessibilityHint(
        store.isRemoteRepositoryPublishing
          ? String(localized: "正在提交并推送，完成前不能关闭发布抽屉")
          : operationController.isRunning
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
      Text("这里只显示当前文章；发布前还会打开完整批次确认页。")
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
  ) async -> Bool {
    guard let result = await store.publishRepositoryWorktree(confirmation), !Task.isCancelled else {
      return false
    }
    completedWorktreeRelease = store.releaseRecords.first {
      $0.commitSHA == result.commitSHA && $0.siteProfileID == store.activeProfileID
    }
    store.refreshBatchPublishPlanInBackground()
    if let draft = publishingFacade.selectedDraft {
      publishingFacade.refreshPublishPreviewInBackground(for: draft)
    }
    return true
  }

  private func prepareRepositoryWorktreePushRetry() {
    operationController.start {
      guard let confirmation = await store.prepareRepositoryWorktreePushRetry(),
        !Task.isCancelled
      else {
        return
      }
      pendingWorktreePushRetryReview = confirmation
    }
  }

  private func retryRepositoryWorktreePush(
    _ confirmation: RepositoryWorktreePushRetryConfirmation
  ) async -> Bool {
    guard let result = await store.retryRepositoryWorktreePush(confirmation),
      !Task.isCancelled
    else {
      return false
    }
    completedWorktreeRelease = store.releaseRecords.first {
      $0.commitSHA == result.commitSHA && $0.siteProfileID == store.activeProfileID
    }
    store.refreshBatchPublishPlanInBackground()
    if let draft = publishingFacade.selectedDraft {
      publishingFacade.refreshPublishPreviewInBackground(for: draft)
    }
    return true
  }

  private func prepareAllChangesOnlinePublish() {
    operationController.start {
      guard await store.prepareBatchOnlinePublish() else { return }
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
      guard await store.prepareSelectedDraftOnlinePublish(draftID: draft.id) else { return }
      guard !Task.isCancelled else { return }
      guard let refreshedPreview = store.cachedRemotePublishPreview(for: draft),
        canStartRemotePublish(refreshedPreview)
      else { return }
      pendingSingleOnlinePublishDraft = draft
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
    _ = await store.refreshRepositoryStateForPublishing()
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
      _ = await store.refreshRepositoryStateForPublishing()
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
    _ = await store.refreshRepositoryStateForPublishing()
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
    guard !store.isRemoteRepositoryPublishing else {
      store.setPublishActionMessage(
        String(localized: "正在提交并推送，请等待操作完成。"),
        status: .warning
      )
      return
    }
    let interruptedOperation = operationController.isRunning
    operationController.cancel()
    pendingWorktreeReview = nil
    pendingWorktreePushRetryReview = nil
    pendingSingleOnlinePublishDraft = nil
    pendingBatchReview = nil
    if interruptedOperation {
      store.setPublishActionMessage(
        String(localized: "发布流程已中断；如果远端请求已经发出，请刷新仓库状态确认结果。"),
        status: .warning
      )
    }
    isPresented = false
  }

  private func refreshPublishingStateFromRemote(draftID: UUID) async {
    let result = await store.refreshRepositoryStateForPublishing()
    guard !Task.isCancelled else { return }
    publishingFacade.runPreflight()
    _ = await store.refreshPublishPreview(for: draftID)
    await store.refreshBatchPublishPlanAsync()
    guard !Task.isCancelled else { return }
    switch result?.status {
    case .succeeded:
      store.setPublishActionMessage(
        String(localized: "已获取远端最新状态并刷新发布清单。"),
        status: .success
      )
    case .skipped:
      store.setPublishActionMessage(
        result?.message ?? String(localized: "当前仓库未设置 upstream，发布时仍会通过远端 API 核对。"),
        status: .information
      )
    case .failed:
      store.setPublishActionMessage(
        String(
          format: String(localized: "本地 fetch 失败；发布时仍会通过远端 API 逐文件核对：%@"),
          result?.message ?? String(localized: "未知错误")
        ),
        status: .warning
      )
    case nil:
      store.setPublishActionMessage(
        String(localized: "站点或仓库在刷新期间发生变化，请重试。"),
        status: .warning
      )
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

}
