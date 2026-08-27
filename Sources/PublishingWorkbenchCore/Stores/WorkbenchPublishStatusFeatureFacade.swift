import Combine
import Foundation

/// Observation boundary for the compact publishing status control in the
/// workspace toolbar. It does not follow draft body buffers, AI streams or
/// unrelated repository operations.
@MainActor
public final class WorkbenchPublishStatusFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  init(store: WorkbenchStore) {
    self.store = store

    observe(store.publishingStore.$profiles)
    observe(store.publishingStore.$activeProfileID)
    observe(store.publishingStore.$selectedDraftID)
    observe(store.publishingStore.$draftListContentScope)
    observe(store.publishingStore.$preflightIssues)
    observe(store.publishingStore.$localPublishReadiness)
    observe(store.publishingStore.$releaseRecords)
    observe(store.repositoryStore.$repositoryReport)
    observe(store.deploymentStore.$deploymentStatusSnapshots)
    // Use the new array supplied by the publisher rather than reading the
    // store during @Published's willSet phase. Only the selected draft's list
    // metadata can invalidate this toolbar; another row changing must not.
    observe(
      Publishers.CombineLatest(
        store.publishingStore.$drafts,
        store.publishingStore.$selectedDraftID
      )
      .map { drafts, selectedDraftID in
        selectedDraftID.flatMap { selectedDraftID in
          drafts.first(where: { $0.id == selectedDraftID })?.listMetadataProjection
        }
      }
      .removeDuplicates()
    )
  }

  public var activeProfile: SiteProfile {
    store.activeProfile
  }

  public var repositoryReport: RepositoryScanReport? {
    store.repositoryReport
  }

  public var selectedDraftID: UUID? {
    store.selectedDraftID
  }

  public var preflightIssues: [PreflightIssue] {
    store.preflightIssues
  }

  public var localPublishReadiness: LocalPublishReadiness? {
    store.localPublishReadiness
  }

  public var activeProfileReleaseLedger: ReleaseLedger {
    store.activeProfileReleaseLedger
  }

  private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}
