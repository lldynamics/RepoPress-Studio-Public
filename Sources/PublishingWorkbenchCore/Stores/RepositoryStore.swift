import Combine
import Foundation

private struct RepositoryScanSnapshot: Sendable {
  var report: RepositoryScanReport
  var branches: [RepositoryBranch]
  var recentCommits: [RepositoryCommitInfo]
}

@MainActor
public final class RepositoryStore: ObservableObject {
  private let repositoryService: LocalRepositoryService
  private let repositoryTokenStore: KeychainTokenStore
  private let remoteRepositoryPublishService: RemoteRepositoryPublishService
  private let repositorySyncCommandBuilder: RepositorySyncCommandBuilder

  @Published public internal(set) var repositoryReport: RepositoryScanReport?
  @Published public internal(set) var repositoryScanState: RepositoryScanState
  @Published public internal(set) var localGitPublishResult: LocalGitPublishResult?
  @Published public internal(set) var localRepositoryBranches: [RepositoryBranch]
  @Published public internal(set) var localRepositoryRecentCommits: [RepositoryCommitInfo]
  @Published public internal(set) var repositoryTokenAvailability: KeychainTokenAvailability
  @Published public internal(set) var remoteRepositoryAccessCheck: RemoteRepositoryAccessCheck?
  @Published public internal(set) var remoteRepositoryCreationResult: RemoteRepositoryCreationResult?
  @Published public internal(set) var remoteRepositoryPublishResult: RemoteRepositoryPublishResult?
  @Published public internal(set) var remoteRepositoryPublishProgress: RemoteRepositoryPublishProgress?
  @Published public internal(set) var remoteRepositoryRollbackResult: RemoteRepositoryRollbackResult?
  @Published public internal(set) var remoteRepositoryReviewWithdrawalResult: RemoteRepositoryReviewWithdrawalResult?
  @Published public internal(set) var isRemoteRepositoryChecking: Bool
  @Published public internal(set) var isRemoteRepositoryPublishing: Bool
  @Published public internal(set) var isLocalRepositoryBranchOperationRunning: Bool
  @Published public internal(set) var repositoryAutoSyncSettings: RepositoryAutoSyncSettings
  @Published public internal(set) var repositoryAutoSyncState: RepositoryAutoSyncState
  private var repositoryScanTask: Task<Void, Never>?
  private var repositoryScanWorkTask: Task<RepositoryScanSnapshot?, Never>?
  private var repositoryScanWorkGeneration: UInt64 = 0
  private var repositoryScanGeneration: UInt64 = 0
  private var repositoryAutoSyncTask: Task<Bool, Never>?
  private var repositoryAutoSyncGeneration: UInt64 = 0
  private var remoteRepositoryCheckContext: RemoteRepositoryOperationContext?

  init(
    repositoryReport: RepositoryScanReport? = nil,
    repositoryScanState: RepositoryScanState = .idle,
    localGitPublishResult: LocalGitPublishResult? = nil,
    localRepositoryBranches: [RepositoryBranch] = [],
    localRepositoryRecentCommits: [RepositoryCommitInfo] = [],
    repositoryTokenAvailability: KeychainTokenAvailability = KeychainTokenAvailability(hasToken: false),
    remoteRepositoryAccessCheck: RemoteRepositoryAccessCheck? = nil,
    remoteRepositoryCreationResult: RemoteRepositoryCreationResult? = nil,
    remoteRepositoryPublishResult: RemoteRepositoryPublishResult? = nil,
    remoteRepositoryPublishProgress: RemoteRepositoryPublishProgress? = nil,
    remoteRepositoryRollbackResult: RemoteRepositoryRollbackResult? = nil,
    remoteRepositoryReviewWithdrawalResult: RemoteRepositoryReviewWithdrawalResult? = nil,
    isRemoteRepositoryChecking: Bool = false,
    isRemoteRepositoryPublishing: Bool = false,
    isLocalRepositoryBranchOperationRunning: Bool = false,
    repositoryAutoSyncSettings: RepositoryAutoSyncSettings = .default,
    repositoryAutoSyncState: RepositoryAutoSyncState = .idle,
    repositoryService: LocalRepositoryService = LocalRepositoryService(),
    repositoryTokenStore: KeychainTokenStore = KeychainTokenStore(service: KeychainCredentialServices.repository),
    remoteRepositoryPublishService: RemoteRepositoryPublishService = RemoteRepositoryPublishService(),
    repositorySyncCommandBuilder: RepositorySyncCommandBuilder = RepositorySyncCommandBuilder()
  ) {
    self.repositoryService = repositoryService
    self.repositoryTokenStore = repositoryTokenStore
    self.remoteRepositoryPublishService = remoteRepositoryPublishService
    self.repositorySyncCommandBuilder = repositorySyncCommandBuilder
    self.repositoryReport = repositoryReport
    self.repositoryScanState = repositoryScanState
    self.localGitPublishResult = localGitPublishResult
    self.localRepositoryBranches = localRepositoryBranches
    self.localRepositoryRecentCommits = localRepositoryRecentCommits
    self.repositoryTokenAvailability = repositoryTokenAvailability
    self.remoteRepositoryAccessCheck = remoteRepositoryAccessCheck
    self.remoteRepositoryCreationResult = remoteRepositoryCreationResult
    self.remoteRepositoryPublishResult = remoteRepositoryPublishResult
    self.remoteRepositoryPublishProgress = remoteRepositoryPublishProgress
    self.remoteRepositoryRollbackResult = remoteRepositoryRollbackResult
    self.remoteRepositoryReviewWithdrawalResult = remoteRepositoryReviewWithdrawalResult
    self.isRemoteRepositoryChecking = isRemoteRepositoryChecking
    self.isRemoteRepositoryPublishing = isRemoteRepositoryPublishing
    self.isLocalRepositoryBranchOperationRunning = isLocalRepositoryBranchOperationRunning
    self.repositoryAutoSyncSettings = repositoryAutoSyncSettings
    self.repositoryAutoSyncState = repositoryAutoSyncState
  }

