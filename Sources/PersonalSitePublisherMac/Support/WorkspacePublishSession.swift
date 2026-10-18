import Combine
import Foundation
import PublishingWorkbenchCore
import SwiftUI

/// One window's publishing work. There are exactly two actions: publish the
/// current article on its own, or publish every change of the site. Both
/// prepare a frozen Git review, wait for the user's confirmation, then commit
/// and push. Shared store operations may outlive a cancelled preparation;
/// only the operation that is still current can deliver its result here.
@MainActor
final class WorkspacePublishSession: ObservableObject {
  struct Context: Equatable {
    let windowID: UUID
    let profileID: UUID
    /// Set only while publishing one article: switching articles in this
    /// window invalidates that preparation, but not a site-wide one.
    let draftID: UUID?
  }

  enum Target: Equatable {
    case article(UUID)
    case all

    var draftID: UUID? {
      if case .article(let draftID) = self { return draftID }
      return nil
    }
  }

  struct Review: Identifiable {
    let id = UUID()
    let target: Target
    let title: String
    let confirmation: RepositoryWorktreePublishConfirmation
    /// A website draft is published by clearing its draft flag first.
    let clearedDraftFlag: Bool
  }

  struct Blockers: Identifiable {
    let id = UUID()
    let draftID: UUID
    let title: String
    let issues: [PreflightIssue]
  }

  struct Outcome: Identifiable {
    let id = UUID()
    let message: String
    let status: PublishActionMessageStatus
    let recordID: UUID?
    /// A failed Git step may have left a local commit that still needs a push.
    let offersPushRetry: Bool
  }

  enum Phase: Equatable {
    case idle
    case preparing(Target)
    case publishing(Target)
    case preparingPushRetry
    case pushingRetry
  }

  enum PreparationResult {
    case review(Review)
    case blockers(Blockers)
    case outcome(Outcome)
  }

  @Published private(set) var phase = Phase.idle
  @Published private(set) var pendingReview: Review?
  @Published private(set) var pendingPushRetry: RepositoryWorktreePushRetryConfirmation?
  @Published var pendingBlockers: Blockers?
  @Published var outcome: Outcome?
  @Published private(set) var isRefreshingChecks = false
  private var operationTask: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var repairTask: Task<Void, Never>?
  private var repairGeneration: UInt64 = 0
  private var observedWindowID: UUID?
  private var contextObservations: Set<AnyCancellable> = []
  private var draftFlagRestoration = PublishDraftFlagRestoration()
  /// Lets `cancel()` return a temporarily published draft to its draft state.
  private weak var flagRestorationStore: WorkbenchStore?

  var isBusy: Bool { phase != .idle }
  var presentsSheet: Bool {
    pendingReview != nil || pendingPushRetry != nil || pendingBlockers != nil || outcome != nil
  }
  var isPublishing: Bool {
    switch phase {
    case .publishing, .pushingRetry: true
    case .idle, .preparing, .preparingPushRetry: false
    }
  }

  var progressTitle: String? {
    switch phase {
    case .idle: nil
    case .preparing(.article): String(localized: "正在准备发布这篇文章…")
    case .preparing(.all): String(localized: "正在准备发布全部变更…")
    case .publishing: String(localized: "正在提交并推送…")
    case .preparingPushRetry: String(localized: "正在核对未完成的推送…")
    case .pushingRetry: String(localized: "正在重新推送…")
    }
  }

  deinit {
    operationTask?.cancel()
    repairTask?.cancel()
  }

  /// Switching article or site in this window cancels a preparation that no
  /// longer matches it. A commit and push in progress is never interrupted.
  func observeWindow(
    _ window: WorkspaceWindowSession, profileChanges: AnyPublisher<UUID, Never>? = nil
  ) {
    guard observedWindowID != window.windowID else { return }
    contextObservations.removeAll()
    cancel()
    observedWindowID = window.windowID
    window.$selectedDraftID.dropFirst().removeDuplicates().sink { [weak self] _ in
      self?.cancelArticleWork()
    }
    .store(in: &contextObservations)
    window.$windowID.dropFirst().sink { [weak self] _ in self?.cancel() }
      .store(in: &contextObservations)
    profileChanges?.removeDuplicates().dropFirst().sink { [weak self] _ in self?.cancel() }
      .store(in: &contextObservations)
  }

  func context(window: WorkspaceWindowSession, store: WorkbenchStore, target: Target) -> Context? {
    if let draftID = target.draftID {
      guard window.selectedDraftID == draftID,
        let draft = store.draft(for: draftID),
        draft.belongs(toSiteProfileID: store.activeProfileID)
      else { return nil }
    }
    return Context(
      windowID: window.windowID, profileID: store.activeProfileID, draftID: target.draftID)
  }

  // MARK: Store-backed flows

