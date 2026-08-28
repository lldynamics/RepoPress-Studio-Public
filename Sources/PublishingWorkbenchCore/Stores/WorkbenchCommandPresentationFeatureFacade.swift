import Combine
import Foundation

/// Observation boundary for the app's command menus. Publishing messages,
/// repository progress and token-by-token AI responses must not invalidate an
/// open menu; only state that changes command availability or presentation is
/// forwarded.
@MainActor
public final class WorkbenchCommandPresentationFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()
  private var isChangeNotificationScheduled = false

  init(store: WorkbenchStore) {
    self.store = store
    observe(store.publishingStore.$selectedDraftID)
    observe(store.publishingStore.$selectedSection)
    observe(store.publishingStore.$isInspectorPresented)
    observe(store.privacyProtectionStore.$isQuickHideActive)
    observe(store.publishingStore.$draftNavigationHistory)
    observe(store.publishingStore.$drafts.map { $0.map(\.id) })
    observe(store.publishingStore.publishSession.$localSitePreviewRuntimeStatus.map(\.isRunning))
    observe(store.aiWorkspaceStore.$isAIPublishingAssistantPresented)
  }

  public var canUseProtectedWorkbench: Bool {
    !store.isQuickHideActive
  }

  public var isInspectorPresented: Bool {
    store.isInspectorPresented
  }

  public var isQuickHideActive: Bool {
    store.isQuickHideActive
  }

  public var selectedDraftID: UUID? {
    store.selectedDraftID
  }

  public var selectedSection: WorkspaceSection {
    store.selectedSection
  }

  public var isLocalSitePreviewRunning: Bool {
    store.localSitePreviewRuntimeStatus.isRunning
  }

  public var canNavigateBackwardInDraftHistory: Bool {
    store.canNavigateBackwardInDraftHistory
  }

  public var canNavigateForwardInDraftHistory: Bool {
    store.canNavigateForwardInDraftHistory
  }

  public var isAIAssistantPresented: Bool {
    store.isAIPublishingAssistantPresented
  }

  private func observe<P: Publisher>(_ publisher: P)
  where P.Failure == Never, P.Output: Equatable {
    publisher
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.scheduleChangeNotification() }
      .store(in: &cancellables)
  }

  private func scheduleChangeNotification() {
    guard !isChangeNotificationScheduled else { return }
    isChangeNotificationScheduled = true

    // Menu actions can synchronously update several observed values while an
    // AppKit tracking session is still unwinding. Deliver one invalidation in
    // the normal run-loop mode so SwiftUI never rebuilds command items inside
    // the menu-tracking mode.
    RunLoop.main.perform(inModes: [.default]) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.isChangeNotificationScheduled = false
        self.objectWillChange.send()
      }
    }
  }
}
