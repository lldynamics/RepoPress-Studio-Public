import Combine
import Foundation

/// Observation boundary for the Settings window. The window still uses the
/// root store for commands and bindings, but it only redraws for values that
/// can change a settings page or its profile header.
@MainActor
public final class WorkbenchSettingsFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  private struct DraftCountSignature: Equatable {
    let id: UUID
    let siteProfileID: UUID
    let isGeneralDraft: Bool
  }

  init(store: WorkbenchStore) {
    self.store = store

    observe(store.publishingStore.$profiles)
    observe(store.publishingStore.$activeProfileID)
    observe(
      store.publishingStore.$drafts
        .map { drafts in
          drafts.map {
            DraftCountSignature(
              id: $0.id,
              siteProfileID: $0.siteProfileID,
              isGeneralDraft: $0.isGeneralDraft
            )
          }
        }
        .removeDuplicates()
    )
    observe(store.publishingStore.$recentlyDeletedProfile)
    observe(store.publishingStore.$automaticallyRefreshPreflightOnEdit)

    observe(store.repositoryStore.$repositoryTokenAvailability)
    observe(store.repositoryStore.$remoteRepositoryAccessCheck)
    observe(store.repositoryStore.$isRemoteRepositoryChecking)
    observe(store.repositoryStore.$isRemoteRepositoryPublishing)
    observe(store.publishingStore.publishSession.$publishActionFeedback)

    observe(store.deploymentStore.$deploymentTokenAvailability)
    observe(store.deploymentStore.$deploymentStatusMessage)
    observe(store.$siteAnalyticsTokenAvailability)
    observe(store.$siteAnalyticsMessage)

    observe(store.$aiConnectionProfiles)
    observe(store.aiWorkspaceStore.$aiTokenAvailability)
    observe(store.aiWorkspaceStore.$isAIActionRunning)
    observe(store.aiWorkspaceStore.$aiActionMessage)

    observe(store.privacyProtectionStore.$privacySettings)
    observe(store.privacyProtectionStore.$isQuickHideActive)
  }

  public var canUseProtectedWorkbench: Bool {
    store.canUseProtectedWorkbench
  }

  public var isQuickHideActive: Bool {
    store.isQuickHideActive
  }

  private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}
