import Combine
import Foundation

@MainActor
public final class DeploymentStore: ObservableObject {
  private static let deploymentStatusHistoryLimitPerRecord = 6

  private let deploymentStatusService: DeploymentStatusService
  private let deploymentTokenStore: KeychainTokenStore
  private let releaseLedgerService: ReleaseLedgerService
  private var latestDeploymentStatusRequestIDByRecord: [UUID: UUID] = [:]
  private var activeDeploymentStatusRequestIDs: Set<UUID> = []

  @Published public internal(set) var deploymentStatusSnapshots: [UUID: DeploymentStatusSnapshot]
  @Published public internal(set) var deploymentStatusHistory: [UUID: [DeploymentStatusSnapshot]]
  @Published public internal(set) var isDeploymentStatusChecking: Bool
  @Published public internal(set) var deploymentStatusMessage: String?
  @Published public internal(set) var deploymentPollingSettings: DeploymentPollingSettings
  @Published public internal(set) var deploymentPollingState: DeploymentPollingState
  @Published public internal(set) var deploymentTokenAvailability: KeychainTokenAvailability

  init(
    deploymentStatusSnapshots: [UUID: DeploymentStatusSnapshot] = [:],
    deploymentStatusHistory: [UUID: [DeploymentStatusSnapshot]] = [:],
    isDeploymentStatusChecking: Bool = false,
    deploymentStatusMessage: String? = nil,
    deploymentPollingSettings: DeploymentPollingSettings = .default,
    deploymentPollingState: DeploymentPollingState = .idle,
    deploymentTokenAvailability: KeychainTokenAvailability = KeychainTokenAvailability(hasToken: false),
    deploymentStatusService: DeploymentStatusService = DeploymentStatusService(),
    deploymentTokenStore: KeychainTokenStore = KeychainTokenStore(service: KeychainCredentialServices.deployment, accountPrefix: "deployment-provider"),
    releaseLedgerService: ReleaseLedgerService = ReleaseLedgerService()
  ) {
    self.deploymentStatusService = deploymentStatusService
    self.deploymentTokenStore = deploymentTokenStore
    self.releaseLedgerService = releaseLedgerService
    self.deploymentStatusSnapshots = deploymentStatusSnapshots
    self.deploymentStatusHistory = deploymentStatusHistory
    self.isDeploymentStatusChecking = isDeploymentStatusChecking
    self.deploymentStatusMessage = deploymentStatusMessage
    self.deploymentPollingSettings = deploymentPollingSettings
    self.deploymentPollingState = deploymentPollingState
    self.deploymentTokenAvailability = deploymentTokenAvailability
  }

  public func deploymentStatusReadiness(
    for profile: SiteProfile,
    hasToken: Bool
  ) -> DeploymentStatusProviderReadiness {
    deploymentStatusService.readiness(
      profile: profile,
      hasToken: hasToken
    )
  }

  public func deploymentStatusReadiness(
    for profile: SiteProfile,
    tokenAvailability: KeychainTokenAvailability
  ) -> DeploymentStatusProviderReadiness {
    var readiness = deploymentStatusReadiness(
      for: profile,
      hasToken: tokenAvailability.hasToken
    )
    guard let accessFailureMessage = tokenAvailability.accessFailureMessage else {
      return readiness
    }

    let accessFailureRequirement = CoreL10n.format(
      "部署 Token 状态读取失败：%@",
      accessFailureMessage
    )
    readiness.missingRequirements.removeAll {
      $0 == CoreL10n.text("部署 Token")
    }
    readiness.missingRequirements.insert(accessFailureRequirement, at: 0)
    if readiness.canCheckAnyStatus {
      readiness.nextStep = accessFailureRequirement
    } else {
      readiness.nextStep = CoreL10n.format(
        "先补齐 %@。",
        readiness.missingRequirements.joined(separator: CoreL10n.text("、"))
      )
      readiness.fallbackMessage = [
        readiness.fallbackMessage,
        accessFailureRequirement,
      ].joined(separator: " ")
    }
    return readiness
  }

