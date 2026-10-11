import Combine
import Foundation

private struct DraftScopedPreflightSnapshot: Sendable {
  let draft: ArticleDraft
  let profile: SiteProfile
  let sameSiteDrafts: [ArticleDraft]
  let repositoryReport: RepositoryScanReport?
  let context: DraftExecutionContext
  let cacheSnapshot: DraftPreflightSnapshot
}

private func hasSamePreflightInputs(_ lhs: [ArticleDraft], _ rhs: [ArticleDraft]) -> Bool {
  guard lhs.count == rhs.count else { return false }
  return zip(lhs, rhs).allSatisfy { current, snapshot in
    current.hasSamePreflightInput(as: snapshot)
  }
}

/// One shared computation has independent cancellable waiters. Superseding
/// the computation wakes them immediately, even while its worker is awaiting
/// a separate word-count task which it does not own.
actor DraftPreflightRefreshCompletion {
  private var isFinished = false
  private var result: DraftPreflightResult?
  private var waiters: [UUID: CheckedContinuation<DraftPreflightResult?, Never>] = [:]
  private var cancelledWaiters = Set<UUID>()

  func value() async -> DraftPreflightResult? {
    let waiterID = UUID()
    let value: DraftPreflightResult? = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if cancelledWaiters.remove(waiterID) != nil {
          continuation.resume(returning: nil)
        } else if isFinished {
          continuation.resume(returning: result)
        } else {
          waiters[waiterID] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterID) }
    }
    return Task.isCancelled ? nil : value
  }

  func finish(_ result: DraftPreflightResult?) {
    guard !isFinished else { return }
    isFinished = true
    self.result = result
    let pending = waiters.values
    waiters.removeAll()
    cancelledWaiters.removeAll()
    for continuation in pending { continuation.resume(returning: result) }
  }

  private func cancelWaiter(_ waiterID: UUID) {
    if let continuation = waiters.removeValue(forKey: waiterID) {
      continuation.resume(returning: nil)
    } else if !isFinished {
      cancelledWaiters.insert(waiterID)
    }
  }
}

struct DraftPreflightRefreshOperation: Sendable {
  let generation: UInt64
  let identity: DraftPreflightRefreshIdentity
  let task: Task<DraftPreflightResult?, Never>
  let completion: DraftPreflightRefreshCompletion

  func cancel() {
    task.cancel()
    Task { await completion.finish(nil) }
  }
}

extension WorkbenchStore {
  /// Runs preflight for an explicit draft without depending on the active
  /// editor selection or mutating the shared preflight projection.
  ///
  /// The editor buffer for only `draftID` is committed before the immutable
  /// snapshot is captured. Detached work is discarded when any input that can
  /// affect duplicate, profile, or repository checks changes before it
  /// finishes.
  public func runPreflight(for draftID: UUID) async -> DraftPreflightResult? {
    configureDraftPreflightInputObservationIfNeeded()
    flushDraftBodyEditorBuffer(for: draftID)
    guard !Task.isCancelled, let identity = draftPreflightRefreshIdentity(for: draftID) else {
      return nil
    }
    let operation = startDraftPreflightRefresh(for: draftID, identity: identity)
    let result = await operation.completion.value()
    guard !Task.isCancelled,
      publishingStore.publishSession.draftPreflightGenerations[draftID] == operation.generation
    else { return nil }
    return result
  }

