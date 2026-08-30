import Combine
import Foundation
import PublishingGitCore

private struct RepositoryScanSnapshot: Sendable {
  var report: RepositoryScanReport
  var branches: [RepositoryBranch]
  var recentCommits: [RepositoryCommitInfo]
  var releaseHistory: RepositoryReleaseHistorySnapshot
  var mergeConflictSession: RepositoryMergeConflictSession
}

private struct RepositoryLineDiffKey: Hashable {
  let reportRevision: UUID
  let isRemote: Bool
  let fileID: String
}

private enum RepositoryLineDiffCacheValue {
  case resolved(String?)

  var value: String? {
    switch self {
    case .resolved(let value): value
    }
  }
}

@MainActor
public final class RepositoryStore: ObservableObject {
  private static let repositoryLineDiffCacheLimit = 48
  private let repositoryService: LocalRepositoryService
  private let repositoryTokenStore: KeychainTokenStore
  private let remoteRepositoryPublishService: RemoteRepositoryPublishService
  private let repositorySyncCommandBuilder: RepositorySyncCommandBuilder

  @Published public internal(set) var repositoryReport: RepositoryScanReport?
  @Published public internal(set) var repositoryMergeConflictSession:
    RepositoryMergeConflictSession?
  @Published public internal(set) var repositoryScanState: RepositoryScanState
  @Published public internal(set) var localGitPublishResult: LocalGitPublishResult?
  @Published public internal(set) var localRepositoryBranches: [RepositoryBranch]
  @Published public internal(set) var localRepositoryRecentCommits: [RepositoryCommitInfo]
  @Published public internal(set) var localRepositoryReleaseHistory:
    RepositoryReleaseHistorySnapshot
  @Published public internal(set) var repositoryTokenAvailability: KeychainTokenAvailability
  @Published public internal(set) var remoteRepositoryAccessCheck: RemoteRepositoryAccessCheck?
  @Published public internal(set) var remoteRepositoryAccessCheckByProfileID:
    [UUID: RemoteRepositoryAccessCheck]
  @Published public internal(set) var remoteRepositoryCreationResult:
    RemoteRepositoryCreationResult?
  @Published public internal(set) var remoteRepositoryPublishResult: RemoteRepositoryPublishResult?
  @Published public internal(set) var remoteRepositoryPublishProgress:
    RemoteRepositoryPublishProgress?
  @Published public internal(set) var remoteRepositoryRollbackResult:
    RemoteRepositoryRollbackResult?
  @Published public internal(set) var remoteRepositoryReviewWithdrawalResult:
    RemoteRepositoryReviewWithdrawalResult?
  @Published public internal(set) var isRemoteRepositoryChecking: Bool
  @Published public internal(set) var isRemoteRepositoryPublishing: Bool
  @Published public internal(set) var isLocalRepositoryBranchOperationRunning: Bool
  @Published public internal(set) var repositoryAutoSyncSettings: RepositoryAutoSyncSettings {
    didSet {
      guard let profileID = boundAutomationProfileID else { return }
      repositoryAutoSyncSettingsByProfileID[profileID] = repositoryAutoSyncSettings
    }
  }
  @Published public internal(set) var repositoryAutoSyncState: RepositoryAutoSyncState {
    didSet {
      guard let profileID = boundAutomationProfileID else { return }
      repositoryAutoSyncStateByProfileID[profileID] = repositoryAutoSyncState
    }
  }
  @Published public internal(set) var repositoryAutoSyncSettingsByProfileID:
    [UUID: RepositoryAutoSyncSettings]
  @Published public internal(set) var repositoryAutoSyncStateByProfileID:
    [UUID: RepositoryAutoSyncState]
  private var repositoryReportProfileID: UUID?
  private var repositoryMergeConflictProfileID: UUID?
  private var repositoryScanProfileID: UUID?
  private var repositoryScanTask: Task<Void, Never>?
  private var repositoryScanWorkTask: Task<RepositoryScanSnapshot?, Never>?
  private var repositoryScanWorkGeneration: UInt64 = 0
  private var repositoryScanGeneration: UInt64 = 0
  // A new scan is a new Git-state revision.  Never reuse a patch across it:
  // the same path can refer to different staged, working-tree, or upstream
  // content after a refresh.
  private var repositoryLineDiffReportRevision = UUID()
  private var repositoryLineDiffCache: [RepositoryLineDiffKey: RepositoryLineDiffCacheValue] = [:]
  private var repositoryLineDiffTasks: [RepositoryLineDiffKey: Task<String?, Never>] = [:]
  private var repositoryAutoSyncTask: Task<Bool, Never>?
  private var repositoryAutoSyncGeneration: UInt64 = 0
  private var repositoryAutoSyncBackgroundGenerationByProfileID: [UUID: UInt64] = [:]
  private var remoteRepositoryCheckContext: RemoteRepositoryOperationContext?
  private var boundAutomationProfileID: UUID?
  #if DEBUG
    // Test-only barrier for exercising stale-result invalidation without a real Git race.
    var backgroundRepositoryAutoSyncTestHook: (() async -> Void)?
    // Test-only barrier for proving that remote article imports validate the
    // active profile after detached snapshot work has completed.
    var remoteFileSnapshotTestHook: (@Sendable () async -> Void)?
    var remoteFileSnapshotTestOverride: (@Sendable () async -> RepositoryFileSnapshot?)?
  #endif