  public func deploymentStatusReadiness(
    for record: ReleaseRecord,
    store: WorkbenchStore
  ) -> DeploymentStatusProviderReadiness {
    deploymentStatusReadiness(
      for: store.profile(for: record),
      tokenAvailability: resolvedDeploymentTokenAvailability(
        for: store.profile(for: record)
      )
    )
  }

  public func activeDeploymentStatusReadiness(store: WorkbenchStore) -> DeploymentStatusProviderReadiness {
    deploymentStatusReadiness(
      for: store.activeProfile,
      tokenAvailability: deploymentTokenAvailability
    )
  }

  public func shouldRefreshDeploymentStatusAfterRemoteOperation(
    _ record: ReleaseRecord,
    store: WorkbenchStore
  ) -> Bool {
    guard record.kind != .remoteReviewRequest else { return false }
    if record.kind == .remotePublishFailure {
      guard record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil else { return false }
    }
    return deploymentStatusReadiness(for: record, store: store).canCheckAnyStatus
  }

  public func deploymentStatusSnapshot(for record: ReleaseRecord) -> DeploymentStatusSnapshot? {
    deploymentStatusSnapshots[record.id]
  }

  public func deploymentStatusHistory(for record: ReleaseRecord, limit: Int = 6) -> [DeploymentStatusSnapshot] {
    Array((deploymentStatusHistory[record.id] ?? []).prefix(max(limit, 0)))
  }

  public func remoteRollbackDraft(for record: ReleaseRecord) -> RemoteRepositoryRollbackDraft? {
    try? RemoteRepositoryRollbackDraft.make(record: record)
  }

  public func remoteReviewWithdrawalDraft(for record: ReleaseRecord) -> RemoteRepositoryReviewWithdrawalDraft? {
    try? RemoteRepositoryReviewWithdrawalDraft.make(record: record)
  }

  public func releaseLedger(store: WorkbenchStore) -> ReleaseLedger {
    releaseLedgerService.ledger(
      releaseRecords: store.releaseRecords,
      deploymentStatusSnapshots: deploymentStatusSnapshots
    )
  }

  public func activeProfileReleaseRecords(store: WorkbenchStore) -> [ReleaseRecord] {
    store.releaseRecords
      .filter { $0.siteProfileID == nil || $0.siteProfileID == store.activeProfileID }
      .sorted { $0.createdAt > $1.createdAt }
  }

  public func activeProfileDeploymentStatusSnapshots(store: WorkbenchStore) -> [UUID: DeploymentStatusSnapshot] {
    let activeRecords = activeProfileReleaseRecords(store: store)
    return activeProfileDeploymentStatusSnapshots(for: activeRecords)
  }

  public func activeProfileReleaseLedger(store: WorkbenchStore) -> ReleaseLedger {
    let activeRecords = activeProfileReleaseRecords(store: store)
    return releaseLedgerService.ledger(
      releaseRecords: activeRecords,
      deploymentStatusSnapshots: activeProfileDeploymentStatusSnapshots(for: activeRecords)
    )
  }

  private func activeProfileDeploymentStatusSnapshots(
    for activeRecords: [ReleaseRecord]
  ) -> [UUID: DeploymentStatusSnapshot] {
    let activeRecordIDs = Set(activeRecords.map(\.id))
    return deploymentStatusSnapshots.filter { activeRecordIDs.contains($0.key) }
  }

  public func releaseLedgerEntry(for record: ReleaseRecord) -> ReleaseLedgerEntry {
    releaseLedgerService.ledger(
      releaseRecords: [record],
      deploymentStatusSnapshots: deploymentStatusSnapshots
    ).entries.first ?? ReleaseLedgerEntry(
      id: record.id,
      record: record,
      status: .unknown,
      statusMessage: CoreL10n.text("未找到发布账本记录。"),
      deploymentStatus: deploymentStatusSnapshots[record.id],
      rollbackDraft: nil
    )
  }

  public func releaseRecoveryVerificationDraftMarkdown(store: WorkbenchStore) -> String {
    activeProfileReleaseLedger(store: store).remoteRecoveryVerificationDraftMarkdown
  }

