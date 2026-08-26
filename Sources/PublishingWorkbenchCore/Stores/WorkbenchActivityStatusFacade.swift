import Combine
import Foundation

@MainActor
public final class WorkbenchActivityStatusFacade: ObservableObject {
  private enum GitOperationKind {
    case local
    case remote
  }

  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()
  private var activeGitOperationKind: GitOperationKind?
  private var lastGitOperationKind: GitOperationKind?
  private var gitRetryIntent: WorkbenchTaskRetryIntent?
  private var imageSummaryFailureProfileID: UUID?

  init(store: WorkbenchStore) {
    self.store = store
    observe(store.privacyProtectionStore.$isQuickHideActive)
    observe(store.repositoryStore.$repositoryScanState)
    observeGitOperation(
      store.repositoryStore.$isRemoteRepositoryPublishing,
      kind: .remote
    )
    observe(store.repositoryStore.$isRemoteRepositoryChecking)
    observe(store.repositoryStore.$remoteRepositoryPublishProgress)
    observe(store.repositoryStore.$remoteRepositoryPublishResult)
    observe(store.repositoryStore.$localGitPublishResult)
    observe(store.aiWorkspaceStore.$isAIChatRunning)
    observe(store.aiWorkspaceStore.$isAIActionRunning)
    observe(store.aiWorkspaceStore.$isAIMetadataSuggestionRunning)
    observe(store.aiWorkspaceStore.$isAutomationRunning)
    observe(store.aiWorkspaceStore.$isAIImageTextRunning)
    observeAIMessage(store.aiWorkspaceStore.$aiChatMessage)
    observeAIMessage(store.aiWorkspaceStore.$aiActionMessage)
    observe(store.aiStore.$aiChatManualRetryState)
    observe(store.aiStore.$aiGeneralChatManualRetryState)
    observe(store.knowledge.$isImporting)
    observe(store.knowledge.$importProgress)
    observe(store.knowledge.$importOperationTitle)
    observe(store.knowledge.$lastImportFailure)
    observe(store.knowledge.$statusMessage)
    observeGitOperation(
      store.publishingStore.$isLocalRepositoryMutationRunning,
      kind: .local
    )
    observe(store.publishingStore.$publishActionFeedback)
    observe(store.publishingStore.$releaseRecords)
    observe(store.publishingStore.$activeProfileID)
    observe(store.imageStore.$imageBatchProgress)
    observe(store.imageStore.$isImageBatchProcessing)
    observe(store.imageStore.$lastBatchFailure)
    observe(store.imageStore.$lastBatchOperation)
    observe(store.imageStore.$isSiteSummaryLoading)
    observeImageSummaryFailure(store.imageStore.$siteSummaryErrorMessage)
    observe(store.deploymentStore.$isDeploymentStatusChecking)
    observe(store.deploymentStore.$deploymentStatusMessage)
    observe(store.deploymentStore.$deploymentStatusSnapshots)
    observe(store.persistenceStore.$lastSaveError)
    observe(store.persistenceStore.$status)
    observe(store.$draftRecoveryJournalErrorMessage)
  }

  public var isQuickHideActive: Bool { store.isQuickHideActive }
  public var repositoryScanState: RepositoryScanState { store.repositoryScanState }
  public var isRemoteRepositoryPublishing: Bool { store.isRemoteRepositoryPublishing }
  public var isAIChatRunning: Bool { store.isAIChatRunning }
  public var isDeploymentStatusChecking: Bool { store.isDeploymentStatusChecking }
  public var lastSaveError: String? { store.lastSaveError }
  public var lastSaveStatus: String { store.lastSaveStatus }

  public var taskCenterItems: [WorkbenchTaskItem] {
    var tasks: [WorkbenchTaskItem] = []
    if let aiTask {
      tasks.append(aiTask)
    }
    if let knowledgeImportTask {
      tasks.append(knowledgeImportTask)
    }
    if let imageTask {
      tasks.append(imageTask)
    }
    if let siteScanTask {
      tasks.append(siteScanTask)
    }
    if let gitTask {
      tasks.append(gitTask)
    }
    if let deploymentTask {
      tasks.append(deploymentTask)
    }
    return tasks.sorted { lhs, rhs in
      if lhs.state == .running, rhs.state != .running { return true }
      if lhs.state != .running, rhs.state == .running { return false }
      return lhs.kind.sortRank < rhs.kind.sortRank
    }
  }