  func prepare(
    _ target: Target, context: Context, store: WorkbenchStore,
    currentContext: @escaping @MainActor () -> Context?
  ) {
    flagRestorationStore = store
    prepare(
      target, context: context, currentContext: currentContext,
      operation: { [weak self] in
        await self?.preparation(for: target, store: store)
          ?? .outcome(Self.failure(String(localized: "发布已取消。")))
      },
      onDiscard: { [weak self] in self?.draftFlagRestoration.restore(in: store) })
  }

  func confirm(_ review: Review, store: WorkbenchStore) {
    guard phase == .idle, pendingReview?.id == review.id else { return }
    draftFlagRestoration.commit()
    let profileID = store.activeProfileID
    publish(review: review) {
      let result = await store.publishRepositoryWorktree(review.confirmation)
      store.refreshBatchPublishPlanInBackground()
      if let draftID = review.target.draftID, let draft = store.draft(for: draftID) {
        store.publishing.refreshPublishPreviewInBackground(for: draft)
      }
      return Self.outcome(result: result, profileID: profileID, store: store)
    }
  }

  func discardReview(store: WorkbenchStore) {
    guard !isPublishing else { return }
    pendingReview = nil
    draftFlagRestoration.restore(in: store)
  }

  func preparePushRetry(store: WorkbenchStore) {
    guard phase == .idle else { return }
    clearPending()
    generation &+= 1
    let operationGeneration = generation
    phase = .preparingPushRetry
    operationTask = Task { @MainActor [weak self] in
      let confirmation = await store.prepareRepositoryWorktreePushRetry()
      guard let self, self.generation == operationGeneration else { return }
      self.operationTask = nil
      self.phase = .idle
      guard !Task.isCancelled else { return }
      if let confirmation {
        self.pendingPushRetry = confirmation
      } else {
        self.outcome = Self.storeOutcome(
          store, fallback: String(localized: "当前没有需要重新推送的提交。"))
      }
    }
  }

  func confirmPushRetry(
    _ confirmation: RepositoryWorktreePushRetryConfirmation, store: WorkbenchStore
  ) {
    guard phase == .idle, pendingPushRetry?.id == confirmation.id else { return }
    let profileID = store.activeProfileID
    generation &+= 1
    let operationGeneration = generation
    phase = .pushingRetry
    operationTask = Task { @MainActor [weak self] in
      let result = await store.retryRepositoryWorktreePush(confirmation)
      store.refreshBatchPublishPlanInBackground()
      guard let self, self.generation == operationGeneration else { return }
      self.operationTask = nil
      self.phase = .idle
      self.pendingPushRetry = nil
      self.outcome = Self.outcome(result: result, profileID: profileID, store: store)
    }
  }

  func discardPushRetry() {
    guard !isPublishing else { return }
    pendingPushRetry = nil
  }

  private func preparation(for target: Target, store: WorkbenchStore) async -> PreparationResult {
    switch target {
    case .all:
      let title = store.activeProfile.name
      return Self.result(
        await store.prepareAllChangesRepositoryPublish(), target: target, title: title,
        clearedDraftFlag: false, store: store)
    case .article(let draftID):
      guard let draft = store.draft(for: draftID) else {
        return .outcome(Self.failure(String(localized: "文章已不存在。")))
      }
      draftFlagRestoration.clearDraftFlag(of: draftID, in: store)
      let cleared = draftFlagRestoration.draftID == draftID
      return Self.result(
        await store.prepareArticleRepositoryPublish(draftID: draftID), target: target,
        title: draft.title, clearedDraftFlag: cleared, store: store)
    }
  }

  private static func result(
    _ preparation: RepositoryPublishPreparation, target: Target, title: String,
    clearedDraftFlag: Bool, store: WorkbenchStore
  ) -> PreparationResult {
    switch preparation {
    case .review(let confirmation):
      return .review(
        Review(
          target: target, title: title, confirmation: confirmation,
          clearedDraftFlag: clearedDraftFlag))
    case .blocked(let draftID, let issues):
      return .blockers(Blockers(draftID: draftID, title: title, issues: issues))
    case .unavailable(let message):
      let status = store.publishDrawerFeedback.flatMap {
        $0.message == message ? $0.status : nil
      }
      return .outcome(
        Outcome(
          message: message, status: status ?? .warning, recordID: nil,
          offersPushRetry: status == .failure))
    }
  }

  private static func outcome(
    result: RepositoryWorktreePublishResult?, profileID: UUID, store: WorkbenchStore
  ) -> Outcome {
    guard let result else {
      return storeOutcome(store, fallback: String(localized: "发布没有完成，请稍后重试。"))
    }
    let recordID = store.releaseRecords.first {
      $0.commitSHA == result.commitSHA && $0.siteProfileID == profileID
        && $0.kind == .remoteDirectCommit
    }?.id
    return Outcome(
      message: store.publishActionMessage
        ?? String(localized: "已提交并推送到 \(result.branch)。"),
      status: .success, recordID: recordID, offersPushRetry: false)
  }

