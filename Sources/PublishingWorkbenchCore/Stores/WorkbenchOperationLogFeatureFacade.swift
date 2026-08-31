import Combine
import Foundation

/// Narrow observation boundary for the activity-record window. Only inputs
/// that can change its privacy state, projection, filters, or status message
/// invalidate this facade; editor body updates and unrelated workbench state
/// stay outside the window's observation graph.
@MainActor
public final class WorkbenchOperationLogFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()
  @Published private var completedActionMessage: String?
  private var actionGeneration: UInt64 = 0

  init(store: WorkbenchStore) {
    self.store = store
    observe(store.privacyProtectionStore.$isQuickHideActive)
    observe(store.publishingStore.publishSession.$releaseRecords)
    observe(store.publishingStore.$maintenanceOperationRecords)
    observe(store.aiWorkspaceStore.$automationRunRecords)
    observe(store.aiWorkspaceStore.$aiMetadataApplicationRecords)
    observe(store.deploymentStore.$deploymentStatusSnapshots)
    observe(store.operationHistory.$document)
    observe(store.operationHistory.$lastErrorMessage)
    observe(store.operationHistory.$recoveryMessage)
    observe(store.publishingStore.$profiles)
    observe(store.draftList.presentationDidChange)
  }

  public var isQuickHideActive: Bool { store.isQuickHideActive }
  public var entries: [WorkbenchOperationLogEntry] { store.operationLogEntries }
  public var profiles: [SiteProfile] { store.profiles }
  public var retentionPolicy: WorkbenchOperationLogRetentionPolicy {
    store.operationLogRetentionPolicy
  }
  public var statusMessage: String? {
    store.operationLogStatusMessage ?? completedActionMessage
  }

  /// The projection changes immediately, but its completion message is held
  /// until the ledger has acknowledged the write.  A failed flush leaves the
  /// store-provided error visible instead of claiming success.
  public func setRetentionPolicy(_ policy: WorkbenchOperationLogRetentionPolicy) {
    guard policy != store.operationLogRetentionPolicy else { return }
    guard store.setOperationLogRetentionPolicy(policy) else { return }
    actionGeneration &+= 1
    let generation = actionGeneration
    completedActionMessage = nil
    Task { [weak self] in
      guard let self else { return }
      guard await store.flushOperationLogPersistence() != nil else { return }
      guard actionGeneration == generation else { return }
      completedActionMessage = CoreL10n.text("活动记录保留期限已保存。")
    }
  }

  /// Clears the in-memory projection optimistically while delaying the user
  /// facing completion acknowledgement until the clear watermark is durable.
  public func clear() {
    guard store.clearOperationLog() else { return }
    actionGeneration &+= 1
    let generation = actionGeneration
    completedActionMessage = nil
    Task { [weak self] in
      guard let self else { return }
      guard await store.flushOperationLogPersistence() != nil else { return }
      guard actionGeneration == generation else { return }
      completedActionMessage = CoreL10n.text("活动记录已清空。")
    }
  }

  public func dismissStatusMessage() {
    actionGeneration &+= 1
    completedActionMessage = nil
    store.dismissOperationLogStatusMessage()
  }

  public func selectSyncWorkspace() {
    store.selectSection(.sync)
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
