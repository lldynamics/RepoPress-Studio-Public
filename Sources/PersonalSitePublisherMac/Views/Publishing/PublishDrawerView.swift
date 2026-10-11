import PublishingGitCore
import PublishingWorkbenchCore
import SwiftUI

struct PublishDrawerView: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  @Environment(\.openSettings) private var openSettings
  @Environment(\.settingsWorkspaceCommandAction) private var settingsWorkspaceCommandAction
  @ObservedObject var publishingFacade: WorkbenchPublishingFeatureFacade
  @ObservedObject private var drawerObservation: WorkbenchPublishDrawerObservationFacade
  // 部分属性尚未迁移到 Facade，保留 store 访问，但去除 @ObservedObject 以避免全局不相关事件触发重绘
  let store: WorkbenchStore
  let draftID: UUID?
  let requestGeneration: Int
  let isActive: Bool
  private let initialScope: PublishScope
  private let initialCompletedReleaseRecordID: UUID?
  private let onNavigateIssue: ((UUID, PublishReadinessTarget, PublishScope) -> Void)?
  private let onRequestAIFix: ((UUID, PublishReadinessTarget) -> Void)?
  @Binding var isPresented: Bool
  @State private var pendingWorktreeReview: RepositoryWorktreePublishConfirmation?
  @State private var pendingWorktreePushRetryReview: RepositoryWorktreePushRetryConfirmation?
  @State private var pendingBatchReview: BatchPublishReviewSnapshot?
  @State private var pendingSingleReview: SinglePublishReviewSnapshot?
  @State private var scope: PublishScope = .repository
  @State private var completedReleaseRecordID: UUID?
  @State private var showsReleaseHistory = false
  @State private var isAdvancedFlowExpanded = false
  @State private var isRemoteConflictResolverPresented = false
  @State private var selectedIssueID: String?
  @State private var batchPlanConsumerID = UUID()
  @StateObject private var operationController = PublishDrawerOperationController()

  init(
    publishingFacade: WorkbenchPublishingFeatureFacade,
    store: WorkbenchStore,
    draftID: UUID?,
    isPresented: Binding<Bool>,
    initialScope: PublishScope = .repository,
    requestGeneration: Int = 0,
    isActive: Bool = true,
    initialCompletedReleaseRecordID: UUID? = nil,
    onNavigateIssue: ((UUID, PublishReadinessTarget, PublishScope) -> Void)? = nil,
    onRequestAIFix: ((UUID, PublishReadinessTarget) -> Void)? = nil
  ) {
    self.publishingFacade = publishingFacade
    _drawerObservation = ObservedObject(wrappedValue: store.publishDrawerObservation)
    self.store = store
    self.draftID = draftID
    self.requestGeneration = requestGeneration
    self.isActive = isActive
    self.initialScope = initialScope
    self.initialCompletedReleaseRecordID = initialCompletedReleaseRecordID
    self.onNavigateIssue = onNavigateIssue
    self.onRequestAIFix = onRequestAIFix
    _isPresented = isPresented
    _scope = State(initialValue: initialScope)
    _completedReleaseRecordID = State(initialValue: initialCompletedReleaseRecordID)
  }

  var body: some View {
    drawerContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onAppear {
        updateActivity()
      }
      .sheet(item: $pendingSingleReview) { review in
        PublishDrawerSingleArticleConfirmation(
          review: review,
          isPublishing: store.isRemoteRepositoryPublishing,
          cancelAction: { pendingSingleReview = nil },
          confirmAction: {
            pendingSingleReview = nil
            publishSingleArticleOnline(review)
          }
        )
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
          feedback: store.publishDrawerFeedback,
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
          feedback: store.publishDrawerFeedback,
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
          ReleaseHistoryDetailView(store: store, focusedRecordID: completedReleaseRecordID)
          Button("关闭") { showsReleaseHistory = false }.padding()
        }
        .frame(minWidth: 760, minHeight: 600)
      }
      .onChange(of: store.activeProfileID) {
        completedReleaseRecordID = nil
        pendingWorktreeReview = nil
        pendingWorktreePushRetryReview = nil
        pendingBatchReview = nil
        pendingSingleReview = nil
        scope = scope == .currentArticle ? .currentArticle : .repository
        selectedIssueID = nil
        updateActivity()
      }
      .onChange(of: store.remoteRepositoryConflictSession?.id) { _, sessionID in
        isRemoteConflictResolverPresented = isActive && sessionID != nil
      }
      .onChange(of: isActive) { updateActivity() }
      .publishDrawerWindowState(operationController, isActive: isActive)
      .onChange(of: requestGeneration) {
        guard !store.isRemoteRepositoryPublishing else { return }
        scope = initialScope
        completedReleaseRecordID = initialCompletedReleaseRecordID
        updateActivity()
      }
      .onChange(of: draftID) {
        if scope == .currentArticle { selectedIssueID = nil }
        updateActivity()
      }
      .articlePreflightRefresh(
        store: store, draftID: currentDraft?.id, isEnabled: isActive && scope == .currentArticle
      )
      .onDisappear {
        store.setBatchPublishPlanConsumer(batchPlanConsumerID, isActive: false)
        if !store.isRemoteRepositoryPublishing { operationController.cancel() }
        pendingWorktreeReview = nil
        pendingWorktreePushRetryReview = nil
      }
  }

  private var currentDraft: ArticleDraft? {
    PublishDrawerDraftPresentation.resolve(
      draftID: draftID, profileID: store.activeProfileID,
      draft: draftID.flatMap { store.draft(for: $0) })
  }

  private func updateActivity() {
    store.setBatchPublishPlanConsumer(batchPlanConsumerID, isActive: isActive)
    pendingWorktreeReview = nil
    pendingWorktreePushRetryReview = nil
    pendingBatchReview = nil
    pendingSingleReview = nil
    isRemoteConflictResolverPresented = false
    guard !store.isRemoteRepositoryPublishing else { return }
    operationController.cancel()
    guard isActive else { return }
    isRemoteConflictResolverPresented = store.remoteRepositoryConflictSession?.isEmpty == false
    store.refreshBatchPublishPlanInBackground()
    if let draft = currentDraft {
      store.prepareSEOSocialPreview(for: draft)
      store.scheduleImageWorkbenchReportRefresh(for: draft)
      publishingFacade.refreshPublishPreviewInBackground(for: draft)
      operationController.start { await refreshPublishingStateFromRemote(draftID: draft.id) }
    }
  }

  private var readiness: PublishDrawerReadinessPresentation {
    if scope == .currentArticle {
      guard let draft = currentDraft else { return .init(sections: []) }
      return ArticlePublishAttention.readiness(store: store, draft: draft)
    }
    return .batch(
      plan: store.batchPublishPlan, profileID: store.activeProfileID,
      isRefreshing: store.isBatchPublishPlanRefreshing,
      isIssueIgnored: { draftID, issue in
        store.draft(for: draftID).map { store.isSuppressedInContentHealth(issue, draft: $0) }
          ?? false
      })
  }

  private var pendingIssueCount: Int {
    ArticlePublishAttention.pendingCount(
      readiness: readiness, accountStatus: accountPresentation.1)
  }

  private var drawerContent: some View {
    let checks = readiness
    return VStack(spacing: 0) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
          scopePicker
          workflowSteps(checks: checks)
          let pendingCount = pendingIssueCount
          if pendingCount > 0 {
            Text(String(format: String(localized: "需要处理 · %d"), pendingCount))
              .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          }
          connectionIssue
          PublishDrawerReadinessChecklist(
            presentation: checks, selectedIssueID: $selectedIssueID,
            onNavigate: onNavigateIssue.map { callback in
              { issue in
                guard let draftID = issue.draftID else { return }
                callback(draftID, issue.target, scope)
              }
            },
            onRequestAIFix: onRequestAIFix.map { callback in
              { issue in
                guard let draftID = issue.draftID else { return }
                callback(draftID, issue.target)
              }
            },
            store: store
          )
          if scope == .repository {
            repositoryWorktreePrimaryAction
          } else if scope == .managedArticles {
            unifiedPublishSummary
          } else if let draft = currentDraft {
            advancedPublishOptions(draft: draft)
          }
          completedWorktreeResult
          DisclosureGroup(String(localized: "高级发布方式")) {
            Button(
              scope == .managedArticles
                ? String(localized: "返回全部变更") : String(localized: "仅应用管理的文章…")
            ) {
              scope = scope == .managedArticles ? .repository : .managedArticles
            }
            .buttonStyle(.link)
            .disabled(operationController.isRunning || store.isRemoteRepositoryPublishing)
            .accessibilityIdentifier("publish-inspector-managed-articles")
            if let draft = currentDraft {
              publishPrimaryActions(
                draft: draft, issues: publishingFacade.preflightIssues(for: draft))
            }
          }
          .disclosureGroupStyle(
            WorkbenchDisclosureGroupStyle(toggleIdentifier: "publish-drawer-local-actions")
          )
        }
        .padding(WorkbenchSpacing.control)
      }
      .accessibilityIdentifier("publish-drawer-scroll-content")
      Divider()
      drawerFooter
    }
    .background(WorkbenchSurface.inspector)
  }

  private var header: some View {
    let title =
      scope == .currentArticle
      ? currentDraft?.title ?? String(localized: "没有可发布文章") : store.activeProfile.name
    return HStack(spacing: WorkbenchSpacing.tight) {
      Text(title)
        .font(.callout.weight(.medium))
        .workbenchTruncatedIdentity(title)
      Spacer(minLength: WorkbenchSpacing.tight)
      Button {
        updateActivity()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .disabled(operationController.isRunning || store.isRemoteRepositoryPublishing)
      .help(
        operationController.isRunning || store.isRemoteRepositoryPublishing
          ? String(localized: "当前操作完成后可刷新发布检查和差异")
          : String(localized: "刷新发布检查和差异")
      )
      .accessibilityLabel("刷新发布检查和差异")
    }
    .padding(WorkbenchSpacing.control)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("publish-drawer-header")
    .accessibilityLabel("发布流程")
    .accessibilityValue(title)
  }

  private var scopePicker: some View {
    Picker(
      "发布范围",
      selection: Binding(
        get: { scope == .currentArticle ? PublishScope.currentArticle : .repository },
        set: { scope = $0 }
      )
    ) {
      Text("当前文章").tag(PublishScope.currentArticle)
      Text("全部变更").tag(PublishScope.repository)
    }
    .pickerStyle(.segmented)
    .disabled(operationController.isRunning || store.isRemoteRepositoryPublishing)
    .accessibilityIdentifier("publish-drawer-scope")
  }

  private func workflowSteps(checks: PublishDrawerReadinessPresentation) -> some View {
    let account = accountPresentation
    let fileCount =
      scope == .repository
      ? store.repositoryReport?.changedFiles.count
      : scope == .managedArticles
        ? store.batchRemotePublishPreviewSnapshot?.changedPaths.count
        : currentDraft.flatMap { store.cachedLocalPublishPreview(for: $0)?.changedFileDiffs.count }
    let record = store.releaseRecords.first {
      $0.id == completedReleaseRecordID && $0.siteProfileID == store.activeProfileID
    }
    let deployment = record.flatMap { store.deploymentStatusSnapshot(for: $0) }
    let steps = PublishDrawerWorkflowStep.make(
      readiness: checks, accountDetail: account.0, accountStatus: account.1,
      changedFileCount: fileCount, isPublishing: store.isRemoteRepositoryPublishing,
      deploymentDetail: record.map {
        store.deploymentStatusSnapshot(for: $0)?.title
          ?? String(localized: "提交已完成，等待核验部署")
      },
      isReviewRequest: scope != .repository
        && store.activeProfile.repositoryPublishStrategy == .reviewRequest,
      deploymentLevel: deployment?.level
    )
    return VStack(spacing: 0) {
      ForEach(steps) { step in
        PublishDrawerWorkflowStepRow(step: step) {
          if step.id == 2, scope != .repository {
            Button("检查发布账户", action: checkPublishingAccount)
              .disabled(
                !PublishDrawerAccountCheckPresentation.canCheck(
                  scope: scope,
                  hasToken: store.repositoryTokenAvailability.hasToken,
                  isBusy: operationController.isRunning || store.isRemoteRepositoryChecking
                    || store.isRemoteRepositoryPublishing)
              )
              .accessibilityIdentifier("publish-inspector-check-account")
          } else if step.id == 3 {
            if scope == .repository {
              Button("查看差异", action: prepareRepositoryWorktreePublish)
                .disabled(operationController.isRunning || store.isRemoteRepositoryPublishing)
                .help("打开完整工作区审阅；确认前不会提交")
            } else if scope == .managedArticles {
              Button("查看差异", action: prepareAllChangesOnlinePublish)
                .disabled(footerPrimaryAction?.disabledReason != nil)
            } else {
              Button("查看差异") { isAdvancedFlowExpanded.toggle() }
            }
          }
        }
        if step.id != 4 {
          Divider().padding(.leading, WorkbenchSpacing.content + WorkbenchSpacing.card)
        }
      }
    }
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityIdentifier("publish-inspector-workflow")
  }

  private func checkPublishingAccount() {
    operationController.startIfIdle {
      _ = await store.checkRepositoryTokenAccess()
      guard !Task.isCancelled else { return }
      if let draft = currentDraft { _ = await store.refreshPublishPreview(for: draft.id) }
      guard !Task.isCancelled else { return }
      await store.refreshBatchPublishPlanAsync()
    }
  }

  private var accountPresentation: (String, PublishDrawerWorkflowStep.Status) {
    if scope == .repository {
      let configured = PublishDrawerConnectionPresentation.isWorktreeConfigured(store.activeProfile)
      return configured
        ? (String(localized: "Git 推送认证将在确认前核对"), .pending)
        : (String(localized: "请先配置本地仓库与 origin，才能审阅完整工作区。"), .blocked)
    }
    let preview =
      scope == .managedArticles
      ? store.batchRemotePublishPreviewSnapshot
      : currentDraft.flatMap { store.cachedRemotePublishPreview(for: $0) }
    let account = ArticlePublishAttention.account(
      preview: preview, tokenAvailability: store.repositoryTokenAvailability)
    return (account.detail, account.status)
  }

  @ViewBuilder
  private var connectionIssue: some View {
    let account = accountPresentation
    if account.1 == .blocked {
      VStack(alignment: .leading, spacing: WorkbenchSpacing.tight) {
        Label("发布连接需要处理", systemImage: "xmark.octagon")
          .font(.callout.weight(.semibold)).foregroundStyle(WorkbenchTheme.risk)
        Text(account.0).font(.caption).foregroundStyle(.secondary)
        if scope == .repository {
          if let draftID {
            Button("打开项目配置") { onNavigateIssue?(draftID, .repository, scope) }
              .buttonStyle(.link)
          } else {
            Button("打开项目配置") { presentRepositorySettings() }.buttonStyle(.link)
          }
        } else {
          Button("设置发布账户") { presentRepositorySettings() }.buttonStyle(.link)
        }
      }
      .padding(WorkbenchSpacing.control)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        WorkbenchBackgroundStyle.card,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
      )
      .accessibilityIdentifier("publish-inspector-connection-issue")
    }
  }

  private func presentRepositorySettings() {
    SettingsNavigation.present(
      destination: .token(.repository),
      workspaceAction: settingsWorkspaceCommandAction
    ) { openSettings() }
  }

  /// The fixed footer keeps the main action and any unavailable reason visible.
  private var footerPrimaryAction: PublishDrawerFooterAction? {
    let isBusy = operationController.isRunning || store.isRemoteRepositoryPublishing
    switch scope {
    case .repository:
      return repositoryFooterAction(isBusy: isBusy)
    case .managedArticles:
      let state = batchActionState(
        plan: store.batchPublishPlan, preview: store.batchRemotePublishPreviewSnapshot
      )
      let isEnabled =
        store.batchRemotePublishPreviewSnapshot != nil
        && PublishDrawerBatchActionPresentation.isEnabled(state)
      return PublishDrawerFooterAction(
        title: String(localized: "审阅并发布文章变更…"),
        systemImage: "doc.on.doc",
        identifier: "publish-drawer-action-publish-articles",
        accessibilityLabel: String(localized: "审阅并发布文章变更"),
        accessibilityHint: nil,
        disabledReason: isEnabled ? nil : PublishDrawerBatchActionPresentation.status(state),
        perform: prepareAllChangesOnlinePublish
      )
    case .currentArticle:
      guard let draft = currentDraft else {
        return PublishDrawerFooterAction(
          title: String(localized: "仅发布当前文章…"), systemImage: "doc.badge.arrow.up",
          identifier: "publish-drawer-action-publish-current",
          accessibilityLabel: String(localized: "仅发布当前文章"), accessibilityHint: nil,
          disabledReason: String(localized: "请选择当前站点的文章后再发布。"), perform: {}
        )
      }
      let action = PublishDrawerSingleArticleActionPresentation.make(isWebsiteDraft: draft.draft)
      let connection = PublishDrawerConnectionPresentation.make(
        preview: store.cachedRemotePublishPreview(for: draft),
        isChecking: store.isRemoteRepositoryChecking,
        isPublishing: isBusy
      )
      return PublishDrawerFooterAction(
        title: action.actionTitle,
        systemImage: "doc.badge.arrow.up",
        identifier: "publish-drawer-action-publish-current",
        accessibilityLabel: action.accessibilityLabel,
        accessibilityHint: nil,
        disabledReason: connection.canStart ? nil : connection.message,
        perform: { prepareSingleArticleOnlinePublish(draft) }
      )
    }
  }

  private func repositoryFooterAction(isBusy: Bool) -> PublishDrawerFooterAction? {
    let profile = store.activeProfile
    let configured = PublishDrawerConnectionPresentation.isWorktreeConfigured(profile)
    return PublishDrawerFooterAction(
      title: String(localized: "审阅并发布仓库全部变更…"),
      systemImage: "paperplane.fill",
      identifier: "publish-drawer-action-publish-all",
      accessibilityLabel: String(localized: "审阅并发布仓库全部变更"),
      accessibilityHint: String(localized: "核对 Git 工作区变更；确认后创建安全提交并推送"),
      disabledReason: isBusy
        ? String(localized: "当前操作完成后可继续发布。")
        : configured ? nil : String(localized: "请先配置本地仓库与 origin，才能审阅完整工作区。"),
      perform: prepareRepositoryWorktreePublish
    )
  }

  @ViewBuilder
  private var completedWorktreeResult: some View {
    if let record = store.releaseRecords.first(where: { $0.id == completedReleaseRecordID }),
      record.siteProfileID == store.activeProfileID
    {
      let status = store.deploymentStatusSnapshot(for: record)
      let entry = store.activeProfileReleaseLedger.entries.first(where: { $0.id == record.id })
      PublishDrawerCard(title: "本次发布结果", systemImage: "checkmark.icloud") {
        Label(record.title, systemImage: record.kind.systemImage)
          .font(.callout.weight(.medium))
        Text("\(record.branchName ?? "") · \(record.shortCommitSHA ?? "")")
          .font(.caption.monospaced()).textSelection(.enabled)
        Text(entry?.statusMessage ?? record.summary)
          .font(.callout).foregroundStyle(.secondary)
        if record.articleVerificationTargets.isEmpty {
          Text("本次没有已确认的文章目标，仅检查站点部署。")
            .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button("检查部署与页面") {
            operationController.start {
              _ = await store.refreshDeploymentStatus(for: record)
            }
          }
          .disabled(!store.canCheckDeploymentStatus(for: record) || operationController.isRunning)
          .help(store.deploymentStatusReadiness(for: record).nextStep)
          .accessibilityIdentifier("publish-result-check-deployment")
          Button("查看发布历史") { showsReleaseHistory = true }
            .accessibilityIdentifier("publish-result-open-records")
        }
        if !store.canCheckDeploymentStatus(for: record) {
          Text(store.deploymentStatusReadiness(for: record).nextStep)
            .font(.caption).foregroundStyle(.secondary)
        }
        if record.kind == .remoteReviewRequest, record.reviewStatus?.state != .merged {
          HStack {
            Button("检查 PR/MR 合并状态") {
              operationController.start { _ = await store.refreshRemoteReviewStatus(for: record) }
            }
            .disabled(operationController.isRunning || store.isDeploymentStatusChecking)
            if let url = record.reviewURL.flatMap(URL.init(string:)) {
              Button("打开 PR/MR") { ExternalURLOpener.open(url) }
            }
          }
        }
        ReleaseArticleVerificationRows(store: store, record: record, snapshot: status)
        if let status, status.releaseRecordID == record.id {
          Label(status.title, systemImage: status.level.systemImage)
            .font(.callout.weight(.medium))
          Text(status.message).font(.caption).textSelection(.enabled)
          Text("\(status.nextActionTitle)：\(status.nextActionMessage)")
            .font(.callout).foregroundStyle(.secondary)
          ForEach(
            status.signals.filter { signal in
              !(status.articleResults ?? []).flatMap(\.signals).contains(where: {
                $0.id == signal.id
              })
            }
          ) { signal in
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
    let summary = UnifiedPublishReadinessPresentation.make(
      plan: store.batchPublishPlan, preview: store.batchRemotePublishPreviewSnapshot,
      profile: store.activeProfile,
      pendingDeletionCount: store.pendingRemoteRepositoryCleanupRequests.count
    )
    return PublishDrawerCard(title: "应用文章发布清单", systemImage: "list.clipboard") {
      Text(PublishDrawerBatchActionPresentation.detail)
        .font(.caption).foregroundStyle(.secondary)
      Label(
        String(
          format: String(localized: "%d 篇变更文章（含 %d 篇新建）"),
          summary.articleCount, summary.newArticleCount), systemImage: "doc.on.doc")
      Label(
        String(
          format: String(localized: "%d 张图片变更（%d 张新增，已纳入发布包）"),
          summary.imageChangeCount, summary.newImageCount), systemImage: "photo.on.rectangle")
      if summary.deletionCount > 0 {
        Label(
          String(
            format: String(localized: "%d 个待下线请求未纳入本次发布，请到回收站单独处理。"),
            summary.deletionCount), systemImage: "trash")
      }
      Label(summary.preflightTitle, systemImage: summary.preflightSystemImage)
      Label("目标分支：\(summary.targetTitle)", systemImage: "arrow.triangle.branch")
      Text(summary.pipelineTitle).font(.caption).foregroundStyle(.secondary)
    }
    .accessibilityIdentifier("publish-drawer-unified-summary")
  }

  @ViewBuilder
  private func publishPrimaryActions(
    draft: ArticleDraft,
    issues: [PreflightIssue]
  ) -> some View {
    let blockingCount = issues.filter { $0.severity == .error }.count
    let localReadiness = store.cachedDraftPublishPreviewSnapshot(for: draft.id)?
      .localPublishReadiness
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
          status: PublishDrawerOtherActionPresentation.localStatus(
            blockingCount: blockingCount,
            readiness: localReadiness, isSaving: store.isLocalRepositoryMutationRunning
          ),
          systemImage: "folder.badge.plus",
          tint: workbenchAccentColor,
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
          status: PublishDrawerOtherActionPresentation.previewBranchStatus(
            preview: previewBranchPreview, isPublishing: store.isRemoteRepositoryPublishing),
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
    let repositoryConfigured = PublishDrawerConnectionPresentation.isWorktreeConfigured(profile)
    let branch = profile.branch.trimmedForPublishing.nilIfEmpty ?? "main"
    let detectedChangeCount = store.repositoryReport?.changedFiles.count
    let isBusy = operationController.isRunning || store.isRemoteRepositoryPublishing

    return PublishDrawerCard(title: "发布仓库全部变更", systemImage: "shippingbox.and.arrow.backward") {
      VStack(alignment: .leading, spacing: 10) {
        Text("默认流程会审阅 Git 工作区的全部待提交变更：文章、图片、配置、主题、CSS/脚本，以及删除和重命名。发布前会自动核对最新变更。")
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
        !PublishDrawerConnectionPresentation.isDeferredRemoteIssue($0)
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

  /// Publish checks missing access proof immediately before confirmation or mutation.
  private func canStartRemotePublish(_ preview: RemoteRepositoryPublishPreview) -> Bool {
    PublishDrawerConnectionPresentation.make(preview: preview).canStart
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
        .padding(.top, WorkbenchSpacing.control)
      }
    }
    .padding(WorkbenchSpacing.content)
    .background(
      WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private var drawerFooter: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.tight) {
      if store.isRemoteRepositoryPublishing {
        if let progress = store.remoteRepositoryPublishProgress {
          if let value = progress.byteProgress {
            ProgressView(value: value).progressViewStyle(.linear)
          }
          Text(progress.statusDescription)
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityLabel("Git 推送进度")
            .accessibilityValue(progress.byteProgressDescription ?? progress.statusDescription)
        } else {
          Label("正在发布", systemImage: "arrow.up.circle").font(.caption)
        }
      }
      if let feedback = store.publishDrawerFeedback {
        Label(feedback.message, systemImage: feedback.status.publishDrawerSystemImage)
          .font(.caption).foregroundStyle(feedback.status.publishDrawerColor)
          .textSelection(.enabled).lineLimit(3).help(feedback.message)
          .accessibilityIdentifier("publish-drawer-feedback-message")
      }
      if store.remoteRepositoryConflictSession?.isEmpty == false {
        Button {
          isRemoteConflictResolverPresented = true
        } label: {
          Label("协调远端冲突", systemImage: "arrow.triangle.merge")
            .frame(maxWidth: .infinity)
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.return, modifiers: [.command])
        .accessibilityIdentifier("publish-drawer-action-resolve-remote-conflicts")
        .accessibilityHint("打开三方对比，不会直接覆盖远端")
      }
      if let primary = footerPrimaryAction {
        PublishDrawerPrimaryButton(
          action: primary,
          isSecondary: store.remoteRepositoryConflictSession?.isEmpty == false)
        if let reason = primary.disabledReason {
          Label(reason, systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("publish-drawer-primary-disabled-reason")
        }
      }
      HStack {
        Text("确认前会再次核对权限和文件变化")
          .font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: WorkbenchSpacing.tight)
        Button(operationController.isRunning ? String(localized: "中断流程") : String(localized: "关闭"))
        {
          dismissDrawer()
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .disabled(store.isRemoteRepositoryPublishing)
        .accessibilityHint(
          store.isRemoteRepositoryPublishing
            ? String(localized: "正在提交并推送，完成前不能关闭发布检查")
            : String(localized: "关闭发布流程"))
      }
    }
    .padding(WorkbenchSpacing.control)
    .frame(maxWidth: .infinity, alignment: .leading)
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
    let navigationClaim = operationController.claimSharedNavigation(from: publishingFacade)
    _ = publishingFacade.focusDraft(draft.id)
    publishingFacade.refreshPublishPreviewInBackground(for: draft)
    operationController.start {
      await store.writeSelectedDraftToLocalRepository()
      guard !Task.isCancelled else { return }
      operationController.restoreSharedSection(navigationClaim, using: publishingFacade)
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
    completedReleaseRecordID =
      store.releaseRecords.first {
        $0.commitSHA == result.commitSHA && $0.siteProfileID == store.activeProfileID
          && $0.kind == .remoteDirectCommit
      }?.id
    store.refreshBatchPublishPlanInBackground()
    if let draft = currentDraft {
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
    completedReleaseRecordID =
      store.releaseRecords.first {
        $0.commitSHA == result.commitSHA && $0.siteProfileID == store.activeProfileID
          && $0.kind == .remoteDirectCommit
      }?.id
    store.refreshBatchPublishPlanInBackground()
    if let draft = currentDraft {
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
      guard let snapshot = store.cachedDraftPublishPreviewSnapshot(for: draft.id),
        let currentDraft = store.draft(for: draft.id),
        snapshot.publishPackage.draftID == currentDraft.id,
        currentDraft.siteProfileID == store.activeProfileID,
        canStartRemotePublish(snapshot.remotePublishPreview)
      else { return }
      pendingSingleReview = try? SinglePublishReviewSnapshot(
        draft: currentDraft, profile: store.activeProfile, snapshot: snapshot
      )
      if pendingSingleReview == nil {
        store.setPublishActionMessage(
          String(localized: "无法读取待审阅的附件，请检查文件后重新准备发布。"), status: .warning)
      }
    }
  }

  private func publishAllChangesOnline(review: BatchPublishReviewSnapshot) async {
    let navigationClaim = operationController.claimSharedNavigation(from: publishingFacade)
    let previousIDs = Set(store.releaseRecords.map(\.id))
    let profileID = store.activeProfileID
    let result = await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy(
      expectedChangedPaths: Set(review.preview.changedPaths),
      expectedTarget: review.target,
      expectedReview: review.expectation
    )
    completedReleaseRecordID = PublishResultRecordSelection.recordID(
      result: result, records: store.releaseRecords, previousRecordIDs: previousIDs,
      profileID: profileID, draftIDs: Set(review.items.map(\.draftID)))
    guard !Task.isCancelled else { return }
    _ = await store.refreshRepositoryStateForPublishing()
    guard !Task.isCancelled else { return }
    operationController.restoreSharedSection(navigationClaim, using: publishingFacade)
    store.refreshBatchPublishPlanInBackground()
    if let draft = currentDraft {
      publishingFacade.refreshPublishPreviewInBackground(for: draft)
    }
  }

  private func publishSingleArticleOnline(_ review: SinglePublishReviewSnapshot) {
    let draft = review.draft
    let navigationClaim = operationController.claimSharedNavigation(from: publishingFacade)
    guard publishingFacade.focusDraft(draft.id) else { return }
    operationController.start {
      let previousIDs = Set(store.releaseRecords.map(\.id))
      let profileID = store.activeProfileID
      let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy(
        expectedReview: review.expectation
      )
      completedReleaseRecordID = PublishResultRecordSelection.recordID(
        result: result, records: store.releaseRecords, previousRecordIDs: previousIDs,
        profileID: profileID, draftIDs: [draft.id])
      guard !Task.isCancelled else { return }
      _ = await store.refreshRepositoryStateForPublishing()
      guard !Task.isCancelled else { return }
      operationController.restoreSharedSection(navigationClaim, using: publishingFacade)
      publishingFacade.refreshPublishPreviewInBackground(for: draft)
      store.refreshBatchPublishPlanInBackground()
    }
  }

  private func publishSingleArticlePreviewBranch(_ draft: ArticleDraft) async {
    let navigationClaim = operationController.claimSharedNavigation(from: publishingFacade)
    _ = publishingFacade.focusDraft(draft.id)
    let previousIDs = Set(store.releaseRecords.map(\.id))
    let profileID = store.activeProfileID
    let result = await store.publishSelectedDraftToPreviewBranch()
    completedReleaseRecordID = PublishResultRecordSelection.recordID(
      result: result, records: store.releaseRecords, previousRecordIDs: previousIDs,
      profileID: profileID, draftIDs: [draft.id])
    guard !Task.isCancelled else { return }
    _ = await store.refreshRepositoryStateForPublishing()
    guard !Task.isCancelled else { return }
    operationController.restoreSharedSection(navigationClaim, using: publishingFacade)
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
    pendingSingleReview = nil
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
        String(localized: "当前分支没有关联远端分支，暂未同步远端状态；发布前仍会在线核对文件。"),
        status: .information
      )
    case .failed:
      store.setPublishActionMessage(
        String(localized: "获取远端最新状态失败；发布时仍会通过远端服务逐文件核对。"),
        status: .warning
      )
    case nil:
      store.setPublishActionMessage(
        String(localized: "站点或仓库在刷新期间发生变化，请重试。"),
        status: .warning
      )
    }
  }
}
