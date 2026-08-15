import Combine
import Foundation

@MainActor
public final class WorkbenchShellFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()
  private var isChangeNotificationScheduled = false

  init(store: WorkbenchStore) {
    self.store = store
    observe(store.publishingStore.$profiles)
    observe(store.publishingStore.$activeProfileID)
    observe(store.publishingStore.$selectedDraftID)
    observe(store.publishingStore.$selectedSection)
    observe(store.publishingStore.$isInspectorPresented)
    observe(store.privacyProtectionStore.$isQuickHideActive)
    observe(store.repositoryStore.$repositoryScanState)
    observe(store.persistenceStore.$recoveryMessage)
    observe(store.persistenceStore.$isRecoveryWriteProtected)
  }

  public var activeProfileName: String {
    store.activeProfile.name
  }

  public var publishingProfiles: [SiteProfile] {
    store.publishingProfiles
  }

  public var activeProfile: SiteProfile {
    store.activeProfile
  }

  public var activeProfileID: UUID {
    store.activeProfileID
  }

  public var selectedDraftID: UUID? {
    store.selectedDraftID
  }

  public var selectedSection: WorkspaceSection {
    store.selectedSection
  }

  public var isInspectorPresented: Bool {
    store.isInspectorPresented
  }

  public var isQuickHideActive: Bool {
    store.isQuickHideActive
  }

  public var canUseProtectedWorkbench: Bool {
    !isQuickHideActive
  }

  public var isRepositoryScanning: Bool {
    store.repositoryScanState.isScanning
  }

  public var persistenceRecoveryMessage: String? {
    store.persistenceRecoveryMessage
  }

  public var isPersistenceRecoveryWriteProtected: Bool {
    store.isPersistenceRecoveryWriteProtected
  }

  public func selectSection(_ section: WorkspaceSection) {
    store.selectSection(section)
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

    // @Published emits before the source property is committed. Register both
    // normal and AppKit event-tracking modes so accessibility clicks cannot
    // starve the deferred invalidation.
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