  /// Uses a valid cache or joins the shared computation for this exact input.
  /// A cancelled window stops waiting without cancelling other consumers.
  public func ensurePreflight(
    for draftID: UUID,
    flushEditorBuffer: Bool = true
  ) async -> DraftPreflightResult? {
    configureDraftPreflightInputObservationIfNeeded()
    guard !Task.isCancelled else { return nil }
    if let cached = cachedPreflightResult(for: draftID) { return cached }
    if flushEditorBuffer { flushDraftBodyEditorBuffer(for: draftID) }
    guard let identity = draftPreflightRefreshIdentity(for: draftID),
      !identity.requestKey.hasPendingBody
    else { return nil }
    let session = publishingStore.publishSession
    while !Task.isCancelled {
      if let cached = cachedPreflightResult(for: draftID) { return cached }
      guard draftPreflightRefreshIdentity(for: draftID) == identity else { return nil }
      let operation: DraftPreflightRefreshOperation
      if let existing = session.draftPreflightRefreshTasks[draftID], existing.identity == identity {
        operation = existing
      } else {
        operation = startDraftPreflightRefresh(for: draftID, identity: identity)
      }
      _ = await operation.completion.value()
      guard !Task.isCancelled,
        draftPreflightRefreshIdentity(for: draftID) == identity
      else { return nil }
      if let cached = cachedPreflightResult(for: draftID) { return cached }
      guard let replacement = session.draftPreflightRefreshTasks[draftID],
        replacement.identity == identity, replacement.generation != operation.generation
      else { return nil }
    }
    return nil
  }

  private func startDraftPreflightRefresh(
    for draftID: UUID,
    identity: DraftPreflightRefreshIdentity
  ) -> DraftPreflightRefreshOperation {
    let generation = beginDraftPreflightCalculation(for: draftID)
    let completion = DraftPreflightRefreshCompletion()
    let task = Task { [weak self] in
      let result = await self?.calculateDraftPreflight(for: draftID, generation: generation)
      await completion.finish(result)
      if let self,
        self.publishingStore.publishSession.draftPreflightGenerations[draftID] == generation
      {
        self.publishingStore.publishSession.draftPreflightRefreshTasks.removeValue(forKey: draftID)
      }
      return result
    }
    let operation = DraftPreflightRefreshOperation(
      generation: generation, identity: identity, task: task, completion: completion
    )
    publishingStore.publishSession.draftPreflightRefreshTasks[draftID] = operation
    return operation
  }

  /// Reading a cached result never starts preflight, scans siblings or touches
  /// the repository. Revisions are maintained when their inputs change.
  public func cachedPreflightResult(for draftID: UUID) -> DraftPreflightResult? {
    guard let snapshot = publishingStore.publishSession.draftPreflightSnapshots[draftID],
      isCurrentDraftPreflightSnapshot(snapshot)
    else { return nil }
    return snapshot.result
  }

  /// The result to show for `draftID`: the current cache when valid, otherwise
  /// the last complete result for the same draft and site, marked not current
  /// while its refresh is pending. Nil only before the first calculation.
  public func displayedPreflightResult(
    for draftID: UUID
  ) -> (result: DraftPreflightResult, isCurrent: Bool)? {
    if let current = cachedPreflightResult(for: draftID) { return (current, true) }
    guard
      let previous = publishingStore.publishSession.draftPreflightLastKnownResults[draftID],
      let draft = draft(for: draftID),
      previous.context.profileID == profile(for: draft).id
    else { return nil }
    return (previous, false)
  }

