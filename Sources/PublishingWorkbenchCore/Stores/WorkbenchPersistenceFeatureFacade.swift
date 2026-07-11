import Combine
import Foundation

@MainActor
public final class WorkbenchPersistenceFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellable: AnyCancellable?

  init(store: WorkbenchStore) {
    self.store = store
    cancellable = store.persistenceStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
  }

  public var hasUnsavedChanges: Bool {
    store.hasUnsavedChanges
  }

  public var lastSaveStatus: String {
    store.lastSaveStatus
  }
}
