import Combine
import Foundation

@MainActor
public final class DeploymentStore: ObservableObject {
  private static let deploymentStatusHistoryLimitPerRecord = 6

  private let deploymentStatusService: DeploymentStatusService
  private let deploymentWebhookService: DeploymentWebhookService
  private let deploymentTokenStore: KeychainTokenStore
  private let legacyRepositoryTokenStore: KeychainTokenStore
  private let releaseLedgerService: ReleaseLedgerService
  private var deploymentWebhookHTTPReceiver: DeploymentWebhookHTTPReceiver?

  @Published public internal(set) var deploymentStatusSnapshots: [UUID: DeploymentStatusSnapshot]
  @Published public internal(set) var deploymentStatusHistory: [UUID: [DeploymentStatusSnapshot]]
  @Published public internal(set) var isDeploymentStatusChecking: Bool
  @Published public internal(set) var deploymentStatusMessage: String?
  @Published public internal(set) var deploymentWebhookHTTPReceiverState: DeploymentWebhookHTTPReceiverState
  @Published public internal(set) var deploymentPollingSettings: DeploymentPollingSettings
  @Published public internal(set) var deploymentPollingState: DeploymentPollingState
  @Published public internal(set) var deploymentTokenAvailability: KeychainTokenAvailability

  init(
    deploymentStatusSnapshots: [UUID: DeploymentStatusSnapshot] = [:],
    deploymentStatusHistory: [UUID: [DeploymentStatusSnapshot]] = [:],
    isDeploymentStatusChecking: Bool = false,
    deploymentStatusMessage: String? = nil,
    deploymentWebhookHTTPReceiverState: DeploymentWebhookHTTPReceiverState = .idle,
    deploymentPollingSettings: DeploymentPollingSettings = .default,
    deploymentPollingState: DeploymentPollingState = .idle,
    deploymentTokenAvailability: KeychainTokenAvailability = KeychainTokenAvailability(hasToken: false),
    deploymentStatusService: DeploymentStatusService = DeploymentStatusService(),
    deploymentWebhookService: DeploymentWebhookService = DeploymentWebhookService(),
    deploymentTokenStore: KeychainTokenStore = KeychainTokenStore(service: "PersonalSitePublisherMac.DeploymentProvider", accountPrefix: "deployment-provider"),
    legacyRepositoryTokenStore: KeychainTokenStore = KeychainTokenStore(service: "PersonalSitePublisherMac.RepositoryProvider", accountPrefix: "repository-provider"),
    releaseLedgerService: ReleaseLedgerService = ReleaseLedgerService()
  ) {
    self.deploymentStatusService = deploymentStatusService
    self.deploymentWebhookService = deploymentWebhookService
    self.deploymentTokenStore = deploymentTokenStore
    self.legacyRepositoryTokenStore = legacyRepositoryTokenStore
    self.releaseLedgerService = releaseLedgerService
    self.deploymentStatusSnapshots = deploymentStatusSnapshots
    self.deploymentStatusHistory = deploymentStatusHistory
    self.isDeploymentStatusChecking = isDeploymentStatusChecking
    self.deploymentStatusMessage = deploymentStatusMessage
    self.deploymentWebhookHTTPReceiverState = deploymentWebhookHTTPReceiverState
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
    for record: ReleaseRecord,
    store: WorkbenchStore
  ) -> DeploymentStatusProviderReadiness {
    deploymentStatusReadiness(
      for: store.profile(for: record),
      hasToken: hasDeploymentToken(for: store.profile(for: record))
    )
  }

  public func activeDeploymentStatusReadiness(store: WorkbenchStore) -> DeploymentStatusProviderReadiness {
    deploymentStatusReadiness(for: store.activeProfile, hasToken: hasDeploymentToken(for: store.activeProfile))
  }

  public func shouldRefreshDeploymentStatusAfterRemoteOperation(
    _ record: ReleaseRecord,
    store: WorkbenchStore
  ) -> Bool {
    guard record.kind != .remoteReviewRequest else { return false }
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
    return deploymentStatusSnapshots.filter { id, _ in activeRecords.contains { $0.id == id } }
  }