  init(
    repositoryReport: RepositoryScanReport? = nil,
    repositoryMergeConflictSession: RepositoryMergeConflictSession? = nil,
    repositoryScanState: RepositoryScanState = .idle,
    localGitPublishResult: LocalGitPublishResult? = nil,
    localRepositoryBranches: [RepositoryBranch] = [],
    localRepositoryRecentCommits: [RepositoryCommitInfo] = [],
    localRepositoryReleaseHistory: RepositoryReleaseHistorySnapshot = .init(),
    repositoryTokenAvailability: KeychainTokenAvailability = KeychainTokenAvailability(
      hasToken: false),
    remoteRepositoryAccessCheck: RemoteRepositoryAccessCheck? = nil,
    remoteRepositoryAccessCheckByProfileID: [UUID: RemoteRepositoryAccessCheck] = [:],
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
    repositoryAutoSyncSettingsByProfileID: [UUID: RepositoryAutoSyncSettings] = [:],
    repositoryAutoSyncStateByProfileID: [UUID: RepositoryAutoSyncState] = [:],
    activeProfileID: UUID? = nil,
    repositoryService: LocalRepositoryService = LocalRepositoryService(),
    repositoryTokenStore: KeychainTokenStore = KeychainTokenStore(
      service: KeychainCredentialServices.repository),
    remoteRepositoryPublishService: RemoteRepositoryPublishService =
      RemoteRepositoryPublishService(),
    repositorySyncCommandBuilder: RepositorySyncCommandBuilder = RepositorySyncCommandBuilder()
  ) {
    self.repositoryService = repositoryService
    self.repositoryTokenStore = repositoryTokenStore
    self.remoteRepositoryPublishService = remoteRepositoryPublishService
    self.repositorySyncCommandBuilder = repositorySyncCommandBuilder
    self.repositoryReport = repositoryReport
    self.repositoryMergeConflictSession = repositoryMergeConflictSession
    self.repositoryScanState = repositoryScanState
    self.localGitPublishResult = localGitPublishResult
    self.localRepositoryBranches = localRepositoryBranches
    self.localRepositoryRecentCommits = localRepositoryRecentCommits
    self.localRepositoryReleaseHistory = localRepositoryReleaseHistory
    self.repositoryTokenAvailability = repositoryTokenAvailability
    self.remoteRepositoryAccessCheckByProfileID = remoteRepositoryAccessCheckByProfileID
    self.remoteRepositoryAccessCheck =
      activeProfileID.flatMap {
        remoteRepositoryAccessCheckByProfileID[$0]
      } ?? remoteRepositoryAccessCheck
    self.remoteRepositoryCreationResult = remoteRepositoryCreationResult
    self.remoteRepositoryPublishResult = remoteRepositoryPublishResult
    self.remoteRepositoryPublishProgress = remoteRepositoryPublishProgress
    self.remoteRepositoryRollbackResult = remoteRepositoryRollbackResult
    self.remoteRepositoryReviewWithdrawalResult = remoteRepositoryReviewWithdrawalResult
    self.isRemoteRepositoryChecking = isRemoteRepositoryChecking
    self.isRemoteRepositoryPublishing = isRemoteRepositoryPublishing
    self.isLocalRepositoryBranchOperationRunning = isLocalRepositoryBranchOperationRunning
    self.repositoryAutoSyncSettingsByProfileID = repositoryAutoSyncSettingsByProfileID
    self.repositoryAutoSyncStateByProfileID = repositoryAutoSyncStateByProfileID
    self.repositoryAutoSyncSettings =
      activeProfileID.flatMap {
        repositoryAutoSyncSettingsByProfileID[$0]
      } ?? repositoryAutoSyncSettings
    self.repositoryAutoSyncState =
      activeProfileID.flatMap {
        repositoryAutoSyncStateByProfileID[$0]
      } ?? repositoryAutoSyncState
    self.boundAutomationProfileID = activeProfileID
    repositoryReportProfileID = nil
    repositoryMergeConflictProfileID = repositoryMergeConflictSession == nil ? nil : activeProfileID
    repositoryScanProfileID = nil
  }

  public func repositoryReport(for profile: SiteProfile, store: WorkbenchStore)
    -> RepositoryScanReport?
  {
    guard let repositoryReport else { return nil }
    if let repositoryReportProfileID, repositoryReportProfileID != profile.id {
      return nil
    }
    guard let configuredIdentity = LocalRepositoryIdentity(profile: profile) else {
      return repositoryReportProfileID == profile.id ? repositoryReport : nil
    }
    return LocalRepositoryIdentity(rootPath: repositoryReport.rootPath) == configuredIdentity
      ? repositoryReport
      : nil
  }

