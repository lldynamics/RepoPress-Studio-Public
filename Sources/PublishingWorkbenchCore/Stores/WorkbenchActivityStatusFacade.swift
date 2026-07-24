import Combine
import Foundation

@MainActor
public final class WorkbenchActivityStatusFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  init(store: WorkbenchStore) {
    self.store = store
    observe(store.privacyMonetizationStore.$isPrivacyLocked)
    observe(store.repositoryStore.$repositoryScanState)
    observe(store.repositoryStore.$isRemoteRepositoryPublishing)
    observe(store.aiWorkspaceStore.$isAIChatRunning)
    observe(store.deploymentStore.$isDeploymentStatusChecking)
    observe(store.persistenceStore.$lastSaveError)
    observe(store.persistenceStore.$status)
  }

  public var isPrivacyLocked: Bool { store.isPrivacyLocked }
  public var repositoryScanState: RepositoryScanState { store.repositoryScanState }
  public var isRemoteRepositoryPublishing: Bool { store.isRemoteRepositoryPublishing }
  public var isAIChatRunning: Bool { store.isAIChatRunning }
  public var isDeploymentStatusChecking: Bool { store.isDeploymentStatusChecking }
  public var lastSaveError: String? { store.lastSaveError }
  public var lastSaveStatus: String { store.lastSaveStatus }

  private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}
