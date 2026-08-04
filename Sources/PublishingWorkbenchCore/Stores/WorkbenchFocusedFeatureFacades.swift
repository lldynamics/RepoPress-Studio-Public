import Combine
import Foundation

/// Observation boundary for the Writing sidebar. It forwards only changes that
/// can alter draft rows, selection, task badges or repository status.
@MainActor
public final class WorkbenchDraftListFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  public init(store: WorkbenchStore) {
    self.store = store
    observe(store.$draftListPresentationRevision)
    observe(store.$draftTaskQueueStateVersion)
    observe(store.$imageWorkbenchInputRevision)
    observe(store.publishingStore.$selectedDraftID)
    observe(store.publishingStore.$draftListContentScope)
    observe(store.repositoryStore.$repositoryReport)
  }

  public var presentationRevision: UInt64 { store.draftListPresentationRevision }
  public var taskQueueStateVersion: Int { store.draftTaskQueueStateVersion }
  public var imageInputRevision: UInt64 { store.imageWorkbenchInputRevision }
  public var selectedDraftID: UUID? { store.selectedDraftID }
  public var contentScope: DraftListContentScope { store.draftListContentScope }
  public var repositoryReport: RepositoryScanReport? { store.repositoryReport }

  private func observe<P: Publisher>(_ publisher: P)
  where P.Failure == Never, P.Output: Equatable {
    publisher
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}

/// Observation boundary for the content-health page. Publishing progress,
/// editor typing details and AI streaming do not invalidate the full page.
@MainActor
public final class WorkbenchContentHealthFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  public init(store: WorkbenchStore) {
    self.store = store
    observe(store.$contentHealthSnapshotVersion)
  }

  public var snapshotVersion: Int { store.contentHealthSnapshotVersion }

  private func observe<P: Publisher>(_ publisher: P)
  where P.Failure == Never, P.Output: Equatable {
    publisher
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}