  public func deploymentPollingEligibleRecords(store: WorkbenchStore) -> [ReleaseRecord] {
    let activeLedgerEntriesByID = Dictionary(
      uniqueKeysWithValues: store.activeProfileReleaseLedger.entries.map { ($0.id, $0) }
    )
    return store.releaseRecords.compactMap { record in
      guard record.siteProfileID == nil || record.siteProfileID == store.activeProfileID,
            let entry = activeLedgerEntriesByID[record.id],
            canPollDeploymentStatus(for: entry.status),
            canCheckDeploymentStatus(for: record, store: store) else {
        return nil
      }
      return record
    }
  }

  public func updateDeploymentPollingSettings(
    _ settings: DeploymentPollingSettings,
    store: WorkbenchStore
  ) {
    deploymentPollingSettings = DeploymentPollingSettings(
      isEnabled: settings.isEnabled,
      intervalMinutes: settings.normalizedIntervalMinutes
    )
    if deploymentPollingSettings.isEnabled {
      let now = Date()
      deploymentPollingState.nextRunAt = deploymentPollingSettings.nextRunDate(after: now)
      if deploymentPollingState.lastRunAt == nil {
        deploymentPollingState.message = CoreL10n.format(
          "部署轮询已开启，将每 %@ 分钟检查待部署记录。",
          String(deploymentPollingSettings.normalizedIntervalMinutes)
        )
      }
    } else {
      deploymentPollingState = DeploymentPollingState(
        status: .disabled,
        message: CoreL10n.text("部署轮询已关闭。")
      )
    }
    store.save()
  }

  @discardableResult
  public func tickDeploymentPolling(
    store: WorkbenchStore,
    now: Date = Date()
  ) async -> Bool {
    guard deploymentPollingSettings.isDue(lastRunAt: deploymentPollingState.lastRunAt, now: now) else {
      return false
    }
    return await runDeploymentPolling(store: store, now: now)
  }

  @discardableResult
  public func runDeploymentPolling(
    store: WorkbenchStore,
    now: Date = Date()
  ) async -> Bool {
    guard deploymentPollingSettings.isEnabled else {
      deploymentPollingState = DeploymentPollingState(
        status: .disabled,
        message: CoreL10n.text("部署轮询已关闭。")
      )
      store.save()
      return false
    }

    let records = deploymentPollingEligibleRecords(store: store)
    guard !records.isEmpty else {
      deploymentPollingState = DeploymentPollingState(
        status: .noEligibleRecords,
        lastRunAt: now,
        nextRunAt: deploymentPollingSettings.nextRunDate(after: now),
        checkedRecordCount: 0,
        checkedRecords: [],
        message: CoreL10n.text("当前没有需要轮询的部署记录。")
      )
      store.save()
      return true
    }

    var checkedCount = 0
    var checkedRecords: [DeploymentPollingRecordSummary] = []
    for record in records {
      if let snapshot = await refreshDeploymentStatus(for: record, store: store, updatesMessage: false) {
        let releaseStatus = store.activeProfileReleaseLedger.entries.first { $0.id == record.id }?.status
        checkedCount += 1
        checkedRecords.append(
          DeploymentPollingRecordSummary(
            recordID: record.id,
            title: record.draftTitle ?? record.title,
            releaseStatus: releaseStatus,
            provider: snapshot.provider,
            level: snapshot.level,
            message: snapshot.message,
            checkedAt: snapshot.checkedAt
          )
        )
      }
    }

    deploymentPollingState = DeploymentPollingState(
      status: .checked,
      lastRunAt: now,
      nextRunAt: deploymentPollingSettings.nextRunDate(after: now),
      checkedRecordCount: checkedCount,
      checkedRecords: checkedRecords,
      message: deploymentPollingMessage(checkedCount: checkedCount, checkedRecords: checkedRecords)
    )
    deploymentStatusMessage = deploymentPollingState.message
    store.save()
    return true
  }

  public func canCheckDeploymentStatus(
    for record: ReleaseRecord,
    store: WorkbenchStore
  ) -> Bool {
    deploymentStatusReadiness(for: record, store: store).canCheckAnyStatus
  }

