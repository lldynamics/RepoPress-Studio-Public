import Combine
import Foundation

/// Observation boundary for the publish badge in the workspace toolbar and
/// the Inspector's 发布检查 tab. Body edits reach it only through the
/// coalesced draft-scoped preflight notification; it does not follow AI
/// streams or unrelated repository operations.
@MainActor
public final class WorkbenchPublishStatusFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  init(store: WorkbenchStore) {
    self.store = store
    store.configureDraftPreflightInputObservationIfNeeded()

    observe(store.publishingStore.$profiles)
    observe(store.publishingStore.$activeProfileID)
    observe(store.publishingStore.$selectedDraftID)
    observe(store.publishingStore.$draftListContentScope)
    observe(store.publishingStore.publishSession.$preflightIssues)
    observe(store.publishingStore.publishSession.$localPublishReadiness)
    observe(store.publishingStore.publishSession.$releaseRecords)
    observe(store.repositoryStore.$repositoryReport)
    observe(store.deploymentStore.$deploymentStatusSnapshots)
    // Inputs of the publish badge besides preflight: the article's images,
    // social card, SEO-relevant metadata and publishing account. These are
    // the same inputs the publish panel lists under 需要处理.
    observe(store.imageStore.$backgroundImageReport)
    observe(store.imageStore.$imageReportLoadingDraftID)
    observe(store.aiWorkspaceStore.$seoSocialPreviewSnapshots)
    observe(store.repositoryStore.$repositoryTokenAvailability)
    observe(store.publishingStore.publishSession.$remotePublishPreviewSnapshot)
    store.publishingStore.publishSession.draftPublishStatusDidChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    // Use the new array supplied by the publisher rather than reading the
    // store during @Published's willSet phase. Only the selected draft's list
    // metadata can invalidate this toolbar; another row changing must not.
    observe(
      Publishers.CombineLatest(
        store.publishingStore.documents.$drafts,
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
