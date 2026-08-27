import Combine
import Foundation

/// The exact shared state that can change the root workbench presentation.
///
/// Profile menus, repository progress, editor typing, RSS updates, and AI
/// streaming remain on their feature facades so they cannot invalidate the
/// complete `ContentView` hierarchy.
@MainActor
public final class WorkbenchRootPresentationFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()
  private var isChangeNotificationScheduled = false

  init(store: WorkbenchStore) {
    self.store = store
    observe(store.publishingStore.$selectedDraftID)
    observe(store.publishingStore.$selectedSection)
    observe(store.publishingStore.$isInspectorPresented)
    observe(store.privacyProtectionStore.$isQuickHideActive)
    observe(store.persistenceStore.$recoveryMessage)
    observe(store.persistenceStore.$isRecoveryWriteProtected)
    observe(store.aiWorkspaceStore.$isAIPublishingAssistantPresented)
  }

  public var selectedDraftID: UUID? { store.selectedDraftID }
  public var selectedSection: WorkspaceSection { store.selectedSection }
  public var isInspectorPresented: Bool { store.isInspectorPresented }
  public var isQuickHideActive: Bool { store.isQuickHideActive }
  public var canUseProtectedWorkbench: Bool { !isQuickHideActive }
  public var persistenceRecoveryMessage: String? { store.persistenceRecoveryMessage }
  public var isPersistenceRecoveryWriteProtected: Bool {
    store.isPersistenceRecoveryWriteProtected
  }
  public var isAssistantPresented: Bool { store.isAIPublishingAssistantPresented }

  public func hideAssistant() {
    store.hideAIPublishingAssistant()
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

    // Source @Published values emit from willSet. Publish after they commit,
    // including while AppKit is tracking a resize or accessibility event.
    RunLoop.main.perform(inModes: [
      .default,
      RunLoop.Mode("NSEventTrackingRunLoopMode"),
    ]) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.isChangeNotificationScheduled = false
        self.objectWillChange.send()
      }
    }
  }
}