  private static func storeOutcome(_ store: WorkbenchStore, fallback: String) -> Outcome {
    let feedback = store.publishDrawerFeedback
    let status = feedback?.status ?? .warning
    return Outcome(
      message: feedback?.message ?? fallback, status: status, recordID: nil,
      offersPushRetry: status == .failure || status == .warning)
  }

  private static func failure(_ message: String) -> Outcome {
    Outcome(message: message, status: .warning, recordID: nil, offersPushRetry: false)
  }

  // MARK: Ownership

  /// Delivers a preparation only while its window, site and article still
  /// match. `onDiscard` undoes temporary changes of a result nobody sees.
  @discardableResult
  func prepare(
    _ target: Target,
    context: Context,
    currentContext: @escaping @MainActor () -> Context?,
    operation: @escaping @MainActor () async -> PreparationResult,
    onDiscard: @escaping @MainActor () -> Void = {}
  ) -> Bool {
    guard phase == .idle, currentContext() == context else { return false }
    clearPending()
    generation &+= 1
    let operationGeneration = generation
    phase = .preparing(target)
    operationTask = Task { @MainActor [weak self] in
      guard !Task.isCancelled, self?.generation == operationGeneration,
        currentContext() == context
      else {
        onDiscard()
        return
      }
      let result = await operation()
      guard let self, self.generation == operationGeneration, !Task.isCancelled,
        currentContext() == context
      else {
        onDiscard()
        return
      }
      self.operationTask = nil
      self.phase = .idle
      switch result {
      case .review(let review):
        self.pendingReview = review
      case .blockers(let blockers):
        onDiscard()
        self.pendingBlockers = blockers
      case .outcome(let outcome):
        onDiscard()
        self.outcome = outcome
      }
    }
    return true
  }

  /// A confirmed publish always runs to completion and reports its outcome,
  /// even if the user switches article or site meanwhile.
  @discardableResult
  func publish(
    review: Review,
    operation: @escaping @MainActor () async -> Outcome
  ) -> Bool {
    guard phase == .idle, pendingReview?.id == review.id else { return false }
    generation &+= 1
    let operationGeneration = generation
    phase = .publishing(review.target)
    operationTask = Task { @MainActor [weak self] in
      let outcome = await operation()
      guard let self, self.generation == operationGeneration else { return }
      self.operationTask = nil
      self.phase = .idle
      self.pendingReview = nil
      self.outcome = outcome
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

  /// Cancels preparations and pending reviews. A running commit and push is
  /// left to finish; Git, not this window, owns that outcome.
  func cancel() {
    cancelRepairRefresh()
    guard !isPublishing else { return }
    generation &+= 1
    operationTask?.cancel()
    operationTask = nil
    phase = .idle
    pendingReview = nil
    pendingPushRetry = nil
    pendingBlockers = nil
    if let store = flagRestorationStore {
      draftFlagRestoration.restore(in: store)
    }
  }

  /// The user closed the publish sheet without choosing an action.
  func sheetDidDismiss(store: WorkbenchStore) {
    pendingBlockers = nil
    outcome = nil
    discardPushRetry()
    discardReview(store: store)
  }

  private func cancelArticleWork() {
    cancelRepairRefresh()
    let isArticleWork: Bool
    switch phase {
    case .preparing(.article): isArticleWork = true
    case .idle: isArticleWork = pendingReview?.target.draftID != nil || pendingBlockers != nil
    default: isArticleWork = false
    }
    guard isArticleWork else { return }
    cancel()
  }

  private func clearPending() {
    pendingReview = nil
    pendingPushRetry = nil
    pendingBlockers = nil
    outcome = nil
  }

  func waitUntilIdle() async {
    let operation = operationTask
    let repair = repairTask
    await operation?.value
    await repair?.value
  }
}

/// A draft whose flag was cleared for a formal publish. It returns to a draft
/// unless that publish is confirmed.
struct PublishDraftFlagRestoration {
  private(set) var draftID: UUID?

  @MainActor
  mutating func clearDraftFlag(of draftID: UUID, in store: WorkbenchStore) {
    guard store.draft(for: draftID)?.articleState == .draft else { return }
    store.setArticleState(.ready, for: draftID)
    self.draftID = draftID
  }

  mutating func commit() { draftID = nil }

  @MainActor
  mutating func restore(in store: WorkbenchStore) {
    guard let draftID else { return }
    self.draftID = nil
    if store.draft(for: draftID)?.articleState == .ready {
      store.setArticleState(.draft, for: draftID)
    }
  }
}
