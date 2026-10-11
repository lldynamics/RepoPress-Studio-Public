import AppKit
import Combine
import Foundation
import PublishingWorkbenchCore
import SwiftUI

/// One window's current-article publishing work. Shared store operations may
/// finish after cancellation; only this owner can deliver their UI result.
@MainActor
final class WorkspaceArticlePublishSession: ObservableObject {
  struct Context: Equatable {
    let windowID: UUID
    let draftID: UUID
    let profileID: UUID
  }

  enum PreparationResult {
    case confirmation(SinglePublishReviewSnapshot)
    case drawer
  }

  enum Phase {
    case idle
    case preparing
    case publishing
  }

  @Published private(set) var phase = Phase.idle
  @Published var pendingReview: SinglePublishReviewSnapshot?
  @Published private(set) var isRefreshingChecks = false
  private var operationTask: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var repairTask: Task<Void, Never>?
  private var repairGeneration: UInt64 = 0
  private var observedWindowID: UUID?
  private var contextObservations: Set<AnyCancellable> = []
  private weak var presentingWindow: NSWindow?
  private var windowObservations: Set<AnyCancellable> = []
  private var hasActiveNativeOwner = false

  var isPreparing: Bool { phase == .preparing }
  var isPublishing: Bool { phase == .publishing }

  deinit {
    operationTask?.cancel()
    repairTask?.cancel()
  }

  /// Observe every transition, including A -> B -> A within one render cycle.
  /// Comparing only the context at completion would accept that old result.
  func observeWindow(
    _ window: WorkspaceWindowSession, profileChanges: AnyPublisher<UUID, Never>? = nil
  ) {
    guard observedWindowID != window.windowID else { return }
    contextObservations.removeAll()
    cancel()
    observedWindowID = window.windowID
    window.$selectedDraftID.dropFirst().sink { [weak self] _ in self?.cancel() }
      .store(in: &contextObservations)
    window.$selectedSection.dropFirst().sink { [weak self] _ in self?.cancel() }
      .store(in: &contextObservations)
    window.$isKeyWindow.dropFirst().sink { [weak self] _ in
      guard let self else { return }
      if self.presentingWindow == nil {
        self.cancel()
      } else {
        self.updateNativeOwnerActivity(self.ownsCurrentKeyWindow)
      }
    }
    .store(in: &contextObservations)
    window.$windowID.dropFirst().sink { [weak self] _ in self?.cancel() }
      .store(in: &contextObservations)
    profileChanges?.removeDuplicates().dropFirst().sink { [weak self] _ in self?.cancel() }
      .store(in: &contextObservations)
  }

  var ownsCurrentKeyWindow: Bool {
    NSApplication.shared.isActive
      && Self.isOwnedWindow(NSApplication.shared.keyWindow, owner: presentingWindow)
  }

  static func isOwnedWindow(_ candidate: NSWindow?, owner: NSWindow?) -> Bool {
    guard let candidate, let owner else { return false }
    return candidate === owner || candidate.sheetParent === owner
  }

  func setPresentingWindow(_ window: NSWindow?) {
    guard presentingWindow !== window else { return }
    windowObservations.removeAll()
    cancel()
    presentingWindow = window
    hasActiveNativeOwner = ownsCurrentKeyWindow
    guard window != nil else { return }
    NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
      .sink { [weak self] notification in
        guard let self else { return }
        self.updateNativeOwnerActivity(
          Self.isOwnedWindow(notification.object as? NSWindow, owner: self.presentingWindow))
      }.store(in: &windowObservations)
    NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
      .sink { [weak self] _ in self?.updateNativeOwnerActivity(false) }
      .store(in: &windowObservations)
  }

  private func updateNativeOwnerActivity(_ isActive: Bool) {
    guard hasActiveNativeOwner != isActive else { return }
    hasActiveNativeOwner = isActive
    cancel()
  }

  func context(
    window: WorkspaceWindowSession, store: WorkbenchStore, requiresWriting: Bool
  ) -> Context? {
    guard !requiresWriting || window.selectedSection == .writing,
      window.isKeyWindow || ownsCurrentKeyWindow,
      let draftID = window.selectedDraftID, store.draft(for: draftID) != nil
    else { return nil }
    return .init(windowID: window.windowID, draftID: draftID, profileID: store.activeProfileID)
  }

  func prepare(
    context: Context, store: WorkbenchStore,
    currentContext: @escaping @MainActor () -> Context?,
    onResult: @escaping @MainActor (PreparationResult) -> Void
  ) {
    prepare(
      context: context, currentContext: currentContext,
      operation: {
        await Self.prepareReview(
          store: store, draftID: context.draftID, profileID: context.profileID)
      }, onResult: onResult)
  }

  func publish(
    context: Context, review: SinglePublishReviewSnapshot, store: WorkbenchStore,
    currentContext: @escaping @MainActor () -> Context?,
    onResult: @escaping @MainActor (PublishDrawerDirectArticleResult?) -> Void
  ) {
    publish(
      context: context, review: review, currentContext: currentContext,
      operation: {
        await PublishDrawerDirectArticlePublisher.publish(store: store, review: review)
      },
      onResult: onResult)
  }

