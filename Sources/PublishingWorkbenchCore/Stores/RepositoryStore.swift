import Combine
import Foundation

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
  @Published public internal(set) var repositoryAutoSyncSettings: RepositoryAutoSyncSettings
  @Published public internal(set) var repositoryAutoSyncState: RepositoryAutoSyncState
  private var repositoryScanTask: Task<Void, Never>?
  private var repositoryScanWorkTask: Task<RepositoryScanReport, Never>?
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
    repositoryAutoSyncSettings: RepositoryAutoSyncSettings = .default,
    repositoryAutoSyncState: RepositoryAutoSyncState = .idle,
    repositoryService: LocalRepositoryService = LocalRepositoryService(),
    repositoryTokenStore: KeychainTokenStore = KeychainTokenStore(service: "PersonalSitePublisher.Repository"),
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
    repositoryScanGeneration &+= 1
    let scanGeneration = repositoryScanGeneration
    repositoryScanState = .scanning()
    let profile = store.activeProfile
    let operation = LocalRepositoryOperationContext(profile: profile)
    let repositoryService = repositoryService
    let previousScanWork = repositoryScanWorkTask
    repositoryScanWorkGeneration &+= 1
    let scanWorkGeneration = repositoryScanWorkGeneration
    let scanWork = Task.detached(priority: .utility) {
      if let previousScanWork {
        _ = await previousScanWork.value
      }
      return repositoryService.scan(profile: profile)
    }
    repositoryScanWorkTask = scanWork
    let scanTask = Task { @MainActor [weak self] in
      let report = await scanWork.value
      guard let self else { return }
      self.finishRepositoryScanWorkIfCurrent(generation: scanWorkGeneration)
      guard self.isCurrentRepositoryScan(
        generation: scanGeneration,
        operation: operation,
        autoSyncGeneration: autoSyncGeneration,
        store: store
      ) else {
        self.finishStaleRepositoryScanIfNeeded(generation: scanGeneration, operation: operation, store: store)
        return
      }
      repositoryReport = report
      repositoryScanState = .finished(report: report)
      store.runPreflight()
      store.refreshPublishPreview(for: store.selectedDraft)
      repositoryScanTask = nil
    }
    repositoryScanTask = scanTask
    await scanTask.value
  }

  public func cancelRepositoryScan() {
    invalidateRepositoryAutoSyncRun()
    repositoryScanTask?.cancel()
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
    # 仓库自动同步审阅

    - 状态：\(repositoryAutoSyncState.status.displayName)
    - 启用：\(repositoryAutoSyncSettings.isEnabled ? "是" : "否")
    - 间隔：\(repositoryAutoSyncSettings.normalizedIntervalMinutes) 分钟
    - 远端变更：\(repositoryAutoSyncState.remoteChangedFileCount)
    - 消息：\(repositoryAutoSyncState.message)
    """
    ]
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
      store.setPublishActionMessage("没有检测到 origin 远端。")
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
    store.setPublishActionMessage("已使用 \(remote.displayName) 更新 PR/MR 配置。")
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

  public func switchActiveProfileRepositoryBranch(to branchName: String, store: WorkbenchStore) {
    var profile = store.activeProfile
    profile.branch = branchName
    store.updateActiveProfile(profile)
    store.save()
  }

  public func createAndSwitchActiveProfileRepositoryBranch(
    name branchName: String,
    from sourceBranch: String? = nil,
    store: WorkbenchStore
  ) {
    switchActiveProfileRepositoryBranch(to: branchName, store: store)
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
      repositoryAutoSyncState.message = "自动同步未启用。"
      return false
    }
    guard !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty else {
      repositoryAutoSyncState.status = .waitingForRepository
      repositoryAutoSyncState.lastRunAt = now
      repositoryAutoSyncState.nextRunAt = repositoryAutoSyncSettings.nextRunDate(after: now)
      repositoryAutoSyncState.message = "自动同步等待本地仓库路径。"
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
        repositoryAutoSyncState.message = "自动同步 Fetch 失败，已保留上次扫描结果：\(fetch.message)"
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
    repositoryAutoSyncState.remoteChangedFileCount = repositoryReport?.remoteChangedFiles.count ?? 0
    repositoryAutoSyncState.remoteChangedPaths = repositoryReport?.remoteChangedFiles.map(\.displayPath) ?? []
    let contentRoot = store.activeProfile.contentRoot.normalizedRelativePath() + "/"
    let importablePaths = repositoryAutoSyncState.remoteChangedPaths.filter {
      $0.normalizedRelativePath().hasPrefix(contentRoot)
        && ["md", "markdown", "mdx"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
    }
    repositoryAutoSyncState.importableRemoteArticleCount = importablePaths.count
    repositoryAutoSyncState.nonArticleRemoteChangedFileCount = max(
      0,
      repositoryAutoSyncState.remoteChangedFileCount - importablePaths.count
    )
    repositoryAutoSyncState.message = "自动同步完成：发现 \(repositoryAutoSyncState.remoteChangedFileCount) 个远端变更，其中 \(importablePaths.count) 篇文章可导入。"
    store.save()
    return true
  }

  public func saveRepositoryAccessToken(_ token: String, store: WorkbenchStore) {
    do {
      try repositoryTokenStore.saveToken(
        token.trimmedForPublishing,
        for: store.activeProfile,
        scope: repositoryTokenScope(for: store.activeProfile)
      )
      remoteRepositoryAccessCheck = nil
      repositoryTokenAvailability = try repositoryTokenAvailability(for: store.activeProfile)
      store.setPublishActionMessage("仓库访问 Token 已保存到 Keychain。")
      store.save()
    } catch {
      store.setPublishActionMessage("仓库 Token 保存失败：\(error.localizedDescription)")
    }
  }

  public func refreshRepositoryTokenAvailability(store: WorkbenchStore) {
    repositoryTokenAvailability = (try? repositoryTokenAvailability(for: store.activeProfile)) ?? KeychainTokenAvailability(hasToken: false)
  }

  public func refreshRepositoryTokenAvailability(updatesMessage: Bool, store: WorkbenchStore) {
    refreshRepositoryTokenAvailability(store: store)
    if updatesMessage {
      store.setPublishActionMessage(repositoryTokenAvailability.hasToken ? "仓库 Token 已配置。" : "仓库 Token 未配置。")
    }
  }

  public func deleteRepositoryAccessToken(store: WorkbenchStore) {
    do {
      try repositoryTokenStore.deleteToken(
        for: store.activeProfile,
        scope: repositoryTokenScope(for: store.activeProfile)
      )
      remoteRepositoryAccessCheck = nil
      refreshRepositoryTokenAvailability(store: store)
      store.setPublishActionMessage("仓库 Token 已删除。")
      store.save()
    } catch {
      store.setPublishActionMessage("仓库 Token 删除失败：\(error.localizedDescription)")
    }
  }

  @discardableResult
  public func checkRepositoryTokenAccess(store: WorkbenchStore) async -> RemoteRepositoryAccessCheck? {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.privacyLockedOperationMessage)
      return nil
    }
    let profile = store.activeProfile
    guard let operation = beginRemoteRepositoryCheck(profile: profile) else {
      store.setPublishActionMessage("已有仓库权限检查或建仓任务正在运行，请等待完成。")
      return nil
    }
    defer { finishRemoteRepositoryCheck(operation) }
    do {
      let token = try repositoryAccessToken(for: profile)
      let check = try await remoteRepositoryPublishService.checkAccess(profile: profile, token: token)
      guard remoteRepositoryCheckIsCurrent(operation, store: store) else { return nil }
      remoteRepositoryAccessCheck = check
      repositoryTokenAvailability = try repositoryTokenAvailability(for: profile)
      store.setPublishActionMessage(check.message)
      store.save()
      return check
    } catch {
      guard remoteRepositoryCheckIsCurrent(operation, store: store) else { return nil }
      store.setPublishActionMessage("仓库权限检查失败：\(error.localizedDescription)")
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

  private func repositoryTokenScope(for profile: SiteProfile) -> KeychainTokenScope {
    .repository(profile.repositoryProvider)
  }

  private func repositoryAccessToken(for profile: SiteProfile) throws -> String? {
    try repositoryTokenStore.repositoryToken(for: profile)
  }

  private func repositoryTokenAvailability(for profile: SiteProfile) throws -> KeychainTokenAvailability {
    try repositoryTokenStore.repositoryTokenAvailability(for: profile)
  }

  @discardableResult
  public func createRemoteRepositoryForActiveProfile(
    privateRepository: Bool = false,
    store: WorkbenchStore
  ) async -> RemoteRepositoryCreationResult? {
    guard store.canUseProtectedWorkbench else {
      store.setPublishActionMessage(store.privacyLockedOperationMessage)
      return nil
    }
    let profile = store.activeProfile
    guard let operation = beginRemoteRepositoryCheck(profile: profile) else {
      store.setPublishActionMessage("已有仓库权限检查或建仓任务正在运行，请等待完成。")
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
      store.setPublishActionMessage("\(result.provider.displayName) 仓库已创建：\(result.repositoryName)。")
      store.save()
      return result
    } catch {
      guard remoteRepositoryCheckIsCurrent(operation, store: store) else { return nil }
      store.setPublishActionMessage("远端仓库创建失败：\(error.localizedDescription)")
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
