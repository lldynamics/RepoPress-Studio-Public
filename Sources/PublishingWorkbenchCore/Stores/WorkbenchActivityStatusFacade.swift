import Combine
import Foundation

@MainActor
public final class WorkbenchActivityStatusFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  init(store: WorkbenchStore) {
    self.store = store
    observe(store.privacyProtectionStore.$isQuickHideActive)
    observe(store.repositoryStore.$repositoryScanState)
    observe(store.repositoryStore.$isRemoteRepositoryPublishing)
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
    observe(store.knowledge.$isImporting)
    observe(store.knowledge.$importProgress)
    observe(store.knowledge.$importOperationTitle)
    observe(store.knowledge.$lastImportFailure)
    observe(store.knowledge.$statusMessage)
    observe(store.publishingStore.$isLocalRepositoryMutationRunning)
    observe(store.publishingStore.$publishActionFeedback)
    observe(store.publishingStore.$releaseRecords)
    observe(store.imageStore.$imageBatchProgress)
    observe(store.imageStore.$isImageBatchProcessing)
    observe(store.imageStore.$lastBatchFailure)
    observe(store.imageStore.$lastBatchOperation)
    observe(store.imageStore.$isSiteSummaryLoading)
    observe(store.imageStore.$siteSummaryErrorMessage)
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

  public func retryTask(_ task: WorkbenchTaskItem) async {
    switch task.kind {
    case .aiRequest:
      _ = await store.aiStore.retryLastFailedAIChatReply(
        confirmingPossibleDuplicateCharge: true,
        draft: store.selectedDraft
      )
    case .knowledgeImport:
      await store.knowledge.retryLastImport()
    case .imageProcessing:
      if task.id == "image-summary" {
        await store.refreshImageWorkbenchSiteSummaryInBackground(force: true)
      } else {
        store.imageStore.retryLastBatch()
      }
    case .siteScan:
      await store.repository.scanAsync()
    case .gitPush:
      await retryGitTask()
    case .deployment:
      guard let recordID = UUID(uuidString: task.id.replacingOccurrences(of: "deployment-", with: "")),
            let record = store.activeProfileReleaseRecords.first(where: { $0.id == recordID }) else {
        return
      }
      _ = await store.refreshDeploymentStatus(for: record)
    }
  }

  private var aiTask: WorkbenchTaskItem? {
    let ai = store.aiWorkspaceStore
    let isRunning = ai.isAIChatRunning
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
    guard let failure = failureReason(in: message) else { return nil }
    return WorkbenchTaskItem(
      id: "ai-request",
      kind: .aiRequest,
      detail: failure,
      state: .failed,
      failureReason: failure,
      canRetry: store.aiStore.aiChatManualRetryState != nil
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
      failureReason: failure,
      canRetry: true
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
        failureReason: failure,
        canRetry: true
      )
    }
    if let failure = image.siteSummaryErrorMessage?.nilIfEmpty {
      return WorkbenchTaskItem(
        id: "image-summary",
        kind: .imageProcessing,
        title: "图片资源扫描",
        detail: "图片资源扫描失败：\(failure)",
        state: .failed,
        failureReason: failure,
        canRetry: true
      )
    }
    return nil
  }

  private var siteScanTask: WorkbenchTaskItem? {
    let state = store.repositoryStore.repositoryScanState
    if state.isScanning {
      return WorkbenchTaskItem(
        id: "site-scan",
        kind: .siteScan,
        detail: state.message,
        state: .running
      )
    }
    guard let repositoryFailure = store.repositoryReport?.preflightIssues.first(where: {
      $0.severity == .error && $0.field == "repository"
    }) else {
      return nil
    }
    return WorkbenchTaskItem(
      id: "site-scan",
      kind: .siteScan,
      detail: repositoryFailure.message,
      state: .failed,
      failureReason: repositoryFailure.message,
      canRetry: true
    )
  }

  private var gitTask: WorkbenchTaskItem? {
    let repository = store.repositoryStore
    let publishing = store.publishingStore
    let progress = repository.remoteRepositoryPublishProgress
    let isRunning = repository.isRemoteRepositoryPublishing
      || repository.isRemoteRepositoryChecking
      || publishing.isLocalRepositoryMutationRunning
    if isRunning {
      let detail = progress.map { [$0.message, $0.detail].compactMap { $0?.nilIfEmpty }.joined(separator: " · ") }
        ?? publishing.publishActionMessage
        ?? (repository.isRemoteRepositoryChecking ? "正在检查远端仓库权限…" : "正在执行 Git 操作…")
      return WorkbenchTaskItem(
        id: "git-push",
        kind: .gitPush,
        detail: detail,
        progress: progress?.progress,
        state: .running
      )
    }
    if let progress, progress.stage == .failed {
      let reason = progress.detail ?? progress.message
      return WorkbenchTaskItem(
        id: "git-push",
        kind: .gitPush,
        detail: reason,
        state: .failed,
        failureReason: reason,
        canRetry: true
      )
    }
    guard let feedback = publishing.publishActionFeedback,
      feedback.status == .failure
    else { return nil }
    return WorkbenchTaskItem(
      id: "git-push",
      kind: .gitPush,
      detail: feedback.message,
      state: .failed,
      failureReason: feedback.message,
      canRetry: store.selectedDraft != nil
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
        canRetry: candidate != nil
      )
    }
    return WorkbenchTaskItem(
      id: candidate.map { "deployment-\($0.id.uuidString)" } ?? "deployment-latest",
      kind: .deployment,
      detail: store.deploymentStore.deploymentStatusMessage ?? snapshot?.message ?? "正在检查部署状态…",
      state: .running,
      canRetry: false
    )
  }

  private func retryGitTask() async {
    if let record = store.activeProfileReleaseRecords.first(where: {
      $0.kind == .remotePublishFailure
    }), let draftID = record.draftID {
      _ = store.focusDraft(draftID, section: .writing)
      _ = await store.publishSelectedDraftOnlineUsingPreferredStrategy()
      return
    }
    if store.publishingStore.publishActionMessage?.contains("写入") == true {
      _ = await store.writeSelectedDraftToLocalRepository()
    } else {
      await store.commitSelectedDraftUsingPreferredStrategy()
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
      .sink { [weak self] _ in
        guard let self else { return }
        let ai = self.store.aiWorkspaceStore
        guard ai.isAIChatRunning
          || ai.isAIActionRunning
          || ai.isAIMetadataSuggestionRunning
          || ai.isAutomationRunning
          || ai.isAIImageTextRunning
          || self.store.aiStore.aiChatManualRetryState != nil
        else {
          return
        }
        self.objectWillChange.send()
      }
      .store(in: &cancellables)
  }
}