  public var activeTaskCount: Int {
    taskCenterItems.filter(\.isActive).count
  }

  public var failedTaskCount: Int {
    taskCenterItems.filter(\.isFailure).count
  }

  public func retryTask(
    _ task: WorkbenchTaskItem,
    confirmingPossibleDuplicateCharge: Bool = false
  ) async {
    guard task.canRetry, let intent = task.retryIntent else {
      // A task without a typed intent is deliberately not retryable. Falling
      // back to the currently selected article would make the task center
      // execute a different user's operation.
      return
    }

    switch intent {
    case .aiChat(let draftID, let conversationID, let requiresConfirmation):
      guard !requiresConfirmation || confirmingPossibleDuplicateCharge else {
        return
      }
      guard let currentRetryState = store.aiStore.aiChatManualRetryState,
        currentRetryState.draftID == draftID,
        currentRetryState.conversationID == conversationID,
        currentRetryState.requiresDuplicateChargeConfirmation == requiresConfirmation
      else {
        return
      }
      guard let draft = store.drafts.first(where: { $0.id == draftID }) else {
        return
      }
      if store.aiChatDraftID != draftID {
        guard store.focusDraft(draftID, section: .writing) else { return }
        store.aiStore.prepareAIChat(for: draft)
        // prepareAIChat clears a retry state when switching drafts. Restore
        // the exact state captured by this task so the conversation guard in
        // the retry API remains effective.
        store.aiStore.aiChatManualRetryState = currentRetryState
      }
      _ = await store.aiStore.retryLastFailedAIChatReply(
        confirmingPossibleDuplicateCharge: requiresConfirmation
          && confirmingPossibleDuplicateCharge,
        draft: draft
      )
    case .generalAIChat(
      let conversationID,
      let operationID,
      let requiresConfirmation
    ):
      guard !requiresConfirmation || confirmingPossibleDuplicateCharge else {
        return
      }
      guard let currentRetryState = store.aiStore.aiGeneralChatManualRetryState,
        currentRetryState.conversationID == conversationID,
        currentRetryState.operationID == operationID,
        currentRetryState.requiresDuplicateChargeConfirmation == requiresConfirmation
      else {
        return
      }
      _ = await store.aiStore.retryLastFailedGeneralAIChatReply(
        confirmingPossibleDuplicateCharge: requiresConfirmation
          && confirmingPossibleDuplicateCharge,
        conversationID: conversationID,
        operationID: operationID
      )
    case .knowledgeImport, .imageProcessing:
      // Kept only for decoding legacy task snapshots. These intents have no
      // stable operation ID, so never repeat whichever operation is currently
      // stored as "last".
      return
    case .imageSummary(let profileID):
      guard profileID == store.activeProfileID,
        imageSummaryFailureProfileID == profileID,
        store.imageStore.siteSummaryErrorMessage?.nilIfEmpty != nil
      else {
        return
      }
      await store.refreshImageWorkbenchSiteSummaryInBackground(force: true)
    case .siteScan(let profileID):
      guard profileID == store.activeProfileID else { return }
      await store.repository.scanAsync()
    case .gitDraft(let profileID, let draftID):
      await retryGitDraft(profileID: profileID, draftID: draftID, remote: false)
    case .gitRemoteDraft(let profileID, let draftID):
      await retryGitDraft(profileID: profileID, draftID: draftID, remote: true)
    case .gitRemoteBatch(let profileID, let draftIDs):
      await retryGitRemoteBatch(profileID: profileID, draftIDs: draftIDs)
    case .deployment(let recordID):
      guard let record = store.releaseRecords.first(where: { $0.id == recordID }) else {
        return
      }
      _ = await store.refreshDeploymentStatus(for: record)
    }
  }

