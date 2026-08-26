import Combine
import Foundation

/// Compatibility facade for older sidebar call sites. The actual list
/// observation boundary is the stable `WorkbenchStore.draftList` child store;
/// this adapter forwards that child only. The image refresh token remains a
/// read-only compatibility getter; image workbench updates are observed by
/// their own leaf facade instead of invalidating the list adapter.
@MainActor
public final class WorkbenchDraftListFeatureFacade: ObservableObject {
  private let listStore: DraftListStore
  private var cancellables = Set<AnyCancellable>()

  public init(store: WorkbenchStore) {
    listStore = store.draftList
    listStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }

  public var presentationRevision: UInt64 { listStore.presentationRevision }
  public var taskQueueStateVersion: Int { listStore.taskQueueStateVersion }
  public var imageInputRevision: UInt64 { listStore.imageInputRevision }
  public var selectedDraftID: UUID? { listStore.selectedDraftID }
  public var contentScope: DraftListContentScope { listStore.contentScope }
  public var repositoryReport: RepositoryScanReport? { listStore.repositoryReport }
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

/// Observation boundary for the metadata summary action. The summary button
/// only depends on token availability, utility-action status/message, and the
/// selected site's AI configuration. Chat streaming, image workbench state,
/// and site-maintenance refreshes stay outside this boundary.
@MainActor
public final class WorkbenchMetadataSummaryFeatureFacade: ObservableObject {
  private struct AIConfigurationProjection: Equatable {
    let id: UUID
    let connectionProfileID: UUID?
    let config: AIProviderConfig
  }

  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  public init(store: WorkbenchStore) {
    self.store = store
    observe(store.aiWorkspaceStore.$aiTokenAvailability)
    observe(store.aiWorkspaceStore.$isAIActionRunning)
    observe(store.aiWorkspaceStore.$aiActionMessage)
    observe(
      store.$aiConnectionProfiles.map { profiles in
        profiles.map {
          AIConfigurationProjection(
            id: $0.id,
            connectionProfileID: nil,
            config: $0.config
          )
        }
      }
    )
    observe(
      store.publishingStore.$profiles.map { profiles in
        profiles.map {
          AIConfigurationProjection(
            id: $0.id,
            connectionProfileID: $0.aiConnectionProfileID,
            config: $0.aiProviderConfig
          )
        }
      }
    )
    observe(store.publishingStore.$activeProfileID)
  }

  public var tokenAvailability: KeychainTokenAvailability {
    store.aiTokenAvailability
  }

  public var isActionRunning: Bool {
    store.isAIActionRunning
  }

  public var actionMessage: String? {
    store.aiActionMessage
  }

  public func providerConfig(for profile: SiteProfile) -> AIProviderConfig {
    store.aiProviderConfig(for: profile)
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