  @discardableResult
  func prepare(
    context: Context,
    currentContext: @escaping @MainActor () -> Context?,
    operation: @escaping @MainActor () async -> PreparationResult,
    onResult: @escaping @MainActor (PreparationResult) -> Void
  ) -> Bool {
    guard phase == .idle, currentContext() == context else { return false }
    generation &+= 1
    let operationGeneration = generation
    pendingReview = nil
    phase = .preparing
    operationTask = Task { @MainActor [weak self] in
      guard !Task.isCancelled, self?.generation == operationGeneration else { return }
      guard currentContext() == context else {
        self?.cancel()
        return
      }
      let result = await operation()
      guard let self, self.generation == operationGeneration else { return }
      self.operationTask = nil
      self.phase = .idle
      guard !Task.isCancelled, currentContext() == context else { return }
      if case .confirmation(let review) = result {
        self.pendingReview = review
      }
      onResult(result)
    }
    return true
  }

  @discardableResult
  func publish(
    context: Context,
    review: SinglePublishReviewSnapshot,
    currentContext: @escaping @MainActor () -> Context?,
    operation: @escaping @MainActor () async -> PublishDrawerDirectArticleResult?,
    onResult: @escaping @MainActor (PublishDrawerDirectArticleResult?) -> Void
  ) -> Bool {
    guard phase == .idle,
      currentContext() == context,
      review.draft.id == context.draftID,
      review.expectation.target.profileID == context.profileID
    else { return false }
    generation &+= 1
    let operationGeneration = generation
    pendingReview = nil
    phase = .publishing
    operationTask = Task { @MainActor [weak self] in
      guard !Task.isCancelled, self?.generation == operationGeneration else { return }
      guard currentContext() == context else {
        self?.cancel()
        return
      }
      let result = await operation()
      guard let self, self.generation == operationGeneration else { return }
      self.operationTask = nil
      self.phase = .idle
      guard !Task.isCancelled, currentContext() == context else { return }
      onResult(result)
    }
    return true
  }

  @discardableResult
  func refreshChecks(
    context: Context,
    repairID: UUID,
    currentContext: @escaping @MainActor () -> Context?,
    currentRepairID: @escaping @MainActor () -> UUID?,
    operation: @escaping @MainActor () async -> Void,
    onResult: @escaping @MainActor () -> Void
  ) -> Bool {
    guard !isRefreshingChecks,
      currentContext() == context,
      currentRepairID() == repairID
    else { return false }
    repairGeneration &+= 1
    let refreshGeneration = repairGeneration
    isRefreshingChecks = true
    repairTask = Task { @MainActor [weak self] in
      guard !Task.isCancelled, self?.repairGeneration == refreshGeneration else { return }
      guard currentContext() == context, currentRepairID() == repairID else {
        self?.cancelRepairRefresh()
        return
      }
      await operation()
      guard let self, self.repairGeneration == refreshGeneration else { return }
      self.repairTask = nil
      self.isRefreshingChecks = false
      guard !Task.isCancelled,
        currentContext() == context,
        currentRepairID() == repairID
      else { return }
      onResult()
    }
    return true
  }

  func cancelRepairRefresh() {
    repairGeneration &+= 1
    repairTask?.cancel()
    repairTask = nil
    isRefreshingChecks = false
  }

  func cancel() {
    cancelRepairRefresh()
    generation &+= 1
    operationTask?.cancel()
    operationTask = nil
    pendingReview = nil
    phase = .idle
  }

  func waitUntilIdle() async {
    let operation = operationTask
    let repair = repairTask
    await operation?.value
    await repair?.value
  }

  static func prepareReview(
    store: WorkbenchStore,
    draftID: UUID,
    profileID: UUID
  ) async -> PreparationResult {
    let prepared = await store.prepareSelectedDraftOnlinePublish(draftID: draftID)
    guard !Task.isCancelled, store.activeProfileID == profileID,
      prepared,
      store.publishDrawerFeedback?.status != .warning,
      store.publishDrawerFeedback?.status != .failure,
      let snapshot = store.cachedDraftPublishPreviewSnapshot(for: draftID),
      let draft = store.draft(for: draftID),
      SingleArticlePublishFastPathPolicy.qualifies(
        snapshot, draftID: draftID, profileID: profileID
      )
    else { return .drawer }
    do {
      return .confirmation(
        try SinglePublishReviewSnapshot(
          draft: draft, profile: store.activeProfile, snapshot: snapshot
        )
      )
    } catch {
      return .drawer
    }
  }
}

/// A narrow bridge for the window that actually hosts this publishing owner.
struct WorkspaceArticlePublishWindowBridge: NSViewRepresentable {
  let session: WorkspaceArticlePublishSession

  func makeNSView(context: NSViewRepresentableContext<Self>) -> WindowReferenceView {
    let view = WindowReferenceView()
    view.session = session
    return view
  }

  func updateNSView(_ view: WindowReferenceView, context: NSViewRepresentableContext<Self>) {
    view.session = session
    view.scheduleWindowBinding()
  }

  final class WindowReferenceView: NSView {
    weak var session: WorkspaceArticlePublishSession?
    private var bindingTask: Task<Void, Never>?

    deinit { bindingTask?.cancel() }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      scheduleWindowBinding()
    }

    func scheduleWindowBinding() {
      bindingTask?.cancel()
      // Binding may cancel a published phase. Deliver it after SwiftUI's
      // native-view update, using the window that still owns this view.
      bindingTask = Task { @MainActor [weak self] in
        await MainRunLoopUpdateDeferral.waitForNextDefaultModeCycle()
        guard !Task.isCancelled, let self else { return }
        self.bindingTask = nil
        self.session?.setPresentingWindow(self.window)
      }
    }
  }
}
