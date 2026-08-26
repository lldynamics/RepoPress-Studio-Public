import Foundation

extension WorkbenchStore {
  public func deploymentStatusSnapshot(for record: ReleaseRecord) -> DeploymentStatusSnapshot? {
    deploymentStore.deploymentStatusSnapshot(for: record)
  }

  public func deploymentStatusHistory(
    for record: ReleaseRecord,
    limit: Int = 6
  ) -> [DeploymentStatusSnapshot] {
    deploymentStore.deploymentStatusHistory(for: record, limit: limit)
  }

  public func remoteRollbackDraft(for record: ReleaseRecord) -> RemoteRepositoryRollbackDraft? {
    deploymentStore.remoteRollbackDraft(for: record)
  }

  public func remoteReviewWithdrawalDraft(for record: ReleaseRecord) -> RemoteRepositoryReviewWithdrawalDraft? {
    deploymentStore.remoteReviewWithdrawalDraft(for: record)
  }

  public func deploymentStatusReadiness(for profile: SiteProfile) -> DeploymentStatusProviderReadiness {
    deploymentStore.deploymentStatusReadiness(
      for: profile,
      tokenAvailability: deploymentTokenAvailability
    )
  }

  @discardableResult
  public func saveDeploymentAccessToken(_ token: String) -> Bool {
    deploymentStore.saveDeploymentAccessToken(token, store: self)
  }

  public func deleteDeploymentAccessToken() {
    deploymentStore.deleteDeploymentAccessToken(store: self)
  }

  public func refreshDeploymentTokenAvailability() {
    deploymentStore.refreshDeploymentTokenAvailability(store: self)
  }

  public func deploymentStatusReadiness(for record: ReleaseRecord) -> DeploymentStatusProviderReadiness {
    deploymentStore.deploymentStatusReadiness(for: record, store: self)
  }

  public var deploymentPollingEligibleRecords: [ReleaseRecord] {
    deploymentStore.deploymentPollingEligibleRecords(store: self)
  }

  public func updateDeploymentPollingSettings(_ settings: DeploymentPollingSettings) {
    deploymentStore.updateDeploymentPollingSettings(settings, store: self)
  }

  public func updateDeploymentPollingSettings(
    _ settings: DeploymentPollingSettings,
    for profileID: UUID
  ) {
    deploymentStore.updateDeploymentPollingSettings(settings, for: profileID, store: self)
  }

  @discardableResult
  public func tickDeploymentPolling(now: Date = Date()) async -> Bool {
    await deploymentStore.tickDeploymentPolling(store: self, now: now)
  }

  @discardableResult
  public func runDeploymentPolling(now: Date = Date()) async -> Bool {
    await deploymentStore.runDeploymentPolling(store: self, now: now)
  }

  public func canCheckDeploymentStatus(for record: ReleaseRecord) -> Bool {
    deploymentStore.canCheckDeploymentStatus(for: record, store: self)
  }

  @discardableResult
  public func refreshDeploymentStatus(
    for record: ReleaseRecord,
    updatesMessage: Bool = true
  ) async -> DeploymentStatusSnapshot? {
    await deploymentStore.refreshDeploymentStatus(for: record, store: self, updatesMessage: updatesMessage)
  }

  public var releaseLedger: ReleaseLedger {
    deploymentStore.releaseLedger(store: self)
  }

  public var activeProfileReleaseRecords: [ReleaseRecord] {
    deploymentStore.activeProfileReleaseRecords(store: self)
  }

  public var activeProfileDeploymentStatusSnapshots: [UUID: DeploymentStatusSnapshot] {
    deploymentStore.activeProfileDeploymentStatusSnapshots(store: self)
  }

  public var activeProfileReleaseLedger: ReleaseLedger {
    deploymentStore.activeProfileReleaseLedger(store: self)
  }

  public func releaseLedgerEntry(for record: ReleaseRecord) -> ReleaseLedgerEntry {
    deploymentStore.releaseLedgerEntry(for: record)
  }

  public var releaseRecoveryVerificationDraftMarkdown: String {
    deploymentStore.releaseRecoveryVerificationDraftMarkdown(store: self)
  }
}
