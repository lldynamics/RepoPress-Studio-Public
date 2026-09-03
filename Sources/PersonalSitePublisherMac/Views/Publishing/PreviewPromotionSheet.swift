import PublishingWorkbenchCore
import SwiftUI

struct PreviewPromotionEntryButton: View {
  let store: WorkbenchStore
  let record: ReleaseRecord

  @ObservedObject private var historyObservation: WorkbenchReleaseHistoryObservationFacade
  @State private var isPresented = false

  init(store: WorkbenchStore, record: ReleaseRecord) {
    self.store = store
    self.record = record
    _historyObservation = ObservedObject(wrappedValue: store.releaseHistoryObservation)
  }

  private var eligibility: PreviewPromotionRecordEligibility {
    PreviewPromotionPresentation.eligibility(for: record)
  }

  private var actionState: PreviewPromotionActionState {
    PreviewPromotionPresentation.actionState(
      for: record,
      canUseProtectedWorkbench: store.canUseProtectedWorkbench,
      isRemoteRepositoryPublishing: store.isRemoteRepositoryPublishing
    )
  }

  var body: some View {
    if case .eligible(let action) = eligibility {
      Button {
        isPresented = true
      } label: {
        Label(
          action.title,
          systemImage: action == .createReview ? "arrow.up.forward.app" : "arrow.triangle.merge"
        )
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .disabled(!actionState.isEnabled)
      .help(disabledHelp)
      .accessibilityIdentifier("preview-promotion-entry-\(record.id.uuidString)")
      .sheet(isPresented: $isPresented) {
        PreviewPromotionSheet(store: store, record: record)
      }
    }
  }

  private var disabledHelp: String {
    switch actionState {
    case .enabled:
      return ""
    case .disabled(.protectedWorkbenchUnavailable):
      return String(localized: "隐私保护已启用，暂不能继续远端发布操作。")
    case .disabled(.remoteOperationRunning):
      return String(localized: "已有远端操作正在运行。")
    case .disabled(.unavailable):
      return String(localized: "这条记录当前不支持转为正式发布。")
    }
  }
}

struct PreviewPromotionSheet: View {
  @Environment(\.dismiss) private var dismiss

  let store: WorkbenchStore
  let record: ReleaseRecord

  @ObservedObject private var historyObservation: WorkbenchReleaseHistoryObservationFacade
  @State private var workflow: PreviewPromotionWorkflowState = .idle
  @State private var previewPlan: PreviewPromotionPlan?
  @State private var mergePlan: ReviewMergePlan?
  @State private var reviewRecord: ReleaseRecord?
  @State private var completedRecord: ReleaseRecord?
  @State private var completedMergeSHA: String?
  @State private var operationError: String?
  @State private var reviewCheckPermission: GitHubReviewCheckPermission?
  @State private var isCheckingDeployment = false
  @State private var task: Task<Void, Never>?
  @State private var taskContext: PreviewPromotionTaskContext

  init(store: WorkbenchStore, record: ReleaseRecord) {
    self.store = store
    self.record = record
    _historyObservation = ObservedObject(wrappedValue: store.releaseHistoryObservation)
    _taskContext = State(
      initialValue: PreviewPromotionTaskContext(
        record: record,
        profileID: store.activeProfileID,
        selectedDraftID: store.selectedDraftID
      )
    )
  }

  private var currentRecord: ReleaseRecord {
    completedRecord ?? mergePlan?.record ?? reviewRecord ?? previewPlan?.record ?? record
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          recordSummary
          content
          operationStatus
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      footer
    }
    .padding(20)
    .frame(minWidth: 680, idealWidth: 820, minHeight: 560, idealHeight: 720)
    .interactiveDismissDisabled(workflow.isLoading)
    .onAppear(perform: beginInitialReviewIfNeeded)
    .onDisappear(perform: cancelOperation)
    .onChange(of: store.activeProfileID) { _, _ in cancelIfContextChanged() }
    .onChange(of: store.selectedDraftID) { _, _ in cancelIfContextChanged() }
    .onChange(of: store.canUseProtectedWorkbench) { _, _ in cancelIfContextChanged() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("预览转正式发布")
    .accessibilityIdentifier("preview-promotion-sheet-\(record.id.uuidString)")
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      Label("预览转正式发布", systemImage: "arrow.up.forward.app")
        .font(.title3.weight(.semibold))
      Spacer()
      if workflow.isLoading {
        Button("取消当前操作") { cancelCurrentOperation() }
          .accessibilityIdentifier("preview-promotion-cancel-operation")
      }
      Button("关闭") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .disabled(workflow.isLoading)
        .accessibilityIdentifier("preview-promotion-close")
    }
  }

