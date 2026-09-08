import Combine
import Foundation

@MainActor
public final class WorkbenchPersistenceFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables: Set<AnyCancellable> = []

  init(store: WorkbenchStore) {
    self.store = store
    store.persistenceStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    store.$siteDraftFileSaveStates.sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    store.$siteDraftFileSaveFailures.sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    store.$isRetryingProjectFileWrites.sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }

  public var hasUnsavedChanges: Bool {
    store.hasUnsavedChanges
  }

  public var lastSaveError: String? {
    store.persistenceStore.lastSaveError
  }

  public var siteDraftFileSaveFailureGroups: [SiteDraftFileSaveFailureGroup] {
    store.siteDraftFileSaveFailureGroups
  }

  public var siteDraftFileSaveFailureSummary: String? {
    store.siteDraftFileSaveFailureSummary
  }

  public var isRetryingProjectFileWrites: Bool { store.isRetryingProjectFileWrites }

  public var isRecoveryWriteProtected: Bool {
    store.persistenceStore.isRecoveryWriteProtected
  }

  public var recoveryMessage: String? {
    store.persistenceStore.recoveryMessage
  }
}
