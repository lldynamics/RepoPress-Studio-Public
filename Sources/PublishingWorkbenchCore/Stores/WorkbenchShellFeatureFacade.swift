import Combine
import Foundation

@MainActor
public final class WorkbenchShellFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  init(store: WorkbenchStore) {
    self.store = store
    observe(store.publishingStore.$profiles)
    observe(store.publishingStore.$activeProfileID)
    observe(store.publishingStore.$selectedDraftID)
    observe(store.publishingStore.$isInspectorPresented)
    observe(store.privacyMonetizationStore.$isPrivacyLocked)
    observe(store.repositoryStore.$repositoryScanState)
    observe(store.persistenceStore.$recoveryMessage)
  }

  public var activeProfileName: String {
    store.activeProfile.name
  }

  public var selectedDraftID: UUID? {
    store.selectedDraftID
  }

  public var isInspectorPresented: Bool {
    store.isInspectorPresented
  }

  public var isPrivacyLocked: Bool {
    store.isPrivacyLocked
  }

  public var canUseProtectedWorkbench: Bool {
    !isPrivacyLocked
  }

  public var isRepositoryScanning: Bool {
    store.repositoryScanState.isScanning
  }

  public var persistenceRecoveryMessage: String? {
    store.persistenceRecoveryMessage
  }

  private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}