  public func repositoryReport(for profile: SiteProfile, store: WorkbenchStore) -> RepositoryScanReport? {
    guard let repositoryReport else { return nil }
    guard let configuredIdentity = LocalRepositoryIdentity(profile: profile) else {
      return profile.id == store.activeProfileID ? repositoryReport : nil
    }
    return LocalRepositoryIdentity(rootPath: repositoryReport.rootPath) == configuredIdentity
      ? repositoryReport
      : nil
  }

  public func scanRepositoryAsync(store: WorkbenchStore) async {
    await scanRepositoryAsync(store: store, autoSyncGeneration: nil)
  }

  private func scanRepositoryAsync(
    store: WorkbenchStore,
    autoSyncGeneration: UInt64?
  ) async {
    if autoSyncGeneration == nil {
      invalidateRepositoryAutoSyncRun()
    }
    repositoryScanTask?.cancel()
    repositoryScanWorkTask?.cancel()
    repositoryScanGeneration &+= 1
    let scanGeneration = repositoryScanGeneration
    repositoryScanState = .scanning()
    let profile = store.activeProfile
    let operation = LocalRepositoryOperationContext(profile: profile)
    let repositoryService = repositoryService
    let previousScanWork = repositoryScanWorkTask
    repositoryScanWorkGeneration &+= 1
    let scanWorkGeneration = repositoryScanWorkGeneration
    let scanWork: Task<RepositoryScanSnapshot?, Never> = Task.detached(priority: .utility) {
      if let previousScanWork {
        _ = await previousScanWork.value
      }
      guard !Task.isCancelled else { return nil }
      let report = repositoryService.scan(
        profile: profile,
        cancellationCheck: {
          withUnsafeCurrentTask { $0?.isCancelled == true }
        }
      )
      guard !Task.isCancelled else { return nil }
      let branches = repositoryService.localBranches(profile: profile)
      guard !Task.isCancelled else { return nil }
      let recentCommits = repositoryService.recentCommits(profile: profile)
      guard !Task.isCancelled else { return nil }
      return RepositoryScanSnapshot(
        report: report,
        branches: branches,
        recentCommits: recentCommits
      )
    }
    repositoryScanWorkTask = scanWork
    let scanTask = Task { @MainActor [weak self] in
      let snapshot = await scanWork.value
      guard let self else { return }
      self.finishRepositoryScanWorkIfCurrent(generation: scanWorkGeneration)
      guard let snapshot else { return }
      guard self.isCurrentRepositoryScan(
        generation: scanGeneration,
        operation: operation,
        autoSyncGeneration: autoSyncGeneration,
        store: store
      ) else {
        self.finishStaleRepositoryScanIfNeeded(generation: scanGeneration, operation: operation, store: store)
        return
      }
      repositoryReport = snapshot.report
      localRepositoryBranches = snapshot.branches
      localRepositoryRecentCommits = snapshot.recentCommits
      repositoryScanState = .finished(report: snapshot.report)
      store.publishingStore.refreshLocalSitePreviewPlan(
        for: store.activeProfile,
        repositoryReport: snapshot.report
      )
      store.runPreflight()
      store.refreshPublishPreviewInBackground(for: store.selectedDraft)
      await store.publishingStore.waitForPublishPreviewRefresh()
      repositoryScanTask = nil
    }
    repositoryScanTask = scanTask
    await scanTask.value
  }

