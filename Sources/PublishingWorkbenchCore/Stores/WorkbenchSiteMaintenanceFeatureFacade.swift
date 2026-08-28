import Combine
import Foundation

/// Observation boundary for the site-maintenance detail page. Report refresh,
/// release history and deployment status are the only inputs that can alter
/// this view; editor, AI and unrelated repository changes stay outside it.
@MainActor
public final class WorkbenchSiteMaintenanceFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  init(store: WorkbenchStore) {
    self.store = store
    observe(store.siteMaintenanceStore.$snapshot)
    observe(store.siteMaintenanceStore.$snapshotVersion)
    observe(store.siteMaintenanceStore.$isRefreshing)
    observe(store.siteMaintenanceStore.$refreshErrorMessage)
    observe(store.publishingStore.$profiles)
    observe(store.publishingStore.$activeProfileID)
    observe(store.publishingStore.publishSession.$releaseRecords)
    observe(store.deploymentStore.$deploymentStatusSnapshots)
    observe(store.deploymentStore.$isDeploymentStatusChecking)
    observe(store.deploymentStore.$deploymentStatusMessage)
    observe(store.aiWorkspaceStore.$isAIChatRunning)
  }

  public var snapshot: SiteMaintenanceSnapshot? {
    store.siteMaintenanceSnapshot
  }

  public var isStale: Bool {
    store.isSiteMaintenanceSnapshotStale
  }

  public var isRefreshing: Bool {
    store.isSiteMaintenanceSnapshotRefreshing
  }

  public var errorMessage: String? {
    store.siteMaintenanceSnapshotErrorMessage
  }

  public var isAIChatRunning: Bool {
    store.isAIChatRunning
  }

  public var latestRelease: ReleaseRecord? {
    store.activeProfileReleaseRecords.first
  }

  public var isDeploymentStatusChecking: Bool {
    store.isDeploymentStatusChecking
  }

  public var deploymentStatusMessage: String? {
    store.deploymentStatusMessage
  }

  public func deploymentStatusSnapshot(for record: ReleaseRecord) -> DeploymentStatusSnapshot? {
    store.deploymentStatusSnapshot(for: record)
  }

  public func canCheckDeploymentStatus(for record: ReleaseRecord) -> Bool {
    store.canCheckDeploymentStatus(for: record)
  }

  public func deploymentStatusReadiness(for record: ReleaseRecord) -> DeploymentStatusProviderReadiness {
    store.deploymentStatusReadiness(for: record)
  }

  private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}
