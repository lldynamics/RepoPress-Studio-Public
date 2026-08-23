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
    let profiles = store.profiles.filter { $0.purpose == .publishing }
    var didRun = false
    for profile in profiles {
      // Both stores receive an explicit profile ID. The repository store uses
      // a non-importing background path for non-active profiles, while the
      // deployment store resolves credentials and release records from the
      // frozen profile without selecting it in the UI.
      didRun = await repositoryStore.tickRepositoryAutoSync(
        for: profile.id,
        store: store,
        now: now
      ) || didRun
      didRun = await deploymentStore.tickDeploymentPolling(
        for: profile.id,
        store: store,
        now: now
      ) || didRun
    }
    return didRun
  }

  func recordRemotePublish(_ result: RemoteRepositoryPublishResult, profileID: UUID) {
    repositoryStore.recordRemoteRepositoryPublishInAutoSync(result, for: profileID)
  }

  func shouldRefreshDeployment(after record: ReleaseRecord, store: WorkbenchStore) -> Bool {
    deploymentStore.shouldRefreshDeploymentStatusAfterRemoteOperation(record, store: store)
  }
}