  private var aiTask: WorkbenchTaskItem? {
    let ai = store.aiWorkspaceStore
    let isRunning =
      ai.isAIChatRunning
      || ai.isAIActionRunning
      || ai.isAIMetadataSuggestionRunning
      || ai.isAutomationRunning
      || ai.isAIImageTextRunning
    let message = ai.aiChatMessage ?? ai.aiActionMessage
    if isRunning {
      return WorkbenchTaskItem(
        id: "ai-request",
        kind: .aiRequest,
        detail: message ?? CoreL10n.text("正在等待 AI 服务响应…"),
        state: .running
      )
    }
    let retryIntent: WorkbenchTaskRetryIntent?
    if let retryState = store.aiStore.aiChatManualRetryState {
      retryIntent = .aiChat(
        draftID: retryState.draftID,
        conversationID: retryState.conversationID,
        requiresDuplicateChargeConfirmation:
          retryState.requiresDuplicateChargeConfirmation
      )
    } else if let retryState = store.aiStore.aiGeneralChatManualRetryState {
      retryIntent = .generalAIChat(
        conversationID: retryState.conversationID,
        operationID: retryState.operationID,
        requiresDuplicateChargeConfirmation:
          retryState.requiresDuplicateChargeConfirmation
      )
    } else {
      retryIntent = nil
    }
    guard let failure = failureReason(in: message) ?? (
      retryIntent == nil ? nil : CoreL10n.text("AI 请求失败，请重试。")
    ) else { return nil }
    return WorkbenchTaskItem(
      id: "ai-request",
      kind: .aiRequest,
      detail: failure,
      state: .failed,
      failureReason: failure,
      retryIntent: retryIntent
    )
  }

  private var knowledgeImportTask: WorkbenchTaskItem? {
    if store.knowledge.isImporting {
      return WorkbenchTaskItem(
        id: "knowledge-import",
        kind: .knowledgeImport,
        title: store.knowledge.importOperationTitle ?? WorkbenchTaskKind.knowledgeImport.title,
        detail: store.knowledge.statusMessage ?? CoreL10n.text("正在导入资料…"),
        progress: store.knowledge.importProgress,
        state: .running
      )
    }
    guard let failure = store.knowledge.lastImportFailure else { return nil }
    return WorkbenchTaskItem(
      id: "knowledge-import",
      kind: .knowledgeImport,
      title: store.knowledge.importOperationTitle ?? WorkbenchTaskKind.knowledgeImport.title,
      detail: "资料导入失败：\(failure)",
      state: .failed,
      failureReason: failure
    )
  }

  private var imageTask: WorkbenchTaskItem? {
    let image = store.imageStore
    if image.isImageBatchProcessing {
      let progress = image.imageBatchProgress
      return WorkbenchTaskItem(
        id: "image-processing",
        kind: .imageProcessing,
        title: progress?.operation.progressTitle
          ?? image.lastBatchOperation?.progressTitle
          ?? WorkbenchTaskKind.imageProcessing.title,
        detail: store.imageActionMessage ?? CoreL10n.text("正在处理图片…"),
        progress: progress?.fractionCompleted,
        state: .running
      )
    }
    if image.isSiteSummaryLoading {
      return WorkbenchTaskItem(
        id: "image-summary",
        kind: .imageProcessing,
        title: "图片资源扫描",
        detail: CoreL10n.text("正在汇总当前站点图片资源…"),
        state: .running
      )
    }
    if let failure = image.lastBatchFailure {
      return WorkbenchTaskItem(
        id: "image-processing",
        kind: .imageProcessing,
        title: image.lastBatchOperation?.progressTitle ?? WorkbenchTaskKind.imageProcessing.title,
        detail: "图片处理失败：\(failure)",
        state: .failed,
        failureReason: failure
      )
    }
    if let failure = image.siteSummaryErrorMessage?.nilIfEmpty {
      let retryIntent: WorkbenchTaskRetryIntent?
      if let profileID = imageSummaryFailureProfileID,
        profileID == store.activeProfileID
      {
        retryIntent = .imageSummary(profileID: profileID)
      } else {
        retryIntent = nil
      }
      return WorkbenchTaskItem(
        id: "image-summary",
        kind: .imageProcessing,
        title: "图片资源扫描",
        detail: "图片资源扫描失败：\(failure)",
        state: .failed,
        failureReason: failure,
        retryIntent: retryIntent
      )
    }
    return nil
  }