  func calculateDraftPreflight(
    for draftID: UUID,
    generation: UInt64
  ) async -> DraftPreflightResult? {
    if let wordCountRefreshTask = draftWordCountRefreshTasks[draftID] {
      await wordCountRefreshTask.value
    }
    guard !Task.isCancelled,
      publishingStore.publishSession.draftPreflightGenerations[draftID] == generation
    else { return nil }

    guard let draftSnapshot = draft(for: draftID) else { return nil }
    let profileSnapshot = profile(for: draftSnapshot)
    let sameSiteDrafts =
      drafts
      .filter { $0.belongs(toSiteProfileID: draftSnapshot.siteProfileID) }
      .sorted { $0.id.uuidString < $1.id.uuidString }
    let repositoryReportSnapshot = repositoryReport(for: profileSnapshot)
    guard let requestKey = draftScopedPreflightRequestKey(for: draftID),
      !requestKey.hasPendingBody
    else { return nil }
    let context = DraftExecutionContext(
      draftID: draftID,
      profileID: profileSnapshot.id,
      bodyRevision: requestKey.bodyRevision
    )
    let cacheSnapshot = makeDraftPreflightSnapshot(
      result: DraftPreflightResult(context: context, issues: []),
      requestKey: requestKey
    )
    let snapshot = DraftScopedPreflightSnapshot(
      draft: draftSnapshot,
      profile: profileSnapshot,
      sameSiteDrafts: sameSiteDrafts,
      repositoryReport: repositoryReportSnapshot,
      context: context,
      cacheSnapshot: cacheSnapshot
    )
    let preflightService = publishingStore.preflightService
    let generalDraftPublishingIssue = publishingStore.generalDraftPublishingIssue
    let linkAuditKey = siteLinkAuditKey(
      drafts: snapshot.sameSiteDrafts,
      profile: snapshot.profile
    )
    let cachedLinkAuditReport = siteLinkAuditSnapshotStore.report(for: linkAuditKey)

    let calculationTask: Task<([PreflightIssue], SiteLinkAuditReport?)?, Never> = Task.detached(
      priority: .userInitiated
    ) {
      guard !Task.isCancelled else { return nil }
      if snapshot.draft.isGeneralDraft {
        return ([generalDraftPublishingIssue], nil)
      }

      let duplicateIndex = PreflightDuplicateIndex(
        drafts: snapshot.sameSiteDrafts,
        profile: snapshot.profile
      )
      let baseIssues = preflightService.run(
        draft: snapshot.draft,
        allDrafts: snapshot.sameSiteDrafts,
        profile: snapshot.profile,
        repositoryReport: snapshot.repositoryReport,
        includeRepositoryReadiness: true,
        duplicateIndex: duplicateIndex
      )
      let linkAuditReport =
        cachedLinkAuditReport
        ?? SiteLinkAuditService().report(
          drafts: snapshot.sameSiteDrafts,
          profile: snapshot.profile
        )
      return (
        linkAuditReport.mergingPreflightIssues(baseIssues, for: snapshot.draft),
        linkAuditReport
      )
    }
    let calculation = await withTaskCancellationHandler(
      operation: {
        await calculationTask.value
      },
      onCancel: {
        calculationTask.cancel()
      }
    )

    guard let currentDraft = draft(for: draftID) else { return nil }
    let currentBodyBuffer = draftBodyEditorBuffer(for: draftID)
    let currentSameSiteDrafts =
      drafts
      .filter { $0.belongs(toSiteProfileID: currentDraft.siteProfileID) }
      .sorted { $0.id.uuidString < $1.id.uuidString }
    let currentProfile = profile(for: currentDraft)
    let currentRepositoryReport = repositoryReport(for: currentProfile)

    guard
      !Task.isCancelled,
      let calculation,
      publishingStore.publishSession.draftPreflightGenerations[draftID] == generation,
      isCurrentDraftPreflightSnapshot(snapshot.cacheSnapshot),
      currentDraft.hasSamePreflightInput(as: snapshot.draft),
      currentBodyBuffer.revision == snapshot.context.bodyRevision,
      !currentBodyBuffer.isDirty,
      currentProfile == snapshot.profile,
      hasSamePreflightInputs(currentSameSiteDrafts, snapshot.sameSiteDrafts),
      currentRepositoryReport == snapshot.repositoryReport
    else {
      return nil
    }

    if let linkAuditReport = calculation.1 {
      replaceSiteLinkAuditSnapshotIfCurrent(
        linkAuditReport,
        key: linkAuditKey,
        drafts: snapshot.sameSiteDrafts,
        profile: snapshot.profile
      )
    }
    let result = DraftPreflightResult(context: snapshot.context, issues: calculation.0)
    let completedSnapshot = DraftPreflightSnapshot(
      requestKey: snapshot.cacheSnapshot.requestKey,
      draftInputGeneration: snapshot.cacheSnapshot.draftInputGeneration,
      repositoryInputGeneration: snapshot.cacheSnapshot.repositoryInputGeneration,
      result: result
    )
    guard installDraftPreflightSnapshot(completedSnapshot, generation: generation) else {
      return nil
    }
    return result
  }

  func makeDraftPreflightSnapshot(
    result: DraftPreflightResult,
    requestKey: DraftScopedPreflightRequestKey
  ) -> DraftPreflightSnapshot {
    let session = publishingStore.publishSession
    return DraftPreflightSnapshot(
      requestKey: requestKey,
      draftInputGeneration: session.draftPreflightDraftInputGeneration,
      repositoryInputGeneration: session.draftPreflightRepositoryInputGeneration,
      result: result
    )
  }

