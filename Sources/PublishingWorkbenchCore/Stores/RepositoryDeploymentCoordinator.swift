import Foundation

/// Coordinates the two operational stores without making either own the other.
/// Feature stores retain their state; this type owns only cross-domain ordering.
@MainActor
final class RepositoryDeploymentCoordinator {
  private let repositoryStore: RepositoryStore
  private let deploymentStore: DeploymentStore

  init(repositoryStore: RepositoryStore, deploymentStore: DeploymentStore) {
    self.repositoryStore = repositoryStore
    self.deploymentStore = deploymentStore
  }

  func refreshTokenAvailability(store: WorkbenchStore) {
    repositoryStore.refreshRepositoryTokenAvailability(store: store)
    deploymentStore.refreshDeploymentTokenAvailability(store: store)
  }

  @discardableResult
  func tickOperationalPolling(store: WorkbenchStore, now: Date) async -> Bool {
    let repositoryDidRun = repositoryStore.tickRepositoryAutoSync(store: store, now: now)
    let deploymentDidRun = await deploymentStore.tickDeploymentPolling(store: store, now: now)
    return repositoryDidRun || deploymentDidRun
  }

  func recordRemotePublish(_ result: RemoteRepositoryPublishResult) {
    repositoryStore.recordRemoteRepositoryPublishInAutoSync(result)
  }

  func shouldRefreshDeployment(after record: ReleaseRecord, store: WorkbenchStore) -> Bool {
    deploymentStore.shouldRefreshDeploymentStatusAfterRemoteOperation(record, store: store)
  }
}