  public func activeProfileReleaseLedger(store: WorkbenchStore) -> ReleaseLedger {
    releaseLedgerService.ledger(
      releaseRecords: activeProfileReleaseRecords(store: store),
      deploymentStatusSnapshots: activeProfileDeploymentStatusSnapshots(store: store)
    )
  }

  public func releaseLedgerEntry(for record: ReleaseRecord, store: WorkbenchStore) -> ReleaseLedgerEntry {
    releaseLedgerService.ledger(
      releaseRecords: [record],
      deploymentStatusSnapshots: deploymentStatusSnapshots
    ).entries.first ?? ReleaseLedgerEntry(
      id: record.id,
      record: record,
      status: .unknown,
      statusMessage: "未找到发布账本记录。",
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
        deploymentPollingState.message = "部署轮询已开启，将每 \(deploymentPollingSettings.normalizedIntervalMinutes) 分钟检查待部署记录。"
      }
    } else {
      deploymentPollingState = DeploymentPollingState(
        status: .disabled,
        message: "部署轮询已关闭。"
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
        message: "部署轮询已关闭。"
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
        message: "当前没有需要轮询的部署记录。"
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
  public func receiveDeploymentWebhook(
    provider: DeploymentProvider,
    payloadText: String,
    store: WorkbenchStore,
    for record: ReleaseRecord? = nil,
    receivedAt: Date = Date()
  ) -> DeploymentWebhookReceiveResult? {
    let targetRecord = record ?? store.activeProfileReleaseRecords.first
    do {
      let targetProfile = targetRecord.map { store.profile(for: $0) } ?? store.activeProfile
      let result = try deploymentWebhookService.receive(
        provider: provider,
        payloadText: payloadText,
        profile: targetProfile,
        releaseRecord: targetRecord,
        receivedAt: receivedAt
      )
      if let targetRecord {
        recordDeploymentStatusSnapshot(result.snapshot, for: targetRecord)
      }
      deploymentStatusMessage = "已接收 \(provider.displayName) Webhook：\(result.snapshot.level.displayName)"
      store.save()
      return result
    } catch {
      deploymentStatusMessage = "Webhook 接收失败：\(error.localizedDescription)"
      return nil
    }
  }

  public func startDeploymentWebhookHTTPReceiver(
    store: WorkbenchStore,
    port: UInt16 = 8787
  ) {
    let receiver = DeploymentWebhookHTTPReceiver()
    do {
      let endpoint = try receiver.start(port: port) { [weak self, weak store] provider, payloadText in
        guard let deploymentStore = self, let workbenchStore = store else {
          return false
        }
        return await MainActor.run {
          deploymentStore.receiveDeploymentWebhook(
            provider: provider,
            payloadText: payloadText,
            store: workbenchStore
          ) != nil
        }
      }
      deploymentWebhookHTTPReceiver = receiver
      deploymentWebhookHTTPReceiverState = DeploymentWebhookHTTPReceiverState(
        isRunning: true,
        port: port,
        endpointURLText: endpoint,
        message: "Webhook 接收器已启动。"
      )
      deploymentStatusMessage = "Webhook 接收器已启动：\(endpoint)"
    } catch {
      deploymentWebhookHTTPReceiver = nil
      deploymentWebhookHTTPReceiverState = DeploymentWebhookHTTPReceiverState(
        isRunning: false,
        port: port,
        endpointURLText: nil,
        message: "Webhook 接收器启动失败：\(error.localizedDescription)"
      )
      deploymentStatusMessage = deploymentWebhookHTTPReceiverState.message
    }
  }

  public func stopDeploymentWebhookHTTPReceiver() {
    deploymentWebhookHTTPReceiver?.stop()
    deploymentWebhookHTTPReceiver = nil
    deploymentWebhookHTTPReceiverState = .idle
    deploymentStatusMessage = "Webhook 接收器已停止。"
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

    isDeploymentStatusChecking = true
    if updatesMessage {
      deploymentStatusMessage = "正在检查部署状态..."
    }
    defer {
      isDeploymentStatusChecking = false
    }

    let profile = store.profile(for: record)
    let token = try? deploymentAccessToken(for: profile)
    let snapshot = await deploymentStatusService.check(
      profile: profile,
      releaseRecord: record,
      token: token
    )
    recordDeploymentStatusSnapshot(snapshot, for: record)
    deploymentStatusMessage = "\(snapshot.provider.displayName)：\(snapshot.level.displayName)"
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

  public func saveDeploymentAccessToken(_ token: String, store: WorkbenchStore) {
    do {
      try deploymentTokenStore.saveToken(
        token.trimmedForPublishing,
        for: store.activeProfile,
        scope: deploymentTokenScope(for: store.activeProfile)
      )
      refreshDeploymentTokenAvailability(store: store)
      deploymentStatusMessage = "\(deploymentProvider(for: store.activeProfile).displayName) 部署 Token 已保存。"
    } catch {
      deploymentStatusMessage = "部署 Token 保存失败：\(error.localizedDescription)"
    }
  }

  public func deleteDeploymentAccessToken(store: WorkbenchStore) {
    do {
      try deploymentTokenStore.deleteToken(
        for: store.activeProfile,
        scope: deploymentTokenScope(for: store.activeProfile)
      )
      refreshDeploymentTokenAvailability(store: store)
      deploymentStatusMessage = "\(deploymentProvider(for: store.activeProfile).displayName) 部署 Token 已删除。"
    } catch {
      deploymentStatusMessage = "部署 Token 删除失败：\(error.localizedDescription)"
    }
  }

  public func refreshDeploymentTokenAvailability(store: WorkbenchStore) {
    let profile = store.activeProfile
    let didMigrate = (try? migrateLegacyDeploymentTokenIfCompatible(for: profile)) == true
    deploymentTokenAvailability = (try? deploymentTokenStore.availability(
      for: profile,
      scope: deploymentTokenScope(for: profile)
    )) ?? KeychainTokenAvailability(hasToken: false)
    if didMigrate {
      deploymentStatusMessage = "已将旧共用 Token 迁移为 \(deploymentProvider(for: profile).displayName) 的部署 Token。"
    }
  }

  private func hasDeploymentToken(for profile: SiteProfile) -> Bool {
    (try? deploymentTokenStore.availability(
      for: profile,
      scope: deploymentTokenScope(for: profile)
    ).hasToken) == true
  }

  private func deploymentAccessToken(for profile: SiteProfile) throws -> String? {
    try deploymentTokenStore.token(for: profile, scope: deploymentTokenScope(for: profile))
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

  private func migrateLegacyDeploymentTokenIfCompatible(for profile: SiteProfile) throws -> Bool {
    let provider = deploymentProvider(for: profile)
    let isCompatibleLegacyCredential: Bool
    switch (provider, profile.repositoryProvider) {
    case (.githubPages, .github), (.gitlabPages, .gitlab):
      isCompatibleLegacyCredential = true
    default:
      isCompatibleLegacyCredential = false
    }
    guard isCompatibleLegacyCredential,
          try deploymentTokenStore.token(for: profile, scope: deploymentTokenScope(for: profile)) == nil,
          let legacyToken = try legacyRepositoryTokenStore.token(for: profile) else {
      return false
    }
    try deploymentTokenStore.saveToken(legacyToken, for: profile, scope: deploymentTokenScope(for: profile))
    return true
  }

  private func deploymentPollingMessage(
    checkedCount: Int,
    checkedRecords: [DeploymentPollingRecordSummary]
  ) -> String {
    guard checkedCount > 0 else {
      return "部署轮询已运行，但没有成功取得部署状态。"
    }

    let successCount = checkedRecords.filter(\.isResolvedSuccess).count
    let runningCount = checkedRecords.filter { $0.level == .running }.count
    let failedCount = checkedRecords.filter { $0.level == .failed }.count
    let unknownCount = checkedRecords.filter { $0.level == .unknown }.count
    let remoteRecoveryCount = checkedRecords.filter(\.isPendingRemoteRecovery).count
    var parts = ["正常 \(successCount)", "部署中 \(runningCount)"]
    if remoteRecoveryCount > 0 {
      parts.append("远端恢复待确认 \(remoteRecoveryCount)")
    }
    if failedCount > 0 {
      parts.append("失败 \(failedCount)")
    }
    if unknownCount > 0 {
      parts.append("未知 \(unknownCount)")
    }
    return "部署轮询已检查 \(checkedCount) 条待部署记录：\(parts.joined(separator: "，"))。"
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
