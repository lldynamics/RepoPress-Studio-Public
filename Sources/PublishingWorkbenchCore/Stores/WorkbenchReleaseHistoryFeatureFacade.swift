import Foundation

@MainActor
public final class WorkbenchReleaseHistoryFeatureFacade {
  private unowned let store: WorkbenchStore

  init(store: WorkbenchStore) {
    self.store = store
  }

  public var records: [ReleaseRecord] {
    store.releaseRecords
  }

  public var activeProfileRecords: [ReleaseRecord] {
    store.activeProfileReleaseRecords
  }

  public var ledger: ReleaseLedger {
    store.activeProfileReleaseLedger
  }

  public var isCheckingDeploymentStatus: Bool {
    store.isDeploymentStatusChecking
  }

  public var deploymentStatusMessage: String? {
    store.deploymentStatusMessage
  }

  public var deploymentWebhookHTTPReceiverState: DeploymentWebhookHTTPReceiverState {
    store.deploymentWebhookHTTPReceiverState
  }

  public var deploymentPollingSettings: DeploymentPollingSettings {
    store.deploymentPollingSettings
  }

  public var deploymentPollingState: DeploymentPollingState {
    store.deploymentPollingState
  }

  public func deploymentStatusSnapshot(for record: ReleaseRecord) -> DeploymentStatusSnapshot? {
    store.deploymentStatusSnapshot(for: record)
  }

  public func deploymentStatusHistory(for record: ReleaseRecord, limit: Int = 6) -> [DeploymentStatusSnapshot] {
    store.deploymentStatusHistory(for: record, limit: limit)
  }

  public func releaseLedgerEntry(for record: ReleaseRecord) -> ReleaseLedgerEntry {
    store.releaseLedgerEntry(for: record)
  }

  public func remoteRollbackDraft(for record: ReleaseRecord) -> RemoteRepositoryRollbackDraft? {
    store.remoteRollbackDraft(for: record)
  }

  public func remoteReviewWithdrawalDraft(for record: ReleaseRecord) -> RemoteRepositoryReviewWithdrawalDraft? {
    store.remoteReviewWithdrawalDraft(for: record)
  }

  public func receiveDeploymentWebhook(
    provider: DeploymentProvider,
    payloadText: String,
    for record: ReleaseRecord? = nil,
    receivedAt: Date = Date()
  ) -> DeploymentWebhookReceiveResult? {
    store.receiveDeploymentWebhook(
      provider: provider,
      payloadText: payloadText,
      for: record,
      receivedAt: receivedAt
    )
  }

  public func startDeploymentWebhookHTTPReceiver(port: UInt16 = 8787) {
    store.startDeploymentWebhookHTTPReceiver(port: port)
  }

  public func stopDeploymentWebhookHTTPReceiver() {
    store.stopDeploymentWebhookHTTPReceiver()
  }

  @discardableResult
  public func rollbackRemoteRelease(_ record: ReleaseRecord) async -> RemoteRepositoryRollbackResult? {
    await store.rollbackRemoteRelease(record)
  }
}