  public func repositoryMergeConflictSession(
    for profile: SiteProfile,
    store: WorkbenchStore
  ) -> RepositoryMergeConflictSession? {
    guard let repositoryMergeConflictSession,
      let repositoryMergeConflictProfileID,
      repositoryMergeConflictProfileID == profile.id
    else {
      return nil
    }
    guard let configuredIdentity = LocalRepositoryIdentity(profile: profile) else {
      return nil
    }
    return LocalRepositoryIdentity(rootPath: repositoryMergeConflictSession.rootPath)
      == configuredIdentity
      ? repositoryMergeConflictSession
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
    let profile = store.activeProfile
    repositoryScanProfileID = profile.id
    repositoryScanState = .scanning()
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
      let mergeConflictSession = repositoryService.mergeConflictSession(profile: profile)
      guard !Task.isCancelled else { return nil }
      let branches = repositoryService.localBranches(profile: profile)
      guard !Task.isCancelled else { return nil }
      let releaseHistory = repositoryService.releaseHistory(profile: profile)
      guard !Task.isCancelled else { return nil }
      return RepositoryScanSnapshot(
        report: report,
        branches: branches,
        recentCommits: releaseHistory.commits,
        releaseHistory: releaseHistory,
        mergeConflictSession: mergeConflictSession
      )
    }
    repositoryScanWorkTask = scanWork
    let scanTask = Task { @MainActor [weak self] in
      let snapshot = await scanWork.value
      guard let self else { return }
      self.finishRepositoryScanWorkIfCurrent(generation: scanWorkGeneration)
      guard let snapshot else { return }
      guard
        self.isCurrentRepositoryScan(
          generation: scanGeneration,
          operation: operation,
          autoSyncGeneration: autoSyncGeneration,
          store: store
        )
      else {
        self.finishStaleRepositoryScanIfNeeded(
          generation: scanGeneration, operation: operation, store: store)
        return
      }
      replaceRepositoryReport(snapshot.report, profileID: operation.profileID)
      repositoryReportProfileID = operation.profileID
      repositoryMergeConflictSession = snapshot.mergeConflictSession
      repositoryMergeConflictProfileID = operation.profileID
      localRepositoryBranches = snapshot.branches
      localRepositoryRecentCommits = snapshot.recentCommits
      localRepositoryReleaseHistory = snapshot.releaseHistory
      repositoryScanState = .finished(report: snapshot.report)
      store.publishingStore.removeDraftPublishPreviewSnapshots(
        forProfileID: operation.profileID
      )
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
    return isCurrentRepositoryAutoSync(
      generation: autoSyncGeneration, operation: operation, store: store)
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

  func replaceRepositoryReport(_ report: RepositoryScanReport?, profileID: UUID?) {
    invalidateRepositoryLineDiffs()
    repositoryReportProfileID = report == nil ? nil : profileID
    if report == nil {
      repositoryMergeConflictSession = nil
      repositoryMergeConflictProfileID = nil
    }
    repositoryReport = report
  }

  /// Loads a single file patch on demand.  Equal requests for the current
  /// report share one detached Git process, and both successful and empty
  /// results are cached until the next scan/report replacement.
  func loadLineDiff(
    for file: RepositoryChangedFile,
    isRemote: Bool,
    profile: SiteProfile,
    store: WorkbenchStore
  ) async -> String? {
    guard let report = repositoryReport(for: profile, store: store) else { return nil }
    let files = isRemote ? report.remoteChangedFiles : report.changedFiles
    // A completed request republishes the report with `lineDiff` filled in.
    // Callers may still hold the earlier summary value, so match Git's stable
    // file identity rather than value equality (which includes `lineDiff`).
    guard let currentFile = files.first(where: { $0.id == file.id }) else { return nil }
    if let lineDiff = currentFile.lineDiff {
      return lineDiff
    }

    let key = RepositoryLineDiffKey(
      reportRevision: repositoryLineDiffReportRevision,
      isRemote: isRemote,
      fileID: currentFile.id
    )
    if let cached = repositoryLineDiffCache[key] {
      return cached.value
    }

    let task: Task<String?, Never>
    if let inFlight = repositoryLineDiffTasks[key] {
      task = inFlight
    } else {
      let service = repositoryService
      let upstreamName = report.branchStatus?.upstreamName
      task = Task.detached(priority: .utility) {
        profile.withLocalRepositoryRootAccess { rootURL in
          if isRemote {
            guard let upstreamName else { return nil }
            return service.diffForRemoteChangedFile(
              currentFile,
              upstreamName: upstreamName,
              rootURL: rootURL
            )
          }
          return service.diffForChangedFile(currentFile, rootURL: rootURL)
        } ?? nil
      }
      repositoryLineDiffTasks[key] = task
    }

    let lineDiff = await task.value
    guard key.reportRevision == repositoryLineDiffReportRevision else { return nil }
    repositoryLineDiffTasks.removeValue(forKey: key)
    if repositoryLineDiffCache.count >= Self.repositoryLineDiffCacheLimit {
      repositoryLineDiffCache.removeAll(keepingCapacity: true)
    }
    repositoryLineDiffCache[key] = .resolved(lineDiff)
    applyLineDiff(lineDiff, to: currentFile, isRemote: isRemote)
    return lineDiff
  }

  private func invalidateRepositoryLineDiffs() {
    repositoryLineDiffReportRevision = UUID()
    for task in repositoryLineDiffTasks.values {
      task.cancel()
    }
    repositoryLineDiffTasks.removeAll(keepingCapacity: true)
    repositoryLineDiffCache.removeAll(keepingCapacity: true)
  }

  private func applyLineDiff(
    _ lineDiff: String?,
    to file: RepositoryChangedFile,
    isRemote: Bool
  ) {
    guard var report = repositoryReport else { return }
    if isRemote {
      guard let index = report.remoteChangedFiles.firstIndex(where: { $0.id == file.id }) else {
        return
      }
      report.remoteChangedFiles[index].lineDiff = lineDiff
    } else {
      guard let index = report.changedFiles.firstIndex(where: { $0.id == file.id }) else { return }
      report.changedFiles[index].lineDiff = lineDiff
    }
    repositoryReport = report
  }

  func repositoryScanState(for profileID: UUID) -> RepositoryScanState {
    guard let repositoryScanProfileID else { return repositoryScanState }
    return repositoryScanProfileID == profileID ? repositoryScanState : .idle
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

  private func beginBackgroundRepositoryAutoSyncRun(for profileID: UUID) -> UInt64 {
    repositoryAutoSyncBackgroundGenerationByProfileID[profileID, default: 0] &+= 1
    return repositoryAutoSyncBackgroundGenerationByProfileID[profileID] ?? 0
  }

  private func isCurrentBackgroundRepositoryAutoSync(
    profileID: UUID,
    generation: UInt64,
    settings: RepositoryAutoSyncSettings,
    frozenProfile: SiteProfile,
    store: WorkbenchStore
  ) -> Bool {
    repositoryAutoSyncBackgroundGenerationByProfileID[profileID] == generation
      && repositoryAutoSyncSettings(for: profileID) == settings
      && store.profiles.first(where: { $0.id == profileID }) == frozenProfile
  }

  public func rememberRepositoryRootAsync(_ url: URL, store: WorkbenchStore) async {
    var profile = store.activeProfile
    _ = profile.rememberLocalRepositoryRoot(url)
    store.updateActiveProfile(profile)
    await scanRepositoryAsync(store: store)
    store.save()
  }

  public func repositorySyncCommandPlan(store: WorkbenchStore) -> RepositorySyncCommandPlan? {
    repositorySyncCommandBuilder.plan(
      report: repositoryReport(for: store.activeProfile, store: store),
      profile: store.activeProfile
    )
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
      let mode = repositoryAutoSyncState.lastRemotePublishMode
    {
      lines.append("\n## 最近线上写入\n")
      lines.append("- 平台：\(provider.displayName)")
      lines.append("- 模式：\(mode.displayName)")
      lines.append(contentsOf: repositoryAutoSyncState.lastRemotePublishPaths.map { "- \($0)" })
    }
    return lines.joined(separator: "\n")
  }

  public func applyDetectedRepositoryRemote(store: WorkbenchStore) {
    guard
      let currentReport = repositoryReport(for: store.activeProfile, store: store),
      let remote = currentReport.originRemote
    else {
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
    if let detectedBranch = currentReport.branchStatus?.branchName?.nilIfEmpty {
      profile.branch = detectedBranch
    }
    store.updateActiveProfile(profile)
    store.setPublishActionMessage(
      CoreL10n.format("已使用 %@ 更新 PR/MR 配置。", remote.displayName),
      status: .success
    )
    store.save()
  }

  /// Fills only the missing repository identity fields from the active
  /// profile's validated scan report. An explicit, complete configuration is
  /// never replaced implicitly by a local Git origin.
  @discardableResult
  private func applyDetectedRepositoryRemoteIfNeeded(store: WorkbenchStore) -> SiteProfile {
    let profile = store.activeProfile
    let owner = profile.repoOwner.trimmedForPublishing
    let name = profile.repoName.trimmedForPublishing
    guard owner.isEmpty || name.isEmpty else { return profile }
    guard
      let report = repositoryReport(for: profile, store: store),
      let remote = report.originRemote
    else {
      return profile
    }
    guard
      (owner.isEmpty || owner == remote.owner.trimmedForPublishing),
      (name.isEmpty || name == remote.name.trimmedForPublishing)
    else {
      // A partially entered target that disagrees with origin is ambiguous;
      // leave it untouched and let the remote service return its structured
      // configuration result rather than probing a guessed repository.
      return profile
    }

    var updated = profile
    // A missing owner/name means the configured remote is incomplete. Use the
    // detected provider and endpoint as a pair so a GitLab origin cannot be
    // checked via the default GitHub client. Preserve any matching identity
    // component to avoid silently changing a user's partially entered target.
    updated.repositoryProvider = remote.provider
    updated.repositoryBaseURL = remote.repositoryBaseURL
    if owner.isEmpty {
      updated.repoOwner = remote.owner
    }
    if name.isEmpty {
      updated.repoName = remote.name
    }
    if let branch = report.branchStatus?.branchName?.nilIfEmpty {
      updated.branch = branch
    }

    guard updated != profile else { return profile }
    store.updateActiveProfile(updated)
    store.save()
    return updated
  }

  public func setRepositoryProvider(_ provider: RepositoryProvider, store: WorkbenchStore) {
    var profile = store.activeProfile
    let currentDefault = profile.repositoryProvider.defaultBaseURL
    let shouldUseProviderDefault =
      profile.repositoryBaseURL.trimmedForPublishing.isEmpty
      || profile.repositoryBaseURL == currentDefault
    profile.repositoryProvider = provider
    if shouldUseProviderDefault {
      profile.repositoryBaseURL = provider.defaultBaseURL
    }
    store.updateActiveProfile(profile)
    store.save()
  }

  public func switchActiveProfileRepositoryBranch(to branchName: String, store: WorkbenchStore)
    async
  {
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
        _ = await store.tickRepositoryAndDeploymentPolling(now: Date())
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
        _ = await store.tickRepositoryAndDeploymentPolling(now: Date())
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

  public func updateRepositoryAutoSyncSettings(
    _ settings: RepositoryAutoSyncSettings, store: WorkbenchStore
  ) {
    updateRepositoryAutoSyncSettings(settings, for: store.activeProfileID, store: store)
  }

  public func updateRepositoryAutoSyncSettings(
    _ settings: RepositoryAutoSyncSettings,
    for profileID: UUID,
    store: WorkbenchStore
  ) {
    guard store.profiles.contains(where: { $0.id == profileID }) else { return }
    invalidateRepositoryAutoSyncRun()
    repositoryAutoSyncBackgroundGenerationByProfileID[profileID, default: 0] &+= 1
    let normalized = RepositoryAutoSyncSettings(
      isEnabled: settings.isEnabled,
      intervalMinutes: settings.normalizedIntervalMinutes,
      fetchBeforeScan: settings.fetchBeforeScan,
      autoImportRemoteArticles: settings.autoImportRemoteArticles
    )
    repositoryAutoSyncSettingsByProfileID[profileID] = normalized
    var state = repositoryAutoSyncStateByProfileID[profileID] ?? .idle
    state.nextRunAt = normalized.isEnabled ? normalized.nextRunDate(after: Date()) : nil
    if !normalized.isEnabled {
      state.status = .disabled
      state.message = CoreL10n.text("自动检查远端未启用。")
    }
    repositoryAutoSyncStateByProfileID[profileID] = state
    if profileID == boundAutomationProfileID {
      repositoryAutoSyncSettings = normalized
      repositoryAutoSyncState = state
    }
    store.save()
  }

  public func repositoryAutoSyncSettings(for profileID: UUID) -> RepositoryAutoSyncSettings {
    repositoryAutoSyncSettingsByProfileID[profileID] ?? .default
  }

  public func repositoryAutoSyncState(for profileID: UUID) -> RepositoryAutoSyncState {
    repositoryAutoSyncStateByProfileID[profileID] ?? .idle
  }

  /// Rebinds the compatibility scalar view when the publishing UI changes
  /// sites. The previous scalar values are flushed before loading the target
  /// site's map entries, so a profile switch cannot move runtime state across
  /// sites.
  func setActiveProfile(_ profileID: UUID, validProfileIDs: Set<UUID>) {
    if boundAutomationProfileID != profileID {
      invalidateRepositoryLineDiffs()
    }
    if let boundAutomationProfileID {
      repositoryAutoSyncSettingsByProfileID[boundAutomationProfileID] = repositoryAutoSyncSettings
      repositoryAutoSyncStateByProfileID[boundAutomationProfileID] = repositoryAutoSyncState
      if let remoteRepositoryAccessCheck {
        remoteRepositoryAccessCheckByProfileID[boundAutomationProfileID] =
          remoteRepositoryAccessCheck
      } else {
        remoteRepositoryAccessCheckByProfileID.removeValue(forKey: boundAutomationProfileID)
      }
    }
    repositoryAutoSyncSettingsByProfileID = repositoryAutoSyncSettingsByProfileID.filter {
      validProfileIDs.contains($0.key)
    }
    repositoryAutoSyncStateByProfileID = repositoryAutoSyncStateByProfileID.filter {
      validProfileIDs.contains($0.key)
    }
    repositoryAutoSyncBackgroundGenerationByProfileID =
      repositoryAutoSyncBackgroundGenerationByProfileID.filter {
        validProfileIDs.contains($0.key)
      }
    remoteRepositoryAccessCheckByProfileID = remoteRepositoryAccessCheckByProfileID.filter {
      validProfileIDs.contains($0.key)
    }
    for profileID in validProfileIDs {
      repositoryAutoSyncSettingsByProfileID[profileID] =
        repositoryAutoSyncSettingsByProfileID[profileID] ?? .default
      repositoryAutoSyncStateByProfileID[profileID] =
        repositoryAutoSyncStateByProfileID[profileID] ?? .idle
    }
    boundAutomationProfileID = profileID
    repositoryAutoSyncSettings = repositoryAutoSyncSettingsByProfileID[profileID] ?? .default
    repositoryAutoSyncState = repositoryAutoSyncStateByProfileID[profileID] ?? .idle
    remoteRepositoryAccessCheck = remoteRepositoryAccessCheckByProfileID[profileID]
  }

  public func recordRemoteRepositoryPublishInAutoSync(_ result: RemoteRepositoryPublishResult) {
    guard let profileID = boundAutomationProfileID else { return }
    recordRemoteRepositoryPublishInAutoSync(result, for: profileID)
  }

  public func recordRemoteRepositoryPublishInAutoSync(
    _ result: RemoteRepositoryPublishResult,
    for profileID: UUID
  ) {
    var state = repositoryAutoSyncState(for: profileID)
    let publishedPaths = Set(result.changedPaths.map { $0.normalizedRelativePath() })
    state.remoteChangedPaths.removeAll {
      publishedPaths.contains($0.normalizedRelativePath())
    }
    state.remoteChangedFileCount = state.remoteChangedPaths.count
    state.importableRemoteArticleCount =
      state.remoteChangedPaths.filter {
        ["md", "markdown", "mdx"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
      }.count
    state.nonArticleRemoteChangedFileCount = max(
      0,
      state.remoteChangedFileCount - state.importableRemoteArticleCount
    )
    state.lastRemotePublishAt = Date()
    state.lastRemotePublishProvider = result.provider
    state.lastRemotePublishMode = result.mode
    state.lastRemotePublishPaths = result.changedPaths
    let removedCount = publishedPaths.count
    state.message = "最近线上发布：\(result.changedPaths.count) 个文件；已从远端同步队列移除 \(removedCount) 个同路径项。"
    setRepositoryAutoSyncState(state, for: profileID)
  }

  func remoteFileSnapshot(profile: SiteProfile, repositoryPath: String) -> RepositoryFileSnapshot? {
    repositoryService.remoteFileSnapshot(profile: profile, repositoryPath: repositoryPath)
  }

  public func resolveRepositoryMergeConflict(
    repositoryPath: String,
    finalContent: String,
    store: WorkbenchStore
  ) async throws {
    let profile = store.activeProfile
    let operation = LocalRepositoryOperationContext(profile: profile)
    let repositoryService = repositoryService
    let outcome = await Task.detached(priority: .userInitiated) {
      do {
        try repositoryService.resolveMergeConflict(
          profile: profile,
          repositoryPath: repositoryPath,
          finalContent: finalContent
        )
        return Result<Void, RepositoryMergeConflictError>.success(())
      } catch let error as RepositoryMergeConflictError {
        return Result<Void, RepositoryMergeConflictError>.failure(error)
      } catch {
        return Result<Void, RepositoryMergeConflictError>.failure(
          .writeFailed(error.localizedDescription)
        )
      }
    }.value

    if case let .failure(error) = outcome {
      throw error
    }
    guard operation.stillMatches(store.activeProfile) else {
      throw RepositoryMergeConflictError.repositoryChanged
    }
    await scanRepositoryAsync(store: store)
  }

  /// Reads one upstream article snapshot away from the main actor. The
  /// profile and repository service are value/sendable captures; only the
  /// result is returned to the actor for parsing and draft mutation.
  func remoteFileSnapshotAsync(
    profile: SiteProfile,
    repositoryPath: String
  ) async -> RepositoryFileSnapshot? {
    let repositoryService = repositoryService
    #if DEBUG
      let testHook = remoteFileSnapshotTestHook
      let testOverride = remoteFileSnapshotTestOverride
    #endif
    let work: Task<RepositoryFileSnapshot?, Never> = Task.detached(priority: .utility) {
      #if DEBUG
        guard !Task.isCancelled else { return nil }
        if let testHook {
          await testHook()
        }
        if let testOverride {
          return await testOverride()
        }
      #endif
      guard !Task.isCancelled else { return nil }
      return repositoryService.remoteFileSnapshot(
        profile: profile,
        repositoryPath: repositoryPath
      )
    }
    return await withTaskCancellationHandler(
      operation: {
        await work.value
      },
      onCancel: {
        work.cancel()
      })
  }

  /// Reads a frozen, already-normalized set of upstream article snapshots
  /// away from the main actor. The caller owns path filtering and ordering so
  /// the returned snapshots can be merged against the exact operation input.
  func remoteFileSnapshotsAsync(
    profile: SiteProfile,
    repositoryPaths: [String]
  ) async -> [RepositoryFileSnapshot] {
    let repositoryService = repositoryService
    #if DEBUG
      let testHook = remoteFileSnapshotTestHook
    #endif
    let work: Task<[RepositoryFileSnapshot], Never> = Task.detached(priority: .utility) {
      #if DEBUG
        guard !Task.isCancelled else { return [] }
        if let testHook {
          await testHook()
        }
      #endif
      guard !Task.isCancelled else { return [] }
      return repositoryService.remoteFileSnapshots(
        profile: profile,
        repositoryPaths: repositoryPaths,
        cancellationCheck: { Task.isCancelled }
      )
    }
    return await withTaskCancellationHandler(
      operation: {
        await work.value
      },
      onCancel: {
        work.cancel()
      })
  }

  @discardableResult
  public func tickRepositoryAutoSync(store: WorkbenchStore, now: Date = Date()) async -> Bool {
    await tickRepositoryAutoSync(for: store.activeProfileID, store: store, now: now)
  }

  @discardableResult
  public func tickRepositoryAutoSync(
    for profileID: UUID,
    store: WorkbenchStore,
    now: Date = Date()
  ) async -> Bool {
    guard repositoryAutoSyncTask == nil else {
      return false
    }
    let settings = repositoryAutoSyncSettings(for: profileID)
    let state = repositoryAutoSyncState(for: profileID)
    guard settings.isDue(lastRunAt: state.lastRunAt, now: now) else {
      return false
    }
    return await runRepositoryAutoSync(for: profileID, store: store, now: now)
  }

  @discardableResult
  public func runRepositoryAutoSync(store: WorkbenchStore, now: Date = Date()) async -> Bool {
    await runRepositoryAutoSync(for: store.activeProfileID, store: store, now: now)
  }

  @discardableResult
  public func runRepositoryAutoSync(
    for profileID: UUID,
    store: WorkbenchStore,
    now: Date = Date()
  ) async -> Bool {
    guard profileID == store.activeProfileID else {
      return await runBackgroundRepositoryAutoSync(for: profileID, store: store, now: now)
    }
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

  /// Performs the non-importing portion of a repository check for a site that
  /// is not currently selected. It freezes the profile before leaving the
  /// actor and only writes the explicit profile's map entry. Remote article
  /// import intentionally remains a foreground operation because its draft
  /// mutation pipeline is active-profile bound.
  private func runBackgroundRepositoryAutoSync(
    for profileID: UUID,
    store: WorkbenchStore,
    now: Date
  ) async -> Bool {
    guard let profile = store.profiles.first(where: { $0.id == profileID }) else {
      return false
    }
    let settings = repositoryAutoSyncSettings(for: profileID)
    guard settings.isEnabled else {
      setRepositoryAutoSyncState(
        RepositoryAutoSyncState(
          status: .disabled,
          message: CoreL10n.text("自动检查远端未启用。")
        ),
        for: profileID
      )
      return false
    }
    let runGeneration = beginBackgroundRepositoryAutoSyncRun(for: profileID)
    #if DEBUG
      if let testHook = backgroundRepositoryAutoSyncTestHook {
        await testHook()
      }
    #endif
    guard
      isCurrentBackgroundRepositoryAutoSync(
        profileID: profileID,
        generation: runGeneration,
        settings: settings,
        frozenProfile: profile,
        store: store
      )
    else {
      return false
    }
    guard !profile.localRepositoryRootPath.trimmedForPublishing.isEmpty else {
      var state = repositoryAutoSyncState(for: profileID)
      state.status = .waitingForRepository
      state.lastRunAt = now
      state.nextRunAt = settings.nextRunDate(after: now)
      state.message = backgroundRepositoryAutoSyncMessage(
        CoreL10n.text("自动检查远端等待本地仓库路径。"),
        settings: settings
      )
      setRepositoryAutoSyncState(state, for: profileID)
      store.save()
      return true
    }

    if settings.fetchBeforeScan {
      let repositoryService = repositoryService
      let fetch = await Task.detached(priority: .utility) {
        repositoryService.fetchUpstream(profile: profile)
      }.value
      guard
        isCurrentBackgroundRepositoryAutoSync(
          profileID: profileID,
          generation: runGeneration,
          settings: settings,
          frozenProfile: profile,
          store: store
        )
      else {
        return false
      }
      var state = repositoryAutoSyncState(for: profileID)
      state.lastFetchAt = now
      state.fetchSucceeded = fetch.status == .succeeded
      state.fetchMessage = fetch.message
      if fetch.status == .failed {
        state.status = .fetchFailed
        state.lastRunAt = now
        state.nextRunAt = settings.nextRunDate(after: now)
        state.message = backgroundRepositoryAutoSyncMessage(
          CoreL10n.format(
            "自动检查远端 Fetch 失败，已保留上次检查结果：%@",
            fetch.message
          ),
          settings: settings
        )
        setRepositoryAutoSyncState(state, for: profileID)
        store.save()
        return true
      }
      setRepositoryAutoSyncState(state, for: profileID)
    }

    let repositoryService = repositoryService
    let report = await Task.detached(priority: .utility) {
      repositoryService.scan(
        profile: profile,
        cancellationCheck: {
          withUnsafeCurrentTask { $0?.isCancelled == true }
        }
      )
    }.value
    guard
      isCurrentBackgroundRepositoryAutoSync(
        profileID: profileID,
        generation: runGeneration,
        settings: settings,
        frozenProfile: profile,
        store: store
      )
    else {
      return false
    }
    var state = repositoryAutoSyncState(for: profileID)
    let detectedRemoteFiles = report.remoteChangedFiles
    let detectedRemoteCount = detectedRemoteFiles.count
    let articleFiles = report.remoteChangedFilesForRole(
      role: .article,
      contentRoot: profile.contentRoot,
      assetRoot: profile.assetRoot
    )
    let importablePaths =
      articleFiles
      .filter { $0.kind != .deleted }
      .map { $0.displayPath.normalizedRelativePath() }
    state.status = .scanned
    state.lastRunAt = now
    state.nextRunAt = settings.nextRunDate(after: now)
    state.remoteChangedFileCount = detectedRemoteCount
    state.remoteChangedPaths = detectedRemoteFiles.map(\.displayPath)
    state.importableRemoteArticleCount = importablePaths.count
    state.nonArticleRemoteChangedFileCount = max(
      0,
      detectedRemoteCount - importablePaths.count
    )
    state.lastAutoImportedArticleCount = 0
    state.lastAutoImportConflictCount = 0
    state.lastAutoImportDeletionCount = 0
    state.message = backgroundRepositoryAutoSyncMessage(
      CoreL10n.format(
        "自动检查远端完成：发现 %d 个远端变更，其中 %d 个文章候选路径可手动尝试导入（导入时会校验内容和 slug）。",
        detectedRemoteCount,
        importablePaths.count
      ),
      settings: settings
    )
    setRepositoryAutoSyncState(state, for: profileID)
    store.save()
    return true
  }

  /// A non-active profile cannot safely enter the foreground draft importer:
  /// that pipeline intentionally guards against mutating the active editor.
  /// Make that deferred/manual path explicit whenever the profile requested
  /// automatic article import.
  private func backgroundRepositoryAutoSyncMessage(
    _ scanMessage: String,
    settings: RepositoryAutoSyncSettings
  ) -> String {
    guard settings.autoImportRemoteArticles else {
      return scanMessage
    }
    return [
      scanMessage,
      CoreL10n.text("该站点未处于前台，已跳过自动导入；切换到该站点后可手动处理。")
    ].joined(separator: " ")
  }

  private func setRepositoryAutoSyncState(
    _ state: RepositoryAutoSyncState,
    for profileID: UUID
  ) {
    repositoryAutoSyncStateByProfileID[profileID] = state
    if profileID == boundAutomationProfileID {
      repositoryAutoSyncState = state
    }
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
      guard isCurrentRepositoryAutoSync(generation: generation, operation: operation, store: store)
      else {
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
    guard isCurrentRepositoryAutoSync(generation: generation, operation: operation, store: store)
    else {
      return false
    }
    repositoryAutoSyncState.status = .scanned
    repositoryAutoSyncState.lastRunAt = now
    repositoryAutoSyncState.nextRunAt = repositoryAutoSyncSettings.nextRunDate(after: now)
    let currentReport = repositoryReport(for: store.activeProfile, store: store)
    let detectedRemoteFiles = currentReport?.remoteChangedFiles ?? []
    let detectedRemoteCount = detectedRemoteFiles.count
    repositoryAutoSyncState.remoteChangedFileCount = detectedRemoteCount
    repositoryAutoSyncState.remoteChangedPaths = detectedRemoteFiles.map(\.displayPath)
    let articleFiles =
      currentReport?.remoteChangedFilesForRole(
        role: .article,
        contentRoot: store.activeProfile.contentRoot,
        assetRoot: store.activeProfile.assetRoot
      ) ?? []
    let importablePaths =
      articleFiles
      .filter { $0.kind != .deleted }
      .map { $0.displayPath.normalizedRelativePath() }
    repositoryAutoSyncState.importableRemoteArticleCount = importablePaths.count
    repositoryAutoSyncState.nonArticleRemoteChangedFileCount = max(
      0,
      detectedRemoteCount - importablePaths.count
    )

    if repositoryAutoSyncSettings.autoImportRemoteArticles {
      let locallyChangedPaths = Set(
        (currentReport?.changedFiles ?? []).map { $0.displayPath.normalizedRelativePath() }
      )
      let candidatePaths =
        articleFiles
        .filter { ($0.kind == .added || $0.kind == .modified) }
        .map { $0.displayPath.normalizedRelativePath() }
        .filter { !locallyChangedPaths.contains($0) }
      let profile = store.activeProfile
      let snapshots = await remoteFileSnapshotsAsync(
        profile: profile,
        repositoryPaths: candidatePaths
      )
      guard isCurrentRepositoryAutoSync(generation: generation, operation: operation, store: store)
      else {
        return false
      }

      let autoImport = store.autoImportRemoteArticleDrafts(
        remoteFiles: articleFiles,
        snapshots: snapshots,
        locallyChangedPaths: locallyChangedPaths,
        profileID: operation.profileID
      )
      let resolvedPaths = Set(autoImport.resolvedPaths.map { $0.normalizedRelativePath() })
      repositoryAutoSyncState.remoteChangedPaths.removeAll {
        resolvedPaths.contains($0.normalizedRelativePath())
      }
      repositoryAutoSyncState.remoteChangedFileCount =
        repositoryAutoSyncState.remoteChangedPaths.count
      let pendingPaths = Set(
        repositoryAutoSyncState.remoteChangedPaths.map { $0.normalizedRelativePath() })
      repositoryAutoSyncState.importableRemoteArticleCount =
        articleFiles.filter {
          $0.kind != .deleted && pendingPaths.contains($0.displayPath.normalizedRelativePath())
        }.count
      repositoryAutoSyncState.nonArticleRemoteChangedFileCount = max(
        0,
        repositoryAutoSyncState.remoteChangedFileCount
          - repositoryAutoSyncState.importableRemoteArticleCount
      )
      repositoryAutoSyncState.lastAutoImportAt = now
      repositoryAutoSyncState.lastAutoImportedArticleCount = autoImport.importedCount
      repositoryAutoSyncState.lastAutoImportConflictCount =
        autoImport.conflictPaths.count + autoImport.failedPaths.count
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
        "自动检查远端完成：发现 %d 个远端变更，其中 %d 个文章候选路径可手动尝试导入（导入时会校验内容和 slug）。",
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
      setRemoteRepositoryAccessCheck(nil, for: store.activeProfileID)
      repositoryTokenAvailability = try repositoryTokenAvailability(for: store.activeProfile)
      store.publishingStore.removeDraftPublishPreviewSnapshots(
        forProfileID: store.activeProfileID
      )
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
    store.publishingStore.removeDraftPublishPreviewSnapshots(
      forProfileID: store.activeProfileID
    )
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
      setRemoteRepositoryAccessCheck(nil, for: store.activeProfileID)
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
  public func checkRepositoryTokenAccess(store: WorkbenchStore) async
    -> RemoteRepositoryAccessCheck?
  {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.quickHideOperationMessage, status: .warning)
      return nil
    }
    guard !store.isRemoteRepositoryPublishing else {
      store.setPublishActionMessage(
        CoreL10n.text("已有远端仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    let profile = applyDetectedRepositoryRemoteIfNeeded(store: store)
    guard let operation = beginRemoteRepositoryCheck(profile: profile, store: store) else {
      store.setPublishActionMessage(
        CoreL10n.text("已有仓库权限检查或建仓任务正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    clearRemoteRepositoryAccessCheck(for: profile, store: store)
    defer { finishRemoteRepositoryCheck(operation) }
    do {
      let token = try repositoryAccessToken(for: profile)
      let check = try await remoteRepositoryPublishService.checkAccess(
        profile: profile, token: token)
      guard remoteRepositoryCheckIsCurrent(operation, store: store) else { return nil }
      setRemoteRepositoryAccessCheck(check, for: profile.id)
      repositoryTokenAvailability = try repositoryTokenAvailability(for: profile)
      store.publishingStore.removeDraftPublishPreviewSnapshots(forProfileID: profile.id)
      store.setPublishActionMessage(
        check.message,
        status: check.canWrite ? .success : .warning
      )
      store.save()
      store.refreshPublishPreviewInBackground(for: store.selectedDraft)
      await store.publishingStore.waitForPublishPreviewRefresh()
      await store.refreshBatchPublishPlanAsync()
      guard remoteRepositoryCheckIsCurrent(operation, store: store) else { return nil }
      return check
    } catch {
      guard remoteRepositoryCheckIsCurrent(operation, store: store) else { return nil }
      if remoteRepositoryCheckWasCancelled(error) {
        clearRemoteRepositoryAccessCheck(for: profile, store: store)
        store.setPublishActionMessage(
          CoreL10n.text("仓库连接检查已中断。"),
          status: .warning
        )
        return nil
      }
      await invalidateRemoteRepositoryAccessCheck(for: profile, store: store)
      store.setPublishActionMessage(
        CoreL10n.format("仓库权限检查失败：%@", error.localizedDescription),
        status: .failure
      )
      return nil
    }
  }

  /// Ensures a fresh, write-capable proof exists immediately before a remote
  /// mutation. The check itself is read-only; callers must still perform their
  /// normal local and remote publish preflights after this returns.
  public func ensureRemoteRepositoryWriteAccess(
    for profile: SiteProfile,
    store: WorkbenchStore
  ) async -> Bool {
    guard profile.id == store.activeProfileID else {
      store.setPublishActionMessage(
        CoreL10n.text("当前站点已变化，请重新发起线上发布。"),
        status: .warning
      )
      return false
    }

    guard !isRemoteRepositoryChecking else {
      store.setPublishActionMessage(
        CoreL10n.text("仓库连接正在重新验证，请等待完成后再发布。"),
        status: .warning
      )
      return false
    }

    if let check = activeRemoteRepositoryAccessCheck(store: store) {
      guard check.canWrite else {
        store.setPublishActionMessage(
          CoreL10n.text("Token 无写入权限，无法线上发布。"),
          status: .failure
        )
        return false
      }
      return true
    }

    guard let check = await checkRepositoryTokenAccess(store: store) else {
      // checkRepositoryTokenAccess has already preserved the specific
      // configuration, in-progress, or transport failure for the user.
      return false
    }
    guard check.canWrite,
      activeRemoteRepositoryAccessCheck(store: store)?.canWrite == true
    else {
      store.setPublishActionMessage(
        CoreL10n.text("Token 无写入权限，无法线上发布。"),
        status: .failure
      )
      return false
    }
    return true
  }

  private func invalidateRemoteRepositoryAccessCheck(
    for profile: SiteProfile,
    store: WorkbenchStore
  ) async {
    clearRemoteRepositoryAccessCheck(for: profile, store: store)
    store.refreshPublishPreviewInBackground(for: store.selectedDraft)
    await store.publishingStore.waitForPublishPreviewRefresh()
    await store.refreshBatchPublishPlanAsync()
  }

  private func clearRemoteRepositoryAccessCheck(
    for profile: SiteProfile,
    store: WorkbenchStore
  ) {
    setRemoteRepositoryAccessCheck(nil, for: profile.id)
    store.publishingStore.removeDraftPublishPreviewSnapshots(forProfileID: profile.id)
    store.publishingStore.removeBatchRemotePublishPreviewSnapshot()
    store.save()
  }

  func setRemoteRepositoryAccessCheck(
    _ check: RemoteRepositoryAccessCheck?,
    for profileID: UUID
  ) {
    if let check {
      remoteRepositoryAccessCheckByProfileID[profileID] = check
    } else {
      remoteRepositoryAccessCheckByProfileID.removeValue(forKey: profileID)
    }
    if profileID == boundAutomationProfileID {
      remoteRepositoryAccessCheck = check
    }
  }

  public func activeRemoteRepositoryAccessCheck(store: WorkbenchStore)
    -> RemoteRepositoryAccessCheck?
  {
    guard let check = remoteRepositoryAccessCheck,
      remoteRepositoryAccessCheck(check, matches: store.activeProfile),
      check.isFresh()
    else {
      return nil
    }
    return check
  }

  public func hasStaleRemoteRepositoryAccessCheckForActiveProfile(store: WorkbenchStore) -> Bool {
    guard let check = remoteRepositoryAccessCheck else { return false }
    return !remoteRepositoryAccessCheck(check, matches: store.activeProfile) || !check.isFresh()
  }

  private func remoteRepositoryAccessCheck(
    _ check: RemoteRepositoryAccessCheck,
    matches profile: SiteProfile
  ) -> Bool {
    guard check.provider == profile.repositoryProvider,
      check.repositoryName == profile.repositoryDisplayName
    else {
      return false
    }
    if let targetBranch = check.targetBranch?.nilIfEmpty,
      targetBranch != (profile.branch.nilIfEmpty ?? "main")
    {
      return false
    }
    if let publishStrategy = check.publishStrategy,
      publishStrategy != profile.repositoryPublishStrategy
    {
      return false
    }
    guard let checkedAPIBaseURL = check.apiBaseURL?.nilIfEmpty else {
      return true
    }
    guard let profileAPIBaseURL = try? remoteRepositoryPublishService.apiBaseURL(for: profile)
    else {
      return false
    }
    return checkedAPIBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      == remoteRepositoryPublishService.normalizedAPIBaseURLString(profileAPIBaseURL)
  }

  private func repositoryAccessToken(for profile: SiteProfile) throws -> String? {
    try repositoryTokenStore.repositoryToken(for: profile)
  }

  private func repositoryTokenAvailability(for profile: SiteProfile) throws
    -> KeychainTokenAvailability
  {
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
    guard !store.isRemoteRepositoryPublishing else {
      store.setPublishActionMessage(
        CoreL10n.text("已有远端仓库操作正在运行，请等待完成。"),
        status: .warning
      )
      return nil
    }
    guard let operation = beginRemoteRepositoryCheck(profile: profile, store: store) else {
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

  private func beginRemoteRepositoryCheck(
    profile: SiteProfile,
    store: WorkbenchStore
  ) -> RemoteRepositoryOperationContext? {
    guard remoteRepositoryCheckContext == nil,
      !store.isRemoteRepositoryPublishing
    else { return nil }
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

  private func remoteRepositoryCheckWasCancelled(_ error: Error) -> Bool {
    if Task.isCancelled || error is CancellationError {
      return true
    }
    if let urlError = error as? URLError, urlError.code == .cancelled {
      return true
    }
    let cocoaError = error as NSError
    return cocoaError.domain == NSURLErrorDomain && cocoaError.code == URLError.cancelled.rawValue
  }
}
