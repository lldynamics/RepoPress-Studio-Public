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
  private var gitOperationID = UUID()
  private var releaseRecordIDsBeforeGitOperation: Set<UUID>?
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
      store.publishingStore.publishSession.$isLocalRepositoryMutationRunning,
      kind: .local
    )
    observe(store.publishingStore.publishSession.$publishActionFeedback)
    observe(store.publishingStore.publishSession.$releaseRecords)
    observe(store.publishingStore.$activeProfileID)
    observe(store.imageStore.$imageBatchProgress)
    observe(store.imageStore.$isImageBatchProcessing)
    observe(store.imageStore.$lastBatchFailure)
    observe(store.imageStore.$imageBatchTaskOwner)
    observe(store.imageStore.$lastBatchOperation)
    observe(store.imageStore.$isSiteSummaryLoading)
    observeImageSummaryFailure(store.imageStore.$siteSummaryErrorMessage)
    observe(store.imageWorkbench.objectWillChange)
    observe(store.deploymentStore.$isDeploymentStatusChecking)
    observe(store.deploymentStore.$deploymentStatusMessage)
    observe(store.deploymentStore.$deploymentStatusSnapshots)
    observe(store.persistenceStore.$lastSaveError)
    observe(store.persistenceStore.$status)
    observe(store.$draftRecoveryJournalErrorMessage)
    observe(store.$siteDraftFileFlushFailureIDs)
    observe(store.$siteDraftFileSaveStates)
    observe(store.$siteDraftFileSaveFailures)
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
    tasks.append(contentsOf: assetResourceTasks)
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

  public var waitingTaskCount: Int {
    taskCenterItems.filter { $0.state == .waiting || $0.state == .needsAttention }.count
  }

  public var failedTaskCount: Int {
    taskCenterItems.filter(\.isFailure).count
  }

  /// Opens exactly the persisted target carried by a task. The task center
  /// never falls back to the article or site that happens to be selected.
  @discardableResult
  public func locateTask(_ task: WorkbenchTaskItem, windowID: UUID? = nil) -> String? {
    guard let target = task.target else {
      return CoreL10n.text("此任务没有稳定的定位目标。")
    }
    switch target {
    case .draft(let draftID):
      guard store.focusDraft(draftID, section: .writing) else {
        return CoreL10n.text("目标文章已不存在或无法访问。")
      }
    case .articleConversation(let draftID, let conversationID):
      guard store.drafts.contains(where: { $0.id == draftID }),
        store.aiStore.aiChatConversations(for: draftID).contains(where: { $0.id == conversationID }
        ),
        store.aiStore.openAIChatWorkspace(for: draftID),
        store.aiStore.selectAIChatConversation(conversationID)
      else {
        return CoreL10n.text("目标文章或 AI 对话已不存在或无法访问。")
      }
    case .generalAIConversation(let conversationID):
      guard
        store.aiStore.aiConversations.contains(where: {
          $0.id == conversationID && $0.scope == .general && !$0.isArchived
        }), store.aiStore.selectGeneralAIChatConversation(conversationID)
      else {
        return CoreL10n.text("目标通用 AI 对话已不存在或无法访问。")
      }
      store.setAIChatContextMode(.general)
      store.setInspectorPresented(true)
    case .siteProfile(let profileID):
      guard store.profiles.contains(where: { $0.id == profileID }) else {
        return CoreL10n.text("目标站点已不存在或无法访问。")
      }
      store.selectProfile(profileID)
      store.selectSection(.sync)
    case .siteProfilePage(let profileID, let section):
      guard store.profiles.contains(where: { $0.id == profileID }) else {
        return CoreL10n.text("目标站点已不存在或无法访问。")
      }
      store.selectProfile(profileID)
      store.selectSection(section)
    case .assetResourceManager(let profileID):
      guard store.profiles.contains(where: { $0.id == profileID }) else {
        return CoreL10n.text("目标站点已不存在或无法访问。")
      }
      store.selectProfile(profileID)
      store.selectSection(.images)
      store.imageWorkbench.requestAssetResourceManagerNavigation(for: profileID, windowID: windowID)
    case .releaseRecord(let recordID):
      guard let record = store.releaseRecords.first(where: { $0.id == recordID }) else {
        return CoreL10n.text("目标发布记录已不存在或无法访问。")
      }
      if let profileID = record.siteProfileID {
        guard store.profiles.contains(where: { $0.id == profileID }) else {
          return CoreL10n.text("目标发布记录所属站点已不存在，未打开其他站点记录。")
        }
        store.selectProfile(profileID)
      }
      store.selectSection(.sync)
    }
    return nil
  }

  /// Stops only the exact AI operation shown in the task row. Operation and
  /// conversation identity are both rechecked at click time so an old row
  /// cannot cancel a later reply after focus has changed.
  @discardableResult
  public func cancelTask(_ task: WorkbenchTaskItem) -> String? {
    guard task.canCancel, let intent = task.cancellationIntent else {
      return CoreL10n.text("此任务当前不支持安全停止。")
    }
    switch intent {
    case .aiChat(let operationID, let target):
      guard task.target == target,
        activeAIChatTarget == target,
        store.aiStore.activeAIChatOperationID == operationID,
        store.aiStore.requestAIChatCancellation(expectedOperationID: operationID)
      else {
        return CoreL10n.text("任务已变化或已结束，未停止其他操作。")
      }
      return nil
    }
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

    if task.requiresPublishReview {
      if let message = locateTask(task) {
        store.setPublishActionMessage(message, status: .warning)
      } else {
        store.setPublishActionMessage(
          CoreL10n.text("已定位原操作。请核对原分支和发布方式，重新审阅后再执行；未自动提交或推送。"),
          status: .information
        )
      }
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
    case .gitDraft, .gitRemoteDraft, .gitRemoteBatch:
      return
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
      let target = activeAIChatTarget
      let cancellationIntent = store.aiStore.activeAIChatOperationID.flatMap { operationID in
        target.map { WorkbenchTaskCancellationIntent.aiChat(operationID: operationID, target: $0) }
      }
      return WorkbenchTaskItem(
        id: "ai-request",
        kind: .aiRequest,
        detail: message ?? CoreL10n.text("正在等待 AI 服务响应…"),
        state: .running,
        target: target,
        cancellationIntent: cancellationIntent
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
      retryIntent: retryIntent,
      target: retryIntent.flatMap(taskTarget(for:))
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
    let batchTarget = image.imageBatchTaskOwner?.profileID.map {
      WorkbenchTaskTarget.siteProfilePage(profileID: $0, section: .images)
    }
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
        state: .running,
        target: batchTarget
      )
    }
    if image.isSiteSummaryLoading {
      return WorkbenchTaskItem(
        id: "image-summary",
        kind: .imageProcessing,
        title: "图片资源扫描",
        detail: CoreL10n.text("正在汇总当前站点图片资源…"),
        state: .running,
        target: .siteProfilePage(profileID: store.activeProfileID, section: .images)
      )
    }
    if let failure = image.lastBatchFailure {
      return WorkbenchTaskItem(
        id: "image-processing",
        kind: .imageProcessing,
        title: image.lastBatchOperation?.progressTitle ?? WorkbenchTaskKind.imageProcessing.title,
        detail: "图片处理失败：\(failure)",
        state: .failed,
        failureReason: failure,
        target: batchTarget
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
        retryIntent: retryIntent,
        target: retryIntent.flatMap(taskTarget(for:))
      )
    }
    return nil
  }

  private var assetResourceTasks: [WorkbenchTaskItem] {
    store.imageWorkbench.assetResourceOperationTaskDescriptors.map { descriptor in
      assetResourceTask(from: descriptor)
    }
  }

  private func assetResourceTask(
    from descriptor: AssetResourceOperationTaskDescriptor
  ) -> WorkbenchTaskItem {
    let profileID = descriptor.profileID
    let state: WorkbenchTaskState
    let detail: String
    let failureReason: String?
    switch descriptor.presentation {
    case .loading(let loadingDetail):
      state = .running
      detail = loadingDetail
      failureReason = nil
    case .success(let completionDetail):
      state = .completed
      detail = completionDetail
      failureReason = nil
    case .partialSuccess(let completionDetail):
      state = .needsAttention
      detail = completionDetail
      failureReason = nil
    case .failure(let reason):
      state = .failed
      detail = reason
      failureReason = reason
    }
    return WorkbenchTaskItem(
      id: "asset-resource-\(profileID.uuidString)",
      kind: .imageProcessing,
      title: descriptor.title,
      detail: detail,
      state: state,
      failureReason: failureReason,
      target: .assetResourceManager(profileID: profileID)
    )
  }

  private var siteScanTask: WorkbenchTaskItem? {
    let state = store.repositoryScanState
    if state.isScanning {
      return WorkbenchTaskItem(
        id: "site-scan",
        kind: .siteScan,
        detail: state.message,
        state: .running,
        target: .siteProfile(store.activeProfileID)
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
      retryIntent: .siteScan(profileID: store.activeProfileID),
      target: .siteProfile(store.activeProfileID)
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
        (progress?.stage == .failed ? nil : progress?.statusDescription)
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
    if lastGitOperationKind != .local, let progress, progress.stage == .failed {
      let reason = currentGitFailureRecord?.summary ?? progress.detail ?? progress.message
      let retryIntent = failedGitRetryIntent
      return WorkbenchTaskItem(
        id: currentGitFailureRecord?.id.uuidString ?? "git-\(gitOperationID)",
        kind: .gitPush,
        title: currentGitFailureRecord?.title,
        detail: gitFailureDetail(reason),
        state: .failed,
        failureReason: reason,
        canRetry: retryIntent != nil,
        retryIntent: retryIntent,
        target: currentGitFailureRecord.map { .releaseRecord($0.id) }
          ?? retryIntent.flatMap(taskTarget(for:))
      )
    }
    guard let feedback = publishing.publishActionFeedback,
      feedback.status == .failure
    else { return nil }
    let retryIntent = failedGitRetryIntent
    return WorkbenchTaskItem(
      id: currentGitFailureRecord?.id.uuidString ?? "git-\(gitOperationID)",
      kind: .gitPush,
      title: currentGitFailureRecord?.title,
      detail: gitFailureDetail(currentGitFailureRecord?.summary ?? feedback.message),
      state: .failed,
      failureReason: currentGitFailureRecord?.summary ?? feedback.message,
      canRetry: retryIntent != nil,
      retryIntent: retryIntent,
      target: currentGitFailureRecord.map { .releaseRecord($0.id) }
        ?? retryIntent.flatMap(taskTarget(for:))
    )
  }

  private var deploymentTask: WorkbenchTaskItem? {
    // A real request has its own activity; a historical provider result does
    // not mean a network operation is still executing.
    if store.deploymentStore.isDeploymentStatusChecking {
      return WorkbenchTaskItem(
        id: "deployment-check", kind: .deployment,
        detail: store.deploymentStore.deploymentStatusMessage ?? CoreL10n.text("正在检查部署状态…"),
        state: .running
      )
    }
    guard
      let record = store.activeProfileReleaseRecords.first(where: { record in
        guard let snapshot = store.deploymentStore.deploymentStatusSnapshot(for: record) else {
          return false
        }
        return snapshot.level != .success
      }), let snapshot = store.deploymentStore.deploymentStatusSnapshot(for: record)
    else { return nil }
    let state: WorkbenchTaskState =
      switch snapshot.level {
      case .failed: .failed
      case .running: .waiting
      default: .needsAttention
      }
    return WorkbenchTaskItem(
      id: "deployment-\(record.id)", kind: .deployment,
      detail: snapshot.message, state: state,
      failureReason: state == .failed ? snapshot.message : nil,
      targetID: record.id, retryIntent: .deployment(recordID: record.id),
      target: .releaseRecord(record.id), checkedAt: snapshot.checkedAt
    )
  }

  private var activeAIChatTarget: WorkbenchTaskTarget? {
    store.aiStore.activeAIChatOperationTarget
  }

  private func taskTarget(for intent: WorkbenchTaskRetryIntent) -> WorkbenchTaskTarget? {
    switch intent {
    case .aiChat(let draftID, let conversationID, _):
      .articleConversation(draftID: draftID, conversationID: conversationID)
    case .generalAIChat(let conversationID, _, _):
      .generalAIConversation(conversationID)
    case .imageSummary(let profileID):
      .siteProfilePage(profileID: profileID, section: .images)
    case .siteScan(let profileID):
      .siteProfile(profileID)
    case .gitDraft(_, let draftID), .gitRemoteDraft(_, let draftID):
      .draft(draftID)
    case .gitRemoteBatch(let profileID, _):
      .siteProfile(profileID)
    case .deployment(let recordID):
      .releaseRecord(recordID)
    case .knowledgeImport, .imageProcessing:
      nil
    }
  }

  private var currentGitFailureRecord: ReleaseRecord? {
    guard lastGitOperationKind != .local else { return nil }
    return store.activeProfileReleaseRecords.first {
      $0.kind == .remotePublishFailure
        && !(releaseRecordIDsBeforeGitOperation?.contains($0.id) ?? false)
    }
  }

  private func gitFailureDetail(_ reason: String) -> String {
    guard let record = currentGitFailureRecord, let branch = record.branchName else {
      return reason
    }
    return reason + "\n" + CoreL10n.format("原分支：%@", branch)
  }

  private var failedGitRetryIntent: WorkbenchTaskRetryIntent? {
    if let record = currentGitFailureRecord {
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
    return gitRetryIntent
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
            self.gitOperationID = UUID()
            self.releaseRecordIDsBeforeGitOperation = Set(self.store.releaseRecords.map(\.id))
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