  public func cancelRepositoryScan() {
    invalidateRepositoryAutoSyncRun()
    repositoryScanTask?.cancel()
    repositoryScanWorkTask?.cancel()
    repositoryScanTask = nil
    repositoryScanGeneration &+= 1
    repositoryScanState = .cancelled()
  }

  private func isCurrentRepositoryScan(
    generation: UInt64,
    operation: LocalRepositoryOperationContext,
    autoSyncGeneration: UInt64?,
    store: WorkbenchStore
  ) -> Bool {
    guard repositoryScanGeneration == generation, operation.stillMatches(store.activeProfile) else {
      return false
    }
    guard let autoSyncGeneration else { return true }
    return isCurrentRepositoryAutoSync(generation: autoSyncGeneration, operation: operation, store: store)
  }

  private func finishStaleRepositoryScanIfNeeded(
    generation: UInt64,
    operation: LocalRepositoryOperationContext,
    store: WorkbenchStore
  ) {
    guard repositoryScanGeneration == generation else { return }
    repositoryScanTask = nil
    if !operation.stillMatches(store.activeProfile), repositoryScanState.isScanning {
      repositoryScanState = .idle
    }
  }

  private func finishRepositoryScanWorkIfCurrent(generation: UInt64) {
    guard repositoryScanWorkGeneration == generation else { return }
    repositoryScanWorkTask = nil
  }

  private func isCurrentRepositoryAutoSync(
    generation: UInt64,
    operation: LocalRepositoryOperationContext,
    store: WorkbenchStore
  ) -> Bool {
    repositoryAutoSyncGeneration == generation && operation.stillMatches(store.activeProfile)
  }

  private func invalidateRepositoryAutoSyncRun() {
    repositoryAutoSyncGeneration &+= 1
    repositoryAutoSyncTask?.cancel()
    repositoryAutoSyncTask = nil
  }

  public func rememberRepositoryRootAsync(_ url: URL, store: WorkbenchStore) async {
    var profile = store.activeProfile
    _ = profile.rememberLocalRepositoryRoot(url)
    store.updateActiveProfile(profile)
    await scanRepositoryAsync(store: store)
    store.save()
  }

  public func repositorySyncCommandPlan(store: WorkbenchStore) -> RepositorySyncCommandPlan? {
    repositorySyncCommandBuilder.plan(report: repositoryReport, profile: store.activeProfile)
  }

  public var repositoryAutoSyncReviewMarkdown: String {
    var lines = [
      """
    # 仓库远端自动检查审阅

    - 状态：\(repositoryAutoSyncState.status.displayName)
    - 启用：\(repositoryAutoSyncSettings.isEnabled ? "是" : "否")
    - 间隔：\(repositoryAutoSyncSettings.normalizedIntervalMinutes) 分钟
    - 自动导入远端文章：\(repositoryAutoSyncSettings.autoImportRemoteArticles ? "是" : "否")
    - 远端变更：\(repositoryAutoSyncState.remoteChangedFileCount)
    - 消息：\(repositoryAutoSyncState.message)
    """
    ]
    if let lastAutoImportAt = repositoryAutoSyncState.lastAutoImportAt {
      lines.append("\n## 最近自动导入\n")
      lines.append("- 时间：\(lastAutoImportAt)")
      lines.append("- 导入文章：\(repositoryAutoSyncState.lastAutoImportedArticleCount)")
      lines.append("- 本地冲突：\(repositoryAutoSyncState.lastAutoImportConflictCount)")
      lines.append("- 远端删除待确认：\(repositoryAutoSyncState.lastAutoImportDeletionCount)")
    }
    if let provider = repositoryAutoSyncState.lastRemotePublishProvider,
       let mode = repositoryAutoSyncState.lastRemotePublishMode {
      lines.append("\n## 最近线上写入\n")
      lines.append("- 平台：\(provider.displayName)")
      lines.append("- 模式：\(mode.displayName)")
      lines.append(contentsOf: repositoryAutoSyncState.lastRemotePublishPaths.map { "- \($0)" })
    }
    return lines.joined(separator: "\n")
  }