  private var recordSummary: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("只发布此预览版本；当前未推送编辑不会包含。创建 PR 不等于合并或上线；合并后仍需验证部署。")
        .font(.callout)
        .foregroundStyle(.secondary)
      if record.kind == .remotePreviewBranch, record.commitSHA?.isEmpty != false {
        Text("此旧记录未保存提交编号，将读取当前预览分支并重新审阅；确认后会固定本次审阅版本。")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
      }
      LabeledContent("文章") {
        Text(record.draftTitle ?? record.title)
          .textSelection(.enabled)
      }
      LabeledContent("仓库") {
        Text(repositorySummary)
          .font(.callout.monospaced())
          .textSelection(.enabled)
      }
      LabeledContent("来源预览版本") {
        Text(record.branchName ?? "未提供")
          .font(.callout.monospaced())
          .textSelection(.enabled)
      }
    }
    .padding(12)
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  @ViewBuilder
  private var content: some View {
    if let previewPlan {
      planReview(previewPlan)
    } else if let mergePlan {
      mergeReview(mergePlan)
    } else if reviewRecord != nil {
      mergeCheckPendingContent
    } else if completedRecord != nil {
      completedContent
    } else {
      emptyPreparation
    }
  }

  private var emptyPreparation: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("尚未读取远端预览", systemImage: "eye.circle")
        .font(.headline)
      Text("先进行只读检查，读取预览分支、目标分支和完整文件差异。此步骤不会创建 PR，也不会合并或发布。")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private var mergeCheckPendingContent: some View {
    Label("尚未完成合并检查。修复问题后可重新检查。", systemImage: "arrow.triangle.merge")
      .font(.callout)
      .foregroundStyle(.secondary)
  }

  private func planReview(_ plan: PreviewPromotionPlan) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("只读审阅", systemImage: "doc.text.magnifyingglass")
        .font(.headline)
      commitSummary(
        source: plan.sourceCommitSHA,
        target: plan.targetCommitSHA,
        targetBranch: plan.record.targetBranch ?? plan.profile.branch
      )
      changedFiles(plan.files)
      markdownReview(plan.markdown)
    }
  }

  private func mergeReview(_ plan: ReviewMergePlan) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("合并检查", systemImage: "checklist")
        .font(.headline)
      commitSummary(
        source: plan.sourceCommitSHA,
        target: plan.targetCommitSHA,
        targetBranch: plan.record.targetBranch ?? plan.profile.branch
      )
      changedFiles(plan.files)
      markdownReview(plan.markdown)
      if let mergedCommitSHA = plan.mergedCommitSHA {
        completionCard(record: plan.record, mergedCommitSHA: mergedCommitSHA)
      } else if !plan.blockers.isEmpty {
        blockerCard(plan.blockers)
      } else {
        AccessibleStatusMessage(
          message: String(localized: "检查已通过。确认合并后，部署状态仍需单独验证。"),
          severity: .success
        )
      }
    }
  }

  private var completedContent: some View {
    completionCard(record: currentRecord, mergedCommitSHA: completedMergeSHA)
  }

  private func completionCard(record: ReleaseRecord, mergedCommitSHA: String?) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if let status = store.deploymentStatusSnapshots[record.id],
        let mergedCommitSHA, status.expectedCommitSHA == mergedCommitSHA
      {
        Label(status.title, systemImage: status.level.systemImage)
          .font(.headline)
        Text(status.message).font(.callout)
        Text("\(status.nextActionTitle)：\(status.nextActionMessage)")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        AccessibleStatusMessage(
          message: PreviewPromotionPresentation.completionMessage(
            for: record, mergedCommitSHA: mergedCommitSHA),
          severity: .success
        )
        Text("状态含义：PR 已合并；部署待验证，尚未标记为已上线。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .accessibilityIdentifier("preview-promotion-completed-pending-deployment")
  }

  private func blockerCard(_ blockers: [String]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("合并尚未通过", systemImage: "exclamationmark.triangle")
        .font(.callout.weight(.semibold))
        .foregroundStyle(WorkbenchTheme.warning)
      ForEach(Array(blockers.enumerated()), id: \.offset) { _, blocker in
        Text(blocker)
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12)
    .background(
      WorkbenchTheme.warning.opacity(WorkbenchOpacity.noticeBackground),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .accessibilityIdentifier("preview-promotion-merge-blockers")
  }

  private func commitSummary(source: String, target: String, targetBranch: String) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
      GridRow {
        Text("预览 Commit").foregroundStyle(.secondary)
        Text(source).font(.caption.monospaced()).textSelection(.enabled)
      }
      GridRow {
        Text("\(targetBranch) Commit").foregroundStyle(.secondary)
        Text(target).font(.caption.monospaced()).textSelection(.enabled)
      }
    }
  }

  private func changedFiles(_ files: [PreviewPromotionFile]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("新增 / 修改文件", systemImage: "doc.on.doc")
        .font(.callout.weight(.semibold))
      if files.isEmpty {
        Text("没有可供合并的文件。")
          .foregroundStyle(.secondary)
      } else {
        ForEach(files) { file in
          VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(file.path)
                .font(.callout.monospaced())
                .textSelection(.enabled)
              Spacer(minLength: 8)
              Text(localizedFileStatus(file.status))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              Text("+\(file.additions) / -\(file.deletions)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            DisclosureGroup(String(localized: "查看差异")) {
              Text(
                file.patch.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "没有可显示的文本 patch。")
              )
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(10)
          .background(
            WorkbenchBackgroundStyle.control,
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
        }
      }
    }
  }

  private func markdownReview(_ markdown: String) -> some View {
    DisclosureGroup(String(localized: "查看完整 Markdown")) {
      Text(markdown)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }
  }

  @ViewBuilder
  private var operationStatus: some View {
    if workflow.isLoading {
      ProgressView(progressTitle)
        .accessibilityIdentifier("preview-promotion-progress")
    }
    if isCheckingDeployment {
      ProgressView(String(localized: "检查部署状态"))
    }
    if let operationError {
      AccessibleStatusMessage(message: operationError, severity: .error)
        .textSelection(.enabled)
        .accessibilityIdentifier("preview-promotion-error")
    }
    if let reviewCheckPermission {
      reviewCheckPermissionRecoveryCard(reviewCheckPermission)
    }
    if let feedback = store.publishActionFeedback, feedback.message.isEmpty == false {
      AccessibleStatusMessage(
        message: feedback.message,
        severity: feedback.status == .failure ? .error : .warning
      )
      .accessibilityIdentifier("preview-promotion-action-feedback")
    }
  }

  private func reviewCheckPermissionRecoveryCard(
    _ deniedPermission: GitHubReviewCheckPermission
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("无法读取合并检查", systemImage: "lock.trianglebadge.exclamationmark")
        .font(.callout.weight(.semibold))
        .foregroundStyle(WorkbenchTheme.warning)
      Text(
        String(
          format: String(
            localized: "GitHub 拒绝读取合并检查；本次请求需要 %@。请在 fine-grained Token 中为当前仓库同时启用以下只读权限："),
          deniedPermission.requiredPermission
        )
      )
      .font(.callout)
      Label("Checks: Read-only", systemImage: "checklist")
        .font(.callout.monospaced())
      Label("Commit statuses: Read-only", systemImage: "checkmark.seal")
        .font(.callout.monospaced())
      Text(
        "Contents 和 Pull requests 的写入权限仍按原发布流程保留。编辑现有 Token 时请授权当前仓库；无需向任何人提供 Token。保存后回到此 PR，点击“重新检查”。读取不到完整检查结果时，软件不会合并。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      if PreviewPromotionPresentation.offersGitHubTokenSettingsLink(
        for: currentRecord,
        profileRepositoryBaseURL: store.activeProfile.repositoryBaseURL
      ) {
        Link(destination: URL(string: "https://github.com/settings/personal-access-tokens")!) {
          Label("打开 GitHub Token 设置", systemImage: "arrow.up.right.square")
        }
        .font(.caption.weight(.medium))
      }
    }
    .padding(12)
    .background(
      WorkbenchTheme.warning.opacity(WorkbenchOpacity.noticeBackground),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .accessibilityIdentifier("preview-promotion-review-check-permission-recovery")
  }

  private var footer: some View {
    HStack(spacing: 8) {
      if previewPlan == nil, mergePlan == nil, reviewRecord == nil, completedRecord == nil {
        Button("只读检查", systemImage: "eye") { preparePreview() }
          .workbenchProminentActionStyle()
          .disabled(workflow.isLoading || !canOperate)
          .accessibilityIdentifier("preview-promotion-prepare")
      }
      if let plan = previewPlan {
        Button("重新检查", systemImage: "arrow.clockwise") { preparePreview() }
          .disabled(workflow.isLoading || !canOperate)
        Button("创建正式发布请求", systemImage: "arrow.up.forward.app") { createReview(plan) }
          .workbenchProminentActionStyle()
          .disabled(workflow.isLoading || !canOperate)
          .accessibilityIdentifier("preview-promotion-create-review")
      }
      if let plan = mergePlan {
        if plan.mergedCommitSHA != nil {
          Button("检查部署状态", systemImage: "checkmark.icloud") { refreshDeployment(for: plan.record) }
            .disabled(workflow.isLoading || !canOperate)
            .accessibilityIdentifier("preview-promotion-check-deployment")
        } else {
          Button("重新检查", systemImage: "arrow.clockwise") { checkMerge(for: plan.record) }
            .disabled(workflow.isLoading || !canOperate)
            .accessibilityIdentifier("preview-promotion-recheck-merge")
          if plan.canMerge {
            Button("确认合并并发布", systemImage: "arrow.triangle.merge") { merge(plan) }
              .workbenchProminentActionStyle()
              .disabled(workflow.isLoading || !canOperate)
              .accessibilityIdentifier("preview-promotion-confirm-merge")
          } else {
            Button("继续处理", systemImage: "arrow.clockwise") { checkMerge(for: plan.record) }
              .disabled(workflow.isLoading || !canOperate)
              .accessibilityIdentifier("preview-promotion-continue")
          }
        }
      }
      if let reviewRecord, mergePlan == nil, completedRecord == nil {
        Button("重新检查", systemImage: "arrow.clockwise") { checkMerge(for: reviewRecord) }
          .disabled(workflow.isLoading || !canOperate)
          .accessibilityIdentifier("preview-promotion-recheck-merge")
      }
      if completedRecord != nil {
        Button("检查部署状态", systemImage: "checkmark.icloud") { refreshDeployment(for: currentRecord) }
          .disabled(workflow.isLoading || !canOperate)
          .accessibilityIdentifier("preview-promotion-check-deployment")
      }
      Spacer()
    }
  }

  private var repositorySummary: String {
    let owner = record.repoOwner?.isEmpty == false ? record.repoOwner! : "-"
    let name = record.repoName?.isEmpty == false ? record.repoName! : "-"
    let target = record.targetBranch?.isEmpty == false ? record.targetBranch! : "未提供"
    return "\(owner)/\(name) / \(target)"
  }

  private var progressTitle: String {
    switch workflow {
    case .preparing: return String(localized: "正在读取预览差异…")
    case .creatingReview: return String(localized: "正在创建或复用正式发布请求…")
    case .checkingMerge: return String(localized: "正在检查合并条件…")
    case .merging: return String(localized: "正在确认合并并启动部署检查…")
    case .idle, .previewReady, .completed: return ""
    }
  }

  private var canOperate: Bool {
    PreviewPromotionPresentation.acceptsCompletion(
      taskContext,
      activeProfileID: store.activeProfileID,
      selectedDraftID: store.selectedDraftID,
      canUseProtectedWorkbench: store.canUseProtectedWorkbench
    ) && !store.isRemoteRepositoryPublishing && !isCheckingDeployment
  }

  private func preparePreview() {
    let capturedContext = taskContext
    task?.cancel()
    workflow = .preparing
    previewPlan = nil
    mergePlan = nil
    reviewRecord = nil
    completedRecord = nil
    operationError = nil
    reviewCheckPermission = nil
    task = Task {
      do {
        let plan = try await store.preparePreviewPromotion(for: record)
        guard accepts(capturedContext) else { return }
        previewPlan = plan
        workflow = .previewReady
      } catch is CancellationError {
      } catch {
        finishError(error, context: capturedContext)
      }
    }
  }

  private func createReview(_ plan: PreviewPromotionPlan) {
    let capturedContext = taskContext
    workflow = .creatingReview
    operationError = nil
    reviewCheckPermission = nil
    task = Task {
      do {
        let reviewRecord = try await store.createReviewForPreview(plan)
        guard accepts(capturedContext) else { return }
        previewPlan = nil
        self.reviewRecord = reviewRecord
        checkMerge(for: reviewRecord, context: capturedContext)
      } catch is CancellationError {
      } catch {
        finishError(error, context: capturedContext)
      }
    }
  }

  private func checkMerge(
    for reviewRecord: ReleaseRecord, context capturedContext: PreviewPromotionTaskContext? = nil
  ) {
    let capturedContext = capturedContext ?? taskContext
    workflow = .checkingMerge
    mergePlan = nil
    operationError = nil
    reviewCheckPermission = nil
    task = Task {
      do {
        let plan = try await store.prepareReviewMerge(for: reviewRecord)
        guard accepts(capturedContext) else { return }
        mergePlan = plan
        self.reviewRecord = plan.record
        workflow = .previewReady
      } catch is CancellationError {
      } catch {
        finishError(error, context: capturedContext)
      }
    }
  }

  private func merge(_ plan: ReviewMergePlan) {
    let capturedContext = taskContext
    workflow = .merging
    reviewRecord = plan.record
    mergePlan = nil
    operationError = nil
    reviewCheckPermission = nil
    task = Task {
      do {
        let merged = try await store.mergeReviewedPublication(plan)
        guard accepts(capturedContext) else { return }
        completedRecord = merged
        completedMergeSHA = merged.reviewStatus?.mergeCommitSHA ?? plan.mergedCommitSHA
        mergePlan = nil
        reviewRecord = nil
        workflow = .completed
      } catch is CancellationError {
      } catch {
        finishError(error, context: capturedContext)
      }
    }
  }

  private func refreshDeployment(for record: ReleaseRecord) {
    let capturedContext = taskContext
    guard !isCheckingDeployment else { return }
    isCheckingDeployment = true
    task = Task {
      defer { isCheckingDeployment = false }
      _ = await store.refreshDeploymentStatus(for: record)
      guard accepts(capturedContext) else { return }
    }
  }

  private func finishError(_ error: Error, context: PreviewPromotionTaskContext) {
    guard accepts(context) else { return }
    if case RemoteRepositoryPublishError.reviewCheckPermissionDenied(let permission, _) = error {
      mergePlan = nil
      reviewCheckPermission = permission
      operationError = nil
    } else {
      if workflow == .preparing || workflow == .checkingMerge || workflow == .merging {
        mergePlan = nil
      }
      operationError = error.localizedDescription
    }
    workflow = .idle
  }

  private func accepts(_ capturedContext: PreviewPromotionTaskContext) -> Bool {
    PreviewPromotionPresentation.acceptsCompletion(
      capturedContext,
      activeProfileID: store.activeProfileID,
      selectedDraftID: store.selectedDraftID,
      canUseProtectedWorkbench: store.canUseProtectedWorkbench
    ) && !Task.isCancelled
  }

  private func cancelIfContextChanged() {
    guard
      !PreviewPromotionPresentation.acceptsCompletion(
        taskContext,
        activeProfileID: store.activeProfileID,
        selectedDraftID: store.selectedDraftID,
        canUseProtectedWorkbench: store.canUseProtectedWorkbench
      )
    else { return }
    cancelCurrentOperation(
      message: String(localized: "审阅上下文已变化，已取消当前操作；远端写入不会自动重试。")
    )
    previewPlan = nil
    mergePlan = nil
    reviewRecord = nil
    completedRecord = nil
    completedMergeSHA = nil
    operationError = nil
    reviewCheckPermission = nil
    dismiss()
  }

  private func beginInitialReviewIfNeeded() {
    guard workflow == .idle, previewPlan == nil, mergePlan == nil, reviewRecord == nil,
      completedRecord == nil, canOperate
    else { return }
    if record.kind == .remoteReviewRequest {
      reviewRecord = record
      checkMerge(for: record)
    }
  }

  private func localizedFileStatus(_ status: String) -> String {
    switch status.lowercased() {
    case "added": return String(localized: "新增")
    case "modified": return String(localized: "修改")
    case "deleted": return String(localized: "删除")
    case "unchanged": return String(localized: "无变化")
    default: return status
    }
  }

  private func cancelCurrentOperation(message: String? = nil) {
    cancelOperation()
    workflow = .idle
    reviewCheckPermission = nil
    operationError = message ?? String(localized: "操作已取消；远端写入不会自动重试。")
  }

  private func cancelOperation() {
    task?.cancel()
    task = nil
  }
}