  func isCurrentDraftPreflightSnapshot(_ snapshot: DraftPreflightSnapshot) -> Bool {
    let session = publishingStore.publishSession
    guard let key = draftScopedPreflightRequestKey(for: snapshot.result.context.draftID) else {
      return false
    }
    return snapshot.matches(key)
      && snapshot.result.context.profileID == key.profile.id
      && snapshot.result.context.bodyRevision == key.bodyRevision
      && snapshot.draftInputGeneration == session.draftPreflightDraftInputGeneration
      && snapshot.repositoryInputGeneration == session.draftPreflightRepositoryInputGeneration
  }

  @discardableResult
  func installDraftPreflightSnapshot(
    _ snapshot: DraftPreflightSnapshot,
    generation: UInt64
  ) -> Bool {
    let session = publishingStore.publishSession
    let draftID = snapshot.result.context.draftID
    guard session.draftPreflightGenerations[draftID] == generation,
      isCurrentDraftPreflightSnapshot(snapshot)
    else { return false }
    session.draftPreflightSnapshots[draftID] = snapshot
    session.rememberDraftPreflightResult(snapshot.result)
    session.scheduleDraftPublishStatusNotification()
    return true
  }

  @discardableResult
  func beginDraftPreflightCalculation(for draftID: UUID) -> UInt64 {
    configureDraftPreflightInputObservationIfNeeded()
    let session = publishingStore.publishSession
    session.draftPreflightRefreshTasks.removeValue(forKey: draftID)?.cancel()
    session.draftPreflightGeneration &+= 1
    session.draftPreflightGenerations[draftID] = session.draftPreflightGeneration
    session.draftPreflightAccessOrder.removeAll { $0 == draftID }
    session.draftPreflightAccessOrder.append(draftID)
    // Both completed results and generation bookkeeping stay bounded. A
    // request evicted while running can no longer install an older result.
    while session.draftPreflightAccessOrder.count > 64 {
      let evictedID = session.draftPreflightAccessOrder.removeFirst()
      session.draftPreflightRefreshTasks.removeValue(forKey: evictedID)?.cancel()
      session.draftPreflightGenerations.removeValue(forKey: evictedID)
      if session.draftPreflightSnapshots.removeValue(forKey: evictedID) != nil {
        session.scheduleDraftPublishStatusNotification()
      }
    }
    return session.draftPreflightGeneration
  }

  func configureDraftPreflightInputObservationIfNeeded() {
    let session = publishingStore.publishSession
    guard session.draftPreflightInputCancellables.isEmpty else { return }
    publishingStore.documents.$drafts.dropFirst()
      .sink { [weak session] drafts in
        guard let session else { return }
        session.pruneDraftPreflightLastKnownResults(keeping: Set(drafts.map(\.id)))
        guard !session.isPublishingDerivedWordCount else { return }
        session.invalidateDraftPreflightInputs()
      }
      .store(in: &session.draftPreflightInputCancellables)
    publishingStore.documentSession.draftBodyEditorBufferDidChange
      .sink { [weak session] _ in
        session?.invalidateDraftPreflightInputs()
      }
      .store(in: &session.draftPreflightInputCancellables)
    repositoryStore.$repositoryReport.dropFirst()
      .sink { [weak session] _ in
        guard let session else { return }
        session.draftPreflightRepositoryInputGeneration &+= 1
        session.clearDraftPreflightState()
      }
      .store(in: &session.draftPreflightInputCancellables)
    // Profile/link invalidations are committed by the time this coalesced
    // notification is delivered. Matching keys still reject them immediately.
    Publishers.Merge(
      publishingStore.$profiles.dropFirst().map { _ in () },
      $contentHealthSnapshotVersion.dropFirst().map { _ in () }
    )
    .sink { [weak session] _ in
      session?.invalidateDraftPreflightInputs()
    }
    .store(in: &session.draftPreflightInputCancellables)
  }
}
