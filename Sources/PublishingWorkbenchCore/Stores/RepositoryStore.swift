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
    if profile.id == store.activeProfileID,
       let repositoryReport,
       profile.localRepositoryRootPath.trimmedForPublishing.isEmpty
        || repositoryReport.rootPath == profile.resolvedLocalRepositoryRootURL?.path {
      return repositoryReport
    }
    return repositoryService.scan(profile: profile)
  }

  @available(*, deprecated, message: "Use scanRepositoryAsync(store:) so repository scanning does not block the main actor.")
  public func scanRepository(store: WorkbenchStore) {
    repositoryReport = repositoryService.scan(profile: store.activeProfile)
    store.runPreflight()
    store.refreshPublishPreview(for: store.selectedDraft)
  }

  public func scanRepositoryAsync(store: WorkbenchStore) async {
    repositoryScanTask?.cancel()
    repositoryScanState = .scanning()
    let profile = store.activeProfile
    let repositoryService = repositoryService
    let scanTask = Task.detached(priority: .utility) {
      repositoryService.scan(profile: profile)
    }
    repositoryScanTask = Task { @MainActor in
      let report = await scanTask.value
      guard !Task.isCancelled else {
        repositoryScanState = .cancelled()
        return
      }
      repositoryReport = report
      repositoryScanState = .finished(report: report)
      store.runPreflight()
      store.refreshPublishPreview(for: store.selectedDraft)
    }
    await repositoryScanTask?.value
  }

  public func cancelRepositoryScan() {
    repositoryScanTask?.cancel()
    repositoryScanTask = nil
    repositoryScanState = .cancelled()
  }

  @available(*, deprecated, message: "Use rememberRepositoryRootAsync(_:store:) so choosing a repository does not run a synchronous scan on the main actor.")
  public func rememberRepositoryRoot(_ url: URL, store: WorkbenchStore) {
    var profile = store.activeProfile
    _ = profile.rememberLocalRepositoryRoot(url)
    store.updateActiveProfile(profile)
    scanRepository(store: store)
    store.save()
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
  public func tickRepositoryAutoSync(store: WorkbenchStore, now: Date = Date()) -> Bool {
    guard repositoryAutoSyncSettings.isDue(lastRunAt: repositoryAutoSyncState.lastRunAt, now: now) else {
      return false
    }
    return runRepositoryAutoSync(store: store, now: now)
  }

  @discardableResult
  public func runRepositoryAutoSync(store: WorkbenchStore, now: Date = Date()) -> Bool {
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
    var shouldRescan = true
    if repositoryAutoSyncSettings.fetchBeforeScan {
      let fetch = repositoryService.fetchUpstream(profile: store.activeProfile)
      repositoryAutoSyncState.lastFetchAt = now
      repositoryAutoSyncState.fetchSucceeded = fetch.status == .succeeded
      repositoryAutoSyncState.fetchMessage = fetch.message
      if fetch.status == .failed, repositoryReport != nil {
        shouldRescan = false
      }
    }
    if shouldRescan {
      scanRepository(store: store)
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
    do {
      isRemoteRepositoryChecking = true
      defer { isRemoteRepositoryChecking = false }
      let token = try repositoryAccessToken(for: store.activeProfile)
      let check = try await remoteRepositoryPublishService.checkAccess(profile: store.activeProfile, token: token)
      remoteRepositoryAccessCheck = check
      repositoryTokenAvailability = try repositoryTokenAvailability(for: store.activeProfile)
      store.setPublishActionMessage(check.message)
      store.save()
      return check
    } catch {
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
    _ = try repositoryTokenStore.migrateLegacyToken(
      for: profile,
      to: repositoryTokenScope(for: profile),
      deleteLegacyToken: false
    )
    return try repositoryTokenStore.token(for: profile, scope: repositoryTokenScope(for: profile))
  }

  private func repositoryTokenAvailability(for profile: SiteProfile) throws -> KeychainTokenAvailability {
    _ = try repositoryTokenStore.migrateLegacyToken(
      for: profile,
      to: repositoryTokenScope(for: profile),
      deleteLegacyToken: false
    )
    return try repositoryTokenStore.availability(for: profile, scope: repositoryTokenScope(for: profile))
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
    do {
      isRemoteRepositoryChecking = true
      defer { isRemoteRepositoryChecking = false }
      let token = try repositoryAccessToken(for: store.activeProfile)
      let result = try await remoteRepositoryPublishService.createRepository(
        profile: store.activeProfile,
        token: token,
        privateRepository: privateRepository
      )
      remoteRepositoryCreationResult = result
      repositoryTokenAvailability = try repositoryTokenAvailability(for: store.activeProfile)
      store.setPublishActionMessage("\(result.provider.displayName) 仓库已创建：\(result.repositoryName)。")
      store.save()
      return result
    } catch {
      store.setPublishActionMessage("远端仓库创建失败：\(error.localizedDescription)")
      return nil
    }
  }
}