  public func applyDetectedRepositoryRemote(store: WorkbenchStore) {
    guard let remote = repositoryReport?.originRemote else {
      store.setPublishActionMessage(
        CoreL10n.text("没有检测到 origin 远端。"),
        status: .warning
      )
      return
    }
    var profile = store.activeProfile
    profile.repositoryProvider = remote.provider
    profile.repositoryBaseURL = remote.repositoryBaseURL
    profile.repoOwner = remote.owner
    profile.repoName = remote.name
    if let detectedBranch = repositoryReport?.branchStatus?.branchName?.nilIfEmpty {
      profile.branch = detectedBranch
    }
    store.updateActiveProfile(profile)
    store.setPublishActionMessage(
      CoreL10n.format("已使用 %@ 更新 PR/MR 配置。", remote.displayName),
      status: .success
    )
    store.save()
  }

  public func setRepositoryProvider(_ provider: RepositoryProvider, store: WorkbenchStore) {
    var profile = store.activeProfile
    let currentDefault = profile.repositoryProvider.defaultBaseURL
    let shouldUseProviderDefault = profile.repositoryBaseURL.trimmedForPublishing.isEmpty
      || profile.repositoryBaseURL == currentDefault
    profile.repositoryProvider = provider
    if shouldUseProviderDefault {
      profile.repositoryBaseURL = provider.defaultBaseURL
    }
    store.updateActiveProfile(profile)
    store.save()
  }

  public func switchActiveProfileRepositoryBranch(to branchName: String, store: WorkbenchStore) async {
    guard !isLocalRepositoryBranchOperationRunning else { return }
    let branchName = branchName.trimmedForPublishing
    let profile = store.activeProfile
    let operation = LocalRepositoryOperationContext(profile: profile)
    isLocalRepositoryBranchOperationRunning = true
    defer { isLocalRepositoryBranchOperationRunning = false }

    let result: Result<Void, LocalRepositoryServiceError> = await Task.detached(
      priority: .userInitiated
    ) { [repositoryService] in
      do {
        try repositoryService.switchLocalBranch(profile: profile, to: branchName)
        return .success(())
      } catch let error as LocalRepositoryServiceError {
        return .failure(error)
      } catch {
        return .failure(.commandFailed(terminated: -1, output: error.localizedDescription))
      }
    }.value
    switch result {
    case .success:
      if alignPublishTarget(profileID: profile.id, branchName: branchName, store: store) {
        await scanRepositoryAsync(store: store)
        store.setPublishActionMessage(
          CoreL10n.format("已切换本地工作分支并将发布目标设为 %@。", branchName),
          status: .success
        )
      } else {
        store.setPublishActionMessage(
          CoreL10n.format("原站点仓库已切换到 %@；当前站点已变化，未覆盖当前界面状态。", branchName),
          status: .warning
        )
      }
    case .failure(let error):
      let prefix = operation.stillMatches(store.activeProfile) ? "切换分支失败" : "原站点切换分支失败"
      store.setPublishActionMessage(
        CoreL10n.format("%@：%@", prefix, error.localizedDescription),
        status: .failure
      )
    }
  }

  public func createAndSwitchActiveProfileRepositoryBranch(
    name branchName: String,
    from sourceBranch: String? = nil,
    store: WorkbenchStore
  ) async {
    guard !isLocalRepositoryBranchOperationRunning else { return }
    let branchName = branchName.trimmedForPublishing
    let profile = store.activeProfile
    let operation = LocalRepositoryOperationContext(profile: profile)
    isLocalRepositoryBranchOperationRunning = true
    defer { isLocalRepositoryBranchOperationRunning = false }

    let result: Result<Void, LocalRepositoryServiceError> = await Task.detached(
      priority: .userInitiated
    ) { [repositoryService] in
      do {
        try repositoryService.createAndSwitchLocalBranch(
          profile: profile,
          branchName: branchName,
          from: sourceBranch
        )
        return .success(())
      } catch let error as LocalRepositoryServiceError {
        return .failure(error)
      } catch {
        return .failure(.commandFailed(terminated: -1, output: error.localizedDescription))
      }
    }.value
    switch result {
    case .success:
      if alignPublishTarget(profileID: profile.id, branchName: branchName, store: store) {
        await scanRepositoryAsync(store: store)
        store.setPublishActionMessage(
          CoreL10n.format("已创建并切换本地工作分支：%@。", branchName),
          status: .success
        )
      } else {
        store.setPublishActionMessage(
          CoreL10n.format("原站点仓库已创建并切换到 %@；当前站点已变化，未覆盖当前界面状态。", branchName),
          status: .warning
        )
      }
    case .failure(let error):
      let prefix = operation.stillMatches(store.activeProfile) ? "创建分支失败" : "原站点创建分支失败"
      store.setPublishActionMessage(
        CoreL10n.format("%@：%@", prefix, error.localizedDescription),
        status: .failure
      )
    }
  }

