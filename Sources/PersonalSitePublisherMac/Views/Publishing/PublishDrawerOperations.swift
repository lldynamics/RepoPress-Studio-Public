import PublishingGitCore
import PublishingWorkbenchCore
import SwiftUI

@MainActor
final class PublishDrawerOperationController: ObservableObject {
  @Published private(set) var isRunning = false

  private var operationTask: Task<Void, Never>?
  private var operationID = UUID()
  /// The section an operation may restore, valid only for the ownership
  /// period in which it was claimed.
  struct SharedNavigationClaim {
    fileprivate let section: WorkspaceSection
    fileprivate let generation: Int
  }

  /// A remote publish may outlive its panel. Its completion may only move the
  /// shared section if the panel stayed shown in the key window since the
  /// operation began; losing that once revokes the claim, even if the panel
  /// is shown again before the operation finishes.
  private(set) var ownsSharedNavigation = true
  private var navigationGeneration = 0

  func setOwnsSharedNavigation(_ owns: Bool) {
    guard owns != ownsSharedNavigation else { return }
    ownsSharedNavigation = owns
    navigationGeneration &+= 1
  }

  func claimSharedNavigation(
    from publishing: WorkbenchPublishingFeatureFacade
  ) -> SharedNavigationClaim {
    SharedNavigationClaim(section: publishing.selectedSection, generation: navigationGeneration)
  }

  func restoreSharedSection(
    _ claim: SharedNavigationClaim, using publishing: WorkbenchPublishingFeatureFacade
  ) {
    guard ownsSharedNavigation, claim.generation == navigationGeneration else { return }
    publishing.selectSection(claim.section)
  }

  @discardableResult
  func startIfIdle(_ operation: @escaping @MainActor () async -> Void) -> Bool {
    guard !isRunning else { return false }
    start(operation)
    return true
  }

  func start(_ operation: @escaping @MainActor () async -> Void) {
    cancel()
    let currentOperationID = UUID()
    operationID = currentOperationID
    isRunning = true
    operationTask = Task { @MainActor [weak self] in
      await operation()
      guard let self, self.operationID == currentOperationID else { return }
      self.operationTask = nil
      self.isRunning = false
    }
  }

  func cancel() {
    operationID = UUID()
    operationTask?.cancel()
    operationTask = nil
    isRunning = false
  }
}

/// Window-facing state of a publish panel. Completions may only move the
/// shared section while the panel is shown in the key window.
private struct PublishDrawerWindowState: ViewModifier {
  let controller: PublishDrawerOperationController
  let isActive: Bool
  @Environment(\.controlActiveState) private var controlActiveState

  func body(content: Content) -> some View {
    content
      .onChange(of: isActive, initial: true) { sync() }
      .onChange(of: controlActiveState) { sync() }
      .onDisappear { controller.setOwnsSharedNavigation(false) }
  }

  private func sync() {
    controller.setOwnsSharedNavigation(isActive && controlActiveState == .key)
  }
}

extension View {
  func publishDrawerWindowState(
    _ controller: PublishDrawerOperationController, isActive: Bool
  ) -> some View {
    modifier(PublishDrawerWindowState(controller: controller, isActive: isActive))
  }
}

struct PublishDrawerDirectArticleResult {
  let recordID: UUID?
}

@MainActor
enum PublishDrawerDirectArticlePublisher {
  static func publish(
    store: WorkbenchStore, review: SinglePublishReviewSnapshot
  ) async -> PublishDrawerDirectArticleResult? {
    let previousIDs = Set(store.releaseRecords.map { $0.id })
    let profileID = review.expectation.target.profileID
    guard store.publishing.focusDraft(review.draft.id) else { return nil }
    let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy(
      expectedReview: review.expectation
    )
    let recordID = PublishResultRecordSelection.recordID(
      result: result,
      records: store.releaseRecords,
      previousRecordIDs: previousIDs,
      profileID: profileID,
      draftIDs: [review.draft.id]
    )
    _ = await store.refreshRepositoryStateForPublishing()
    store.publishing.refreshPublishPreviewInBackground(for: review.draft)
    store.refreshBatchPublishPlanInBackground()
    return PublishDrawerDirectArticleResult(recordID: recordID)
  }
}