  private var siteScanTask: WorkbenchTaskItem? {
    let state = store.repositoryScanState
    if state.isScanning {
      return WorkbenchTaskItem(
        id: "site-scan",
        kind: .siteScan,
        detail: state.message,
        state: .running
      )
    }
    guard
      let repositoryFailure = store.repositoryReport?.preflightIssues.first(where: {
        $0.severity == .error && $0.field == "repository"
      })
    else {
      return nil
    }
    return WorkbenchTaskItem(
      id: "site-scan",
      kind: .siteScan,
      detail: repositoryFailure.message,
      state: .failed,
      failureReason: repositoryFailure.message,
      canRetry: true,
      retryIntent: .siteScan(profileID: store.activeProfileID)
    )
  }

  private var gitTask: WorkbenchTaskItem? {
    let repository = store.repositoryStore
    let publishing = store.publishingStore
    let progress = repository.remoteRepositoryPublishProgress
    let isRunning =
      repository.isRemoteRepositoryPublishing
      || repository.isRemoteRepositoryChecking
      || publishing.isLocalRepositoryMutationRunning
    if isRunning {
      let detail =
        progress?.statusDescription
        ?? publishing.publishActionMessage
        ?? (repository.isRemoteRepositoryChecking ? "正在检查远端仓库权限…" : "正在执行 Git 操作…")
      return WorkbenchTaskItem(
        id: "git-push",
        kind: .gitPush,
        detail: detail,
        progress: progress?.byteProgress,
        state: .running
      )
    }
    if let progress, progress.stage == .failed {
      let reason = progress.detail ?? progress.message
      let retryIntent = failedGitRetryIntent
      return WorkbenchTaskItem(
        id: "git-push",
        kind: .gitPush,
        detail: reason,
        state: .failed,
        failureReason: reason,
        canRetry: retryIntent != nil,
        retryIntent: retryIntent
      )
    }
    guard let feedback = publishing.publishActionFeedback,
      feedback.status == .failure
    else { return nil }
    let retryIntent = failedGitRetryIntent
    return WorkbenchTaskItem(
      id: "git-push",
      kind: .gitPush,
      detail: feedback.message,
      state: .failed,
      failureReason: feedback.message,
      canRetry: retryIntent != nil,
      retryIntent: retryIntent
    )
  }

  private var deploymentTask: WorkbenchTaskItem? {
    let records = store.activeProfileReleaseRecords
    let candidate = records.first { record in
      guard let snapshot = store.deploymentStore.deploymentStatusSnapshot(for: record) else {
        return false
      }
      return snapshot.level == .running || snapshot.level == .failed
    }
    let isChecking = store.deploymentStore.isDeploymentStatusChecking
    guard isChecking || candidate != nil else { return nil }
    let snapshot = candidate.flatMap { store.deploymentStore.deploymentStatusSnapshot(for: $0) }
    if let snapshot, snapshot.level == .failed {
      return WorkbenchTaskItem(
        id: "deployment-\(candidate?.id.uuidString ?? "latest")",
        kind: .deployment,
        detail: snapshot.message,
        state: .failed,
        failureReason: snapshot.message,
        canRetry: candidate != nil,
        targetID: candidate?.id,
        retryIntent: candidate.map { .deployment(recordID: $0.id) }
      )
    }
    return WorkbenchTaskItem(
      id: candidate.map { "deployment-\($0.id.uuidString)" } ?? "deployment-latest",
      kind: .deployment,
      detail: store.deploymentStore.deploymentStatusMessage ?? snapshot?.message ?? "正在检查部署状态…",
      state: .running,
      canRetry: false,
      targetID: candidate?.id
    )
  }

  private var failedGitRetryIntent: WorkbenchTaskRetryIntent? {
    if lastGitOperationKind != .local,
      let record = store.activeProfileReleaseRecords.first(where: {
      $0.kind == .remotePublishFailure
    })
    {
      if !record.batchItems.isEmpty {
        return .gitRemoteBatch(
          profileID: record.siteProfileID ?? store.activeProfileID,
          draftIDs: record.batchItems.map(\.draftID)
        )
      }
      if let draftID = record.draftID {
        return .gitRemoteDraft(
          profileID: record.siteProfileID ?? store.activeProfileID,
          draftID: draftID
        )
      }
    }
    guard lastGitOperationKind == .local else { return nil }
    return gitRetryIntent
  }