  @discardableResult
  public func refreshDeploymentStatus(
    for record: ReleaseRecord,
    store: WorkbenchStore,
    updatesMessage: Bool = true
  ) async -> DeploymentStatusSnapshot? {
    guard canCheckDeploymentStatus(for: record, store: store) else {
      deploymentStatusMessage = deploymentStatusReadiness(for: record, store: store).nextStep
      return nil
    }

    let requestID = UUID()
    latestDeploymentStatusRequestIDByRecord[record.id] = requestID
    activeDeploymentStatusRequestIDs.insert(requestID)
    isDeploymentStatusChecking = true
    if updatesMessage {
      deploymentStatusMessage = CoreL10n.text("正在检查部署状态...")
    }
    defer {
      activeDeploymentStatusRequestIDs.remove(requestID)
      if latestDeploymentStatusRequestIDByRecord[record.id] == requestID {
        latestDeploymentStatusRequestIDByRecord.removeValue(forKey: record.id)
      }
      isDeploymentStatusChecking = !activeDeploymentStatusRequestIDs.isEmpty
    }

    let profile = store.profile(for: record)
    let token: String?
    let tokenAccessFailureMessage: String?
    do {
      token = try deploymentAccessToken(for: profile)
      tokenAccessFailureMessage = nil
    } catch {
      token = nil
      tokenAccessFailureMessage = CoreL10n.format(
        "部署 Token 状态读取失败：%@",
        error.localizedDescription
      )
      if profile.id == store.activeProfile.id {
        deploymentTokenAvailability = KeychainTokenAvailability(accessFailure: error)
      }
      deploymentStatusMessage = tokenAccessFailureMessage
      let fallbackReadiness = deploymentStatusReadiness(
        for: profile,
        hasToken: false
      )
      guard fallbackReadiness.canCheckAnyStatus else {
        return nil
      }
    }
    let snapshot = await deploymentStatusService.check(
      profile: profile,
      releaseRecord: record,
      token: token
    )
    guard latestDeploymentStatusRequestIDByRecord[record.id] == requestID else {
      return nil
    }
    recordDeploymentStatusSnapshot(snapshot, for: record)
    if updatesMessage {
      let statusMessage = CoreL10n.format(
        "%@：%@",
        snapshot.provider.displayName,
        snapshot.level.displayName
      )
      deploymentStatusMessage = [tokenAccessFailureMessage, statusMessage]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
    store.save()
    return snapshot
  }

  public func recordDeploymentStatusSnapshot(_ snapshot: DeploymentStatusSnapshot, for record: ReleaseRecord) {
    deploymentStatusSnapshots[record.id] = snapshot
    deploymentStatusHistory[record.id] = Array(
      ([snapshot] + (deploymentStatusHistory[record.id] ?? []))
        .sorted { $0.checkedAt > $1.checkedAt }
        .prefix(Self.deploymentStatusHistoryLimitPerRecord)
    )
  }

  @discardableResult
  public func saveDeploymentAccessToken(_ token: String, store: WorkbenchStore) -> Bool {
    do {
      try deploymentTokenStore.saveToken(
        token.trimmedForPublishing,
        for: store.activeProfile,
        scope: deploymentTokenScope(for: store.activeProfile),
        originURLText: deploymentCredentialOriginURLText(for: store.activeProfile)
      )
      refreshDeploymentTokenAvailability(store: store)
      deploymentStatusMessage = CoreL10n.format(
        "%@ 部署 Token 已保存。",
        deploymentProvider(for: store.activeProfile).displayName
      )
      return true
    } catch {
      deploymentStatusMessage = CoreL10n.format("部署 Token 保存失败：%@", error.localizedDescription)
      return false
    }
  }

  public func deleteDeploymentAccessToken(store: WorkbenchStore) {
    do {
      try deploymentTokenStore.deleteToken(
        for: store.activeProfile,
        scope: deploymentTokenScope(for: store.activeProfile),
        originURLText: deploymentCredentialOriginURLText(for: store.activeProfile)
      )
      refreshDeploymentTokenAvailability(store: store)
      deploymentStatusMessage = CoreL10n.format(
        "%@ 部署 Token 已删除。",
        deploymentProvider(for: store.activeProfile).displayName
      )
    } catch {
      deploymentStatusMessage = CoreL10n.format("部署 Token 删除失败：%@", error.localizedDescription)
    }
  }

  public func refreshDeploymentTokenAvailability(store: WorkbenchStore) {
    let profile = store.activeProfile
    deploymentTokenAvailability = resolvedDeploymentTokenAvailability(for: profile)
    if let accessFailureMessage = deploymentTokenAvailability.accessFailureMessage {
      deploymentStatusMessage = CoreL10n.format(
        "部署 Token 状态读取失败：%@",
        accessFailureMessage
      )
    }
  }

  private func resolvedDeploymentTokenAvailability(
    for profile: SiteProfile
  ) -> KeychainTokenAvailability {
    do {
      return try deploymentTokenStore.availability(
        for: profile,
        scope: deploymentTokenScope(for: profile),
        originURLText: deploymentCredentialOriginURLText(for: profile)
      )
    } catch {
      return KeychainTokenAvailability(accessFailure: error)
    }
  }

  private func deploymentAccessToken(for profile: SiteProfile) throws -> String? {
    try deploymentTokenStore.token(
      for: profile,
      scope: deploymentTokenScope(for: profile),
      originURLText: deploymentCredentialOriginURLText(for: profile)
    )
  }

  private func deploymentTokenScope(for profile: SiteProfile) -> KeychainTokenScope {
    .deployment(deploymentProvider(for: profile))
  }

  private func deploymentProvider(for profile: SiteProfile) -> DeploymentProvider {
    if let provider = profile.deploymentProvider {
      return provider
    }
    return profile.repositoryProvider == .github ? .githubPages : .gitlabPages
  }

  private func deploymentCredentialOriginURLText(for profile: SiteProfile) -> String {
    switch deploymentProvider(for: profile) {
    case .githubPages:
      return profile.repositoryBaseURL.nilIfEmpty ?? RepositoryProvider.github.defaultBaseURL
    case .gitlabPages:
      return profile.repositoryBaseURL.nilIfEmpty ?? RepositoryProvider.gitlab.defaultBaseURL
    case .netlify:
      return "https://api.netlify.com"
    case .vercel:
      return "https://api.vercel.com"
    case .cloudflarePages:
      return "https://api.cloudflare.com"
    case .custom:
      return profile.deploymentStatusEndpointURL?.nilIfEmpty ?? ""
    }
  }

  private func deploymentPollingMessage(
    checkedCount: Int,
    checkedRecords: [DeploymentPollingRecordSummary]
  ) -> String {
    guard checkedCount > 0 else {
      return CoreL10n.text("部署轮询已运行，但没有成功取得部署状态。")
    }

    let successCount = checkedRecords.filter(\.isResolvedSuccess).count
    let runningCount = checkedRecords.filter { $0.level == .running }.count
    let failedCount = checkedRecords.filter { $0.level == .failed }.count
    let unknownCount = checkedRecords.filter { $0.level == .unknown }.count
    let remoteRecoveryCount = checkedRecords.filter(\.isPendingRemoteRecovery).count
    var parts = [
      CoreL10n.format("正常 %@", String(successCount)),
      CoreL10n.format("部署中 %@", String(runningCount)),
    ]
    if remoteRecoveryCount > 0 {
      parts.append(CoreL10n.format("远端恢复待确认 %@", String(remoteRecoveryCount)))
    }
    if failedCount > 0 {
      parts.append(CoreL10n.format("失败 %@", String(failedCount)))
    }
    if unknownCount > 0 {
      parts.append(CoreL10n.format("未知 %@", String(unknownCount)))
    }
    return CoreL10n.format(
      "部署轮询已检查 %@ 条待部署记录：%@。",
      String(checkedCount),
      parts.joined(separator: CoreL10n.text("，"))
    )
  }

  private func canPollDeploymentStatus(for status: ReleaseLedgerStatus) -> Bool {
    switch status {
    case .pendingDeployment, .pendingRemoteRecovery, .pendingRetry, .deploying, .unknown:
      return true
    case .localOnly, .pendingReview, .succeeded, .failed:
      return false
    }
  }
}