  @discardableResult
  private func alignPublishTarget(
    profileID: UUID,
    branchName: String,
    store: WorkbenchStore
  ) -> Bool {
    var profiles = store.profiles
    guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
      return false
    }
    profiles[index].branch = branchName
    store.setProfiles(profiles)
    store.save()
    return store.activeProfileID == profileID
  }

  public func updateRepositoryAutoSyncSettings(_ settings: RepositoryAutoSyncSettings, store: WorkbenchStore) {
    invalidateRepositoryAutoSyncRun()
    repositoryAutoSyncSettings = settings
    repositoryAutoSyncState.nextRunAt = settings.isEnabled ? settings.nextRunDate(after: Date()) : nil
    store.save()
  }

  public func recordRemoteRepositoryPublishInAutoSync(_ result: RemoteRepositoryPublishResult) {
    let publishedPaths = Set(result.changedPaths.map { $0.normalizedRelativePath() })
    repositoryAutoSyncState.remoteChangedPaths.removeAll {
      publishedPaths.contains($0.normalizedRelativePath())
    }
    repositoryAutoSyncState.remoteChangedFileCount = repositoryAutoSyncState.remoteChangedPaths.count
    repositoryAutoSyncState.importableRemoteArticleCount = repositoryAutoSyncState.remoteChangedPaths.filter {
      ["md", "markdown", "mdx"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
    }.count
    repositoryAutoSyncState.nonArticleRemoteChangedFileCount = max(
      0,
      repositoryAutoSyncState.remoteChangedFileCount - repositoryAutoSyncState.importableRemoteArticleCount
    )
    repositoryAutoSyncState.lastRemotePublishAt = Date()
    repositoryAutoSyncState.lastRemotePublishProvider = result.provider
    repositoryAutoSyncState.lastRemotePublishMode = result.mode
    repositoryAutoSyncState.lastRemotePublishPaths = result.changedPaths
    let removedCount = publishedPaths.count
    repositoryAutoSyncState.message = "最近线上发布：\(result.changedPaths.count) 个文件；已从远端同步队列移除 \(removedCount) 个同路径项。"
  }

  func remoteFileSnapshot(profile: SiteProfile, repositoryPath: String) -> RepositoryFileSnapshot? {
    repositoryService.remoteFileSnapshot(profile: profile, repositoryPath: repositoryPath)
  }

  @discardableResult
  public func tickRepositoryAutoSync(store: WorkbenchStore, now: Date = Date()) async -> Bool {
    guard repositoryAutoSyncTask == nil else {
      return false
    }
    guard repositoryAutoSyncSettings.isDue(lastRunAt: repositoryAutoSyncState.lastRunAt, now: now) else {
      return false
    }
    return await runRepositoryAutoSync(store: store, now: now)
  }

  @discardableResult
  public func runRepositoryAutoSync(store: WorkbenchStore, now: Date = Date()) async -> Bool {
    if let repositoryAutoSyncTask {
      return await repositoryAutoSyncTask.value
    }
    repositoryAutoSyncGeneration &+= 1
    let generation = repositoryAutoSyncGeneration
    let operation = LocalRepositoryOperationContext(profile: store.activeProfile)
    let task = Task { @MainActor [weak self] in
      guard let self else { return false }
      return await self.performRepositoryAutoSync(
        generation: generation,
        operation: operation,
        store: store,
        now: now
      )
    }
    repositoryAutoSyncTask = task
    let didRun = await task.value
    if repositoryAutoSyncGeneration == generation {
      repositoryAutoSyncTask = nil
    }
    return didRun
  }

  private func performRepositoryAutoSync(
    generation: UInt64,
    operation: LocalRepositoryOperationContext,
    store: WorkbenchStore,
    now: Date
  ) async -> Bool {
    guard repositoryAutoSyncSettings.isEnabled else {
      repositoryAutoSyncState.status = .disabled
      repositoryAutoSyncState.message = CoreL10n.text("自动检查远端未启用。")
      return false
    }
    guard !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty else {
      repositoryAutoSyncState.status = .waitingForRepository
      repositoryAutoSyncState.lastRunAt = now
      repositoryAutoSyncState.nextRunAt = repositoryAutoSyncSettings.nextRunDate(after: now)
      repositoryAutoSyncState.message = CoreL10n.text("自动检查远端等待本地仓库路径。")
      store.save()
      return true
    }
    if repositoryAutoSyncSettings.fetchBeforeScan {
      let profile = store.activeProfile
      let repositoryService = repositoryService
      let fetch = await Task.detached(priority: .utility) {
        repositoryService.fetchUpstream(profile: profile)
      }.value
      guard isCurrentRepositoryAutoSync(generation: generation, operation: operation, store: store) else {
        return false
      }
      repositoryAutoSyncState.lastFetchAt = now
      repositoryAutoSyncState.fetchSucceeded = fetch.status == .succeeded
      repositoryAutoSyncState.fetchMessage = fetch.message
      if fetch.status == .failed {
        repositoryAutoSyncState.status = .fetchFailed
        repositoryAutoSyncState.lastRunAt = now
        repositoryAutoSyncState.nextRunAt = repositoryAutoSyncSettings.nextRunDate(after: now)
        repositoryAutoSyncState.message = CoreL10n.format(
          "自动检查远端 Fetch 失败，已保留上次检查结果：%@",
          fetch.message
        )
        store.save()
        return true
      }
    }
    await scanRepositoryAsync(store: store, autoSyncGeneration: generation)
    guard isCurrentRepositoryAutoSync(generation: generation, operation: operation, store: store) else {
      return false
    }
    repositoryAutoSyncState.status = .scanned
    repositoryAutoSyncState.lastRunAt = now
    repositoryAutoSyncState.nextRunAt = repositoryAutoSyncSettings.nextRunDate(after: now)
    let detectedRemoteFiles = repositoryReport?.remoteChangedFiles ?? []
    let detectedRemoteCount = detectedRemoteFiles.count
    repositoryAutoSyncState.remoteChangedFileCount = detectedRemoteCount
    repositoryAutoSyncState.remoteChangedPaths = detectedRemoteFiles.map(\.displayPath)
    let articleFiles = repositoryReport?.remoteChangedFilesForRole(
      role: .article,
      contentRoot: store.activeProfile.contentRoot,
      assetRoot: store.activeProfile.assetRoot
    ) ?? []
    let importablePaths = articleFiles
      .filter { $0.kind != .deleted }
      .map { $0.displayPath.normalizedRelativePath() }
    repositoryAutoSyncState.importableRemoteArticleCount = importablePaths.count
    repositoryAutoSyncState.nonArticleRemoteChangedFileCount = max(
      0,
      detectedRemoteCount - importablePaths.count
    )

    if repositoryAutoSyncSettings.autoImportRemoteArticles {
      let locallyChangedPaths = Set(
        (repositoryReport?.changedFiles ?? []).map { $0.displayPath.normalizedRelativePath() }
      )
      let candidatePaths = articleFiles
        .filter { ($0.kind == .added || $0.kind == .modified) }
        .map { $0.displayPath.normalizedRelativePath() }
        .filter { !locallyChangedPaths.contains($0) }
      let profile = store.activeProfile
      let repositoryService = repositoryService
      let snapshots = await Task.detached(priority: .utility) {
        candidatePaths.compactMap {
          repositoryService.remoteFileSnapshot(profile: profile, repositoryPath: $0)
        }
      }.value
      guard isCurrentRepositoryAutoSync(generation: generation, operation: operation, store: store) else {
        return false
      }

      let autoImport = store.autoImportRemoteArticleDrafts(
        remoteFiles: articleFiles,
        snapshots: snapshots,
        locallyChangedPaths: locallyChangedPaths
      )
      let resolvedPaths = Set(autoImport.resolvedPaths.map { $0.normalizedRelativePath() })
      repositoryAutoSyncState.remoteChangedPaths.removeAll {
        resolvedPaths.contains($0.normalizedRelativePath())
      }
      repositoryAutoSyncState.remoteChangedFileCount = repositoryAutoSyncState.remoteChangedPaths.count
      let pendingPaths = Set(repositoryAutoSyncState.remoteChangedPaths.map { $0.normalizedRelativePath() })
      repositoryAutoSyncState.importableRemoteArticleCount = articleFiles.filter {
        $0.kind != .deleted && pendingPaths.contains($0.displayPath.normalizedRelativePath())
      }.count
      repositoryAutoSyncState.nonArticleRemoteChangedFileCount = max(
        0,
        repositoryAutoSyncState.remoteChangedFileCount - repositoryAutoSyncState.importableRemoteArticleCount
      )
      repositoryAutoSyncState.lastAutoImportAt = now
      repositoryAutoSyncState.lastAutoImportedArticleCount = autoImport.importedCount
      repositoryAutoSyncState.lastAutoImportConflictCount = autoImport.conflictPaths.count + autoImport.failedPaths.count
      repositoryAutoSyncState.lastAutoImportDeletionCount = autoImport.deletionPaths.count

      if autoImport.pendingReviewCount > 0 {
        repositoryAutoSyncState.message = CoreL10n.format(
          "自动检查远端完成：发现 %d 个变更，已自动导入 %d 篇文章；%d 项保留手动审阅。",
          detectedRemoteCount,
          autoImport.importedCount,
          autoImport.pendingReviewCount
        )
      } else {
        repositoryAutoSyncState.message = CoreL10n.format(
          "自动检查远端完成：发现 %d 个变更，已自动导入 %d 篇文章。",
          detectedRemoteCount,
          autoImport.importedCount
        )
      }
    } else {
      repositoryAutoSyncState.lastAutoImportedArticleCount = 0
      repositoryAutoSyncState.lastAutoImportConflictCount = 0
      repositoryAutoSyncState.lastAutoImportDeletionCount = 0
      repositoryAutoSyncState.message = CoreL10n.format(
        "自动检查远端完成：发现 %d 个远端变更，其中 %d 篇文章可手动导入。",
        detectedRemoteCount,
        importablePaths.count
      )
    }
    store.save()
    return true
  }

  @discardableResult
  public func saveRepositoryAccessToken(_ token: String, store: WorkbenchStore) -> Bool {
    do {
      try repositoryTokenStore.saveRepositoryToken(
        token.trimmedForPublishing,
        for: store.activeProfile
      )
      remoteRepositoryAccessCheck = nil
      repositoryTokenAvailability = try repositoryTokenAvailability(for: store.activeProfile)
      store.setPublishActionMessage(
        CoreL10n.text("仓库访问 Token 已保存到 Keychain。"),
        status: .success
      )
      store.save()
      return true
    } catch {
      store.setPublishActionMessage(
        CoreL10n.format("仓库 Token 保存失败：%@", error.localizedDescription),
        status: .failure
      )
      return false
    }
  }

  public func refreshRepositoryTokenAvailability(store: WorkbenchStore) {
    do {
      repositoryTokenAvailability = try repositoryTokenAvailability(for: store.activeProfile)
    } catch {
      repositoryTokenAvailability = KeychainTokenAvailability(accessFailure: error)
    }
  }

  public func refreshRepositoryTokenAvailability(updatesMessage: Bool, store: WorkbenchStore) {
    refreshRepositoryTokenAvailability(store: store)
    if updatesMessage {
      switch repositoryTokenAvailability.accessState {
      case .available:
        store.setPublishActionMessage(
          CoreL10n.text("仓库 Token 已配置。"),
          status: .success
        )
      case .missing:
        store.setPublishActionMessage(
          CoreL10n.text("仓库 Token 未配置。"),
          status: .warning
        )
      case .accessFailed:
        store.setPublishActionMessage(
          CoreL10n.format(
            "仓库 Token 状态读取失败：%@",
            repositoryTokenAvailability.accessFailureMessage ?? CoreL10n.text("未知错误")
          ),
          status: .failure
        )
      }
    }
  }

  public func deleteRepositoryAccessToken(store: WorkbenchStore) {
    do {
      try repositoryTokenStore.deleteRepositoryToken(for: store.activeProfile)
      remoteRepositoryAccessCheck = nil
      refreshRepositoryTokenAvailability(store: store)
      store.setPublishActionMessage(
        CoreL10n.text("仓库 Token 已删除。"),
        status: .success
      )
      store.save()
    } catch {
      store.setPublishActionMessage(
        CoreL10n.format("仓库 Token 删除失败：%@", error.localizedDescription),
        status: .failure
      )
    }
  }

  @discardableResult
  public func checkRepositoryTokenAccess(store: WorkbenchStore) async -> RemoteRepositoryAccessCheck? {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }
    let profile = store.activeProfile
    guard let operation = beginRemoteRepositoryCheck(profile: profile) else {
      store.setPublishActionMessage(
        CoreL10n.text("已有仓库权限检查或建仓任务正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    defer { finishRemoteRepositoryCheck(operation) }
    do {
      let token = try repositoryAccessToken(for: profile)
      let check = try await remoteRepositoryPublishService.checkAccess(profile: profile, token: token)
      guard remoteRepositoryCheckIsCurrent(operation, store: store) else { return nil }
      remoteRepositoryAccessCheck = check
      repositoryTokenAvailability = try repositoryTokenAvailability(for: profile)
      store.setPublishActionMessage(
        check.message,
        status: check.canWrite ? .success : .warning
      )
      store.save()
      return check
    } catch {
      guard remoteRepositoryCheckIsCurrent(operation, store: store) else { return nil }
      store.setPublishActionMessage(
        CoreL10n.format("仓库权限检查失败：%@", error.localizedDescription),
        status: .failure
      )
      return nil
    }
  }

  public func activeRemoteRepositoryAccessCheck(store: WorkbenchStore) -> RemoteRepositoryAccessCheck? {
    guard let check = remoteRepositoryAccessCheck,
          remoteRepositoryAccessCheck(check, matches: store.activeProfile) else {
      return nil
    }
    return check
  }

  public func hasStaleRemoteRepositoryAccessCheckForActiveProfile(store: WorkbenchStore) -> Bool {
    guard let check = remoteRepositoryAccessCheck else { return false }
    return !remoteRepositoryAccessCheck(check, matches: store.activeProfile)
  }

  private func remoteRepositoryAccessCheck(
    _ check: RemoteRepositoryAccessCheck,
    matches profile: SiteProfile
  ) -> Bool {
    guard check.provider == profile.repositoryProvider,
          check.repositoryName == profile.repositoryDisplayName else {
      return false
    }
    guard let checkedAPIBaseURL = check.apiBaseURL?.nilIfEmpty else {
      return true
    }
    guard let profileAPIBaseURL = try? remoteRepositoryPublishService.apiBaseURL(for: profile) else {
      return false
    }
    return checkedAPIBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      == remoteRepositoryPublishService.normalizedAPIBaseURLString(profileAPIBaseURL)
  }

  private func repositoryAccessToken(for profile: SiteProfile) throws -> String? {
    try repositoryTokenStore.repositoryToken(for: profile)
  }

  private func repositoryTokenAvailability(for profile: SiteProfile) throws -> KeychainTokenAvailability {
    try repositoryTokenStore.repositoryTokenAvailability(for: profile)
  }

  @discardableResult
  public func createRemoteRepositoryForActiveProfile(
    privateRepository: Bool = true,
    store: WorkbenchStore
  ) async -> RemoteRepositoryCreationResult? {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }
    let profile = store.activeProfile
    guard let operation = beginRemoteRepositoryCheck(profile: profile) else {
      store.setPublishActionMessage(
        CoreL10n.text("已有仓库权限检查或建仓任务正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    defer { finishRemoteRepositoryCheck(operation) }
    do {
      let token = try repositoryAccessToken(for: profile)
      let result = try await remoteRepositoryPublishService.createRepository(
        profile: profile,
        token: token,
        privateRepository: privateRepository
      )
      guard remoteRepositoryCheckIsCurrent(operation, store: store) else { return nil }
      remoteRepositoryCreationResult = result
      repositoryTokenAvailability = try repositoryTokenAvailability(for: profile)
      store.setPublishActionMessage(
        CoreL10n.format("%@ 仓库已创建：%@。", result.provider.displayName, result.repositoryName),
        status: .success
      )
      store.save()
      return result
    } catch {
      guard remoteRepositoryCheckIsCurrent(operation, store: store) else { return nil }
      store.setPublishActionMessage(
        CoreL10n.format("远端仓库创建失败：%@", error.localizedDescription),
        status: .failure
      )
      return nil
    }
  }

  private func beginRemoteRepositoryCheck(profile: SiteProfile) -> RemoteRepositoryOperationContext? {
    guard remoteRepositoryCheckContext == nil else { return nil }
    let operation = RemoteRepositoryOperationContext(profile: profile)
    remoteRepositoryCheckContext = operation
    isRemoteRepositoryChecking = true
    return operation
  }

  private func remoteRepositoryCheckIsCurrent(
    _ operation: RemoteRepositoryOperationContext,
    store: WorkbenchStore
  ) -> Bool {
    remoteRepositoryCheckContext == operation && operation.stillMatches(store.activeProfile)
  }

  private func finishRemoteRepositoryCheck(_ operation: RemoteRepositoryOperationContext) {
    guard remoteRepositoryCheckContext == operation else { return }
    remoteRepositoryCheckContext = nil
    isRemoteRepositoryChecking = false
  }
}