  private func retryGitDraft(profileID: UUID, draftID: UUID, remote: Bool) async {
    guard store.drafts.contains(where: {
      $0.id == draftID && $0.siteProfileID == profileID
    }) else {
      return
    }
    guard store.focusDraft(draftID, section: .writing) else { return }
    if remote {
      _ = await store.publishSelectedDraftOnlineUsingPreferredStrategy()
    } else if store.repository.report?.hasGitDirectory == false {
      _ = await store.writeSelectedDraftToLocalRepository()
    } else {
      await store.commitSelectedDraftUsingPreferredStrategy()
    }
  }

  private func retryGitRemoteBatch(profileID: UUID, draftIDs: [UUID]) async {
    guard !draftIDs.isEmpty,
      draftIDs.allSatisfy({ draftID in
        store.drafts.contains { $0.id == draftID && $0.siteProfileID == profileID }
      })
    else {
      return
    }
    if store.activeProfileID != profileID {
      guard let firstDraftID = draftIDs.first,
        store.focusDraft(firstDraftID, section: .sync)
      else { return }
    }
    guard store.activeProfileID == profileID else { return }
    await store.refreshBatchPublishPlanAsync()
    guard let plan = store.batchPublishPlan,
      plan.profileID == profileID,
      Set(plan.remotePublishableItems.map(\.draftID)) == Set(draftIDs)
    else {
      store.setPublishActionMessage(
        "待重试的批量发布队列已变化，请重新审阅后再发布。",
        status: .warning
      )
      return
    }
    _ = await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy()
  }

  private func observeGitOperation(
    _ publisher: Published<Bool>.Publisher,
    kind: GitOperationKind
  ) {
    publisher
      .dropFirst()
      .sink { [weak self] isRunning in
        guard let self else { return }
        if isRunning {
          if self.activeGitOperationKind != kind {
            self.activeGitOperationKind = kind
            self.lastGitOperationKind = kind
            self.gitRetryIntent = self.makeGitRetryIntent(for: kind)
          }
        } else if self.activeGitOperationKind == kind {
          self.activeGitOperationKind = nil
        }
        self.objectWillChange.send()
      }
      .store(in: &cancellables)
  }

  private func makeGitRetryIntent(
    for kind: GitOperationKind
  ) -> WorkbenchTaskRetryIntent? {
    guard let draftID = store.selectedDraft?.id else { return nil }
    switch kind {
    case .local:
      return .gitDraft(profileID: store.activeProfileID, draftID: draftID)
    case .remote:
      return .gitRemoteDraft(profileID: store.activeProfileID, draftID: draftID)
    }
  }

  private func failureReason(in message: String?) -> String? {
    guard let message = message?.trimmedForPublishing.nilIfEmpty else { return nil }
    let markers = ["失败", "错误", "超时", "拒绝", "无法", "不可用", "未配置", "未保存"]
    return markers.contains(where: message.contains) ? message : nil
  }

  private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }

  private func observeAIMessage(_ publisher: Published<String?>.Publisher) {
    publisher
      .dropFirst()
      .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)
      .sink { [weak self] _ in
        guard let self else { return }
        let ai = self.store.aiWorkspaceStore
        guard
          ai.isAIChatRunning
            || ai.isAIActionRunning
            || ai.isAIMetadataSuggestionRunning
            || ai.isAutomationRunning
            || ai.isAIImageTextRunning
            || self.store.aiStore.aiChatManualRetryState != nil
            || self.store.aiStore.aiGeneralChatManualRetryState != nil
        else {
          return
        }
        self.objectWillChange.send()
      }
      .store(in: &cancellables)
  }

  private func observeImageSummaryFailure(
    _ publisher: Published<String?>.Publisher
  ) {
    publisher
      .dropFirst()
      .sink { [weak self] message in
        guard let self else { return }
        if message?.nilIfEmpty != nil {
          self.imageSummaryFailureProfileID = self.store.activeProfileID
        } else {
          self.imageSummaryFailureProfileID = nil
        }
        self.objectWillChange.send()
      }
      .store(in: &cancellables)
  }
}
