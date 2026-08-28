import Combine
import Foundation

/// Observation boundary for repository and deployment automation settings.
///
/// The facade deliberately observes only the two setting values rendered by
/// the token settings page. AI, maintenance, publishing progress, and other
/// workspace activity therefore cannot invalidate that settings surface.
@MainActor
public final class WorkbenchAutomationSettingsFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  public init(store: WorkbenchStore) {
    self.store = store

    observe(store.repositoryStore.$repositoryAutoSyncSettings)
    observe(store.deploymentStore.$deploymentPollingSettings)
  }

  public var repositoryAutoSyncSettings: RepositoryAutoSyncSettings {
    store.repositoryAutoSyncSettings
  }

  public var deploymentPollingSettings: DeploymentPollingSettings {
    store.deploymentPollingSettings
  }

  public func updateRepositoryAutoSyncSettings(_ settings: RepositoryAutoSyncSettings) {
    store.updateRepositoryAutoSyncSettings(settings)
  }

  public func updateDeploymentPollingSettings(_ settings: DeploymentPollingSettings) {
    store.updateDeploymentPollingSettings(settings)
  }

  private func observe<P: Publisher>(_ publisher: P)
  where P.Failure == Never, P.Output: Equatable {
    publisher
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}
