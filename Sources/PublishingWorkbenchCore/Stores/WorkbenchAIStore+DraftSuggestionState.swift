import Foundation

extension WorkbenchAIStore {

  public func aiMetadataSuggestion(for draftID: UUID)
    -> AIPublishingMetadataSuggestion?
  {
    guard let suggestion = aiMetadataSuggestionsByDraftID[draftID],
      let baseline = aiMetadataSuggestionBaselinesByDraftID[draftID],
      let profile = aiMetadataSuggestionProfilesByDraftID[draftID],
      draftOperationStillMatches(baseline, profile: profile)
    else {
      return nil
    }
    return suggestion
  }

  func bumpAIDraftSuggestionStateRevision() {
    aiDraftSuggestionStateRevision &+= 1
  }

  /// Drops transient suggestion state for drafts that no longer belong to the
  /// current workspace snapshot. The root store calls this after replacing
  /// its draft collection. Generation entries are removed after cancelling
  /// their network child tasks, so a late completion cannot reinstall state
  /// for a deleted draft.
  func reconcileAIDraftSuggestionState(validDraftIDs: Set<UUID>) {
    let invalidRequests = aiRequestBaselines.filter { !validDraftIDs.contains($0.value.draft.id) }
    for lane in invalidRequests.keys {
      if let generation = currentAIRequestGeneration(lane) {
        cancelAIRequest(lane, generation: generation)
      }
    }
    var knownDraftIDs = Set(aiMetadataSuggestionsByDraftID.keys)
      .union(aiMetadataSuggestionBaselinesByDraftID.keys)
      .union(aiMetadataSuggestionProfilesByDraftID.keys)
      .union(aiMetadataSuggestionGenerationsByDraftID.keys)
      .union(aiMetadataSuggestionRunningDraftIDs)
      .union(aiMetadataSuggestionCancellationHandlersByDraftID.keys)
    if let projectedDraftID = workspace.aiMetadataSuggestionDraftID {
      knownDraftIDs.insert(projectedDraftID)
    }
    let removedDraftIDs = knownDraftIDs.subtracting(validDraftIDs)
    var didChange = false

    for draftID in removedDraftIDs {
      let lane = AIGenerationLane.metadata(draftID)
      if let generation = currentAIRequestGeneration(lane) {
        cancelAIRequest(lane, generation: generation)
        didChange = true
      }
      if let cancellation =
        aiMetadataSuggestionCancellationHandlersByDraftID
        .removeValue(forKey: draftID)
      {
        cancellation()
        didChange = true
      }
      if aiMetadataSuggestionsByDraftID.removeValue(forKey: draftID) != nil {
        didChange = true
      }
      if aiMetadataSuggestionBaselinesByDraftID.removeValue(forKey: draftID) != nil {
        didChange = true
      }
      if aiMetadataSuggestionProfilesByDraftID.removeValue(forKey: draftID) != nil {
        didChange = true
      }
      if aiMetadataSuggestionGenerationsByDraftID.removeValue(forKey: draftID) != nil {
        didChange = true
      }
      if aiMetadataSuggestionRunningDraftIDs.remove(draftID) != nil {
        didChange = true
      }
    }

    let nextMetadataRunning = !aiMetadataSuggestionRunningDraftIDs.isEmpty
    if workspaceIsAIMetadataSuggestionRunning != nextMetadataRunning {
      workspaceIsAIMetadataSuggestionRunning = nextMetadataRunning
      didChange = true
    }

    guard didChange else { return }
    let revisionBeforeProjection = aiDraftSuggestionStateRevision
    restoreDraftSuggestionProjectionForCurrentSelection()
    if aiDraftSuggestionStateRevision == revisionBeforeProjection {
      bumpAIDraftSuggestionStateRevision()
    }
  }

  func registerAIMetadataSuggestionCancellationHandler(
    for draftID: UUID,
    generation: UInt64,
    handler: @escaping () -> Void
  ) {
    guard !Task.isCancelled,
      aiMetadataSuggestionGenerationsByDraftID[draftID] == generation
    else {
      handler()
      return
    }
    aiMetadataSuggestionCancellationHandlersByDraftID[draftID] = handler
  }

  func beginAIMetadataSuggestionOperation(for draftID: UUID) -> UInt64 {
    aiMetadataSuggestionCancellationHandlersByDraftID.removeValue(forKey: draftID)?()
    let generation = nextAIRequestGeneration()
    aiMetadataSuggestionGenerationsByDraftID[draftID] = generation
    aiMetadataSuggestionRunningDraftIDs.insert(draftID)
    workspaceIsAIMetadataSuggestionRunning = true
    if store.selectedDraftID == draftID {
      restoreDraftSuggestionProjectionForCurrentSelection()
    } else {
      bumpAIDraftSuggestionStateRevision()
    }
    return generation
  }

  func finishAIMetadataSuggestionOperation(for draftID: UUID, generation: UInt64) {
    guard aiMetadataSuggestionGenerationsByDraftID[draftID] == generation else { return }
    aiMetadataSuggestionCancellationHandlersByDraftID.removeValue(forKey: draftID)
    aiMetadataSuggestionRunningDraftIDs.remove(draftID)
    workspaceIsAIMetadataSuggestionRunning = !aiMetadataSuggestionRunningDraftIDs.isEmpty
    bumpAIDraftSuggestionStateRevision()
  }

  @discardableResult
  func installAIMetadataSuggestion(
    _ suggestion: AIPublishingMetadataSuggestion,
    for draftID: UUID,
    generation: UInt64
  ) -> Bool {
    guard !Task.isCancelled,
      aiMetadataSuggestionGenerationsByDraftID[draftID] == generation
    else {
      return false
    }
    guard let baseline = store.draftOperationBaseline(for: draftID) else {
      return false
    }
    aiMetadataSuggestionsByDraftID[draftID] = suggestion
    aiMetadataSuggestionBaselinesByDraftID[draftID] = baseline
    aiMetadataSuggestionProfilesByDraftID[draftID] = store.profile(for: baseline.draft)
    if store.selectedDraftID == draftID {
      restoreDraftSuggestionProjectionForCurrentSelection()
    } else {
      bumpAIDraftSuggestionStateRevision()
    }
    return true
  }

  func removeAIMetadataSuggestion(for draftID: UUID) {
    aiMetadataSuggestionsByDraftID.removeValue(forKey: draftID)
    aiMetadataSuggestionBaselinesByDraftID.removeValue(forKey: draftID)
    aiMetadataSuggestionProfilesByDraftID.removeValue(forKey: draftID)
    if store.selectedDraftID == draftID {
      restoreDraftSuggestionProjectionForCurrentSelection()
    } else {
      bumpAIDraftSuggestionStateRevision()
    }
  }

  /// Consumes fields explicitly accepted by the caller. Remaining metadata
  /// candidates are rebased to the post-application draft so an author can
  /// accept title, summary, and tags one at a time from the same AI result.
  func consumeAIMetadataSuggestion(
    _ appliedSuggestion: AIPublishingMetadataSuggestion,
    for updatedDraft: ArticleDraft
  ) {
    guard var remaining = aiMetadataSuggestionsByDraftID[updatedDraft.id] else { return }

    if !appliedSuggestion.titles.isEmpty { remaining.titles = [] }
    if !appliedSuggestion.slugs.isEmpty { remaining.slugs = [] }
    if appliedSuggestion.summary != nil { remaining.summary = nil }
    if !appliedSuggestion.tags.isEmpty { remaining.tags = [] }

    guard remaining.hasSuggestions,
      let baseline = store.draftOperationBaseline(for: updatedDraft.id)
    else {
      removeAIMetadataSuggestion(for: updatedDraft.id)
      return
    }

    aiMetadataSuggestionsByDraftID[updatedDraft.id] = remaining
    aiMetadataSuggestionBaselinesByDraftID[updatedDraft.id] = baseline
    aiMetadataSuggestionProfilesByDraftID[updatedDraft.id] = store.profile(for: updatedDraft)
    if store.selectedDraftID == updatedDraft.id {
      restoreDraftSuggestionProjectionForCurrentSelection()
    } else {
      bumpAIDraftSuggestionStateRevision()
    }
  }

  /// Rebuilds the legacy workspace fields for the selected draft. Every
  /// selection path already calls `restoreSEOSocialPreviewSnapshotForCurrentSelection`,
  /// so keeping this projection here avoids adding selection-specific calls at
  /// every UI entry point.
  func restoreDraftSuggestionProjectionForCurrentSelection() {
    let selectedDraftID = store.selectedDraftID.flatMap { selectedID in
      store.drafts.contains(where: { $0.id == selectedID }) ? selectedID : nil
    }
    let nextMetadataSuggestion = selectedDraftID.flatMap {
      aiMetadataSuggestion(for: $0)
    }

    let didChange =
      workspace.aiMetadataSuggestionDraftID != selectedDraftID
      || workspace.aiMetadataSuggestion != nextMetadataSuggestion

    if workspace.aiMetadataSuggestionDraftID != selectedDraftID {
      workspace.aiMetadataSuggestionDraftID = selectedDraftID
    }
    if workspace.aiMetadataSuggestion != nextMetadataSuggestion {
      workspace.aiMetadataSuggestion = nextMetadataSuggestion
    }
    if didChange {
      bumpAIDraftSuggestionStateRevision()
    }
  }

  func beginAIActionOperation() -> UUID {
    let operationID = UUID()
    aiActionOperationIDs.insert(operationID)
    workspace.isAIActionRunning = true
    return operationID
  }

  func finishAIActionOperation(_ operationID: UUID) {
    aiActionOperationIDs.remove(operationID)
    workspace.isAIActionRunning = !aiActionOperationIDs.isEmpty
  }

  func prepareDraftOperationBaseline(for draftID: UUID) async -> DraftOperationBaseline? {
    await store.flushDraftBodyEditorBufferAndWaitForWordCount(for: draftID)
    guard !Task.isCancelled else { return nil }
    return store.draftOperationBaseline(for: draftID)
  }

  func draftOperationStillMatches(
    _ baseline: DraftOperationBaseline,
    profile: SiteProfile
  ) -> Bool {
    let currentDraft = store.draft(for: baseline.draft.id)
    return AIApplicationContract.draftStillMatches(
      baseline: baseline,
      profile: profile,
      currentDraft: currentDraft,
      currentProfile: currentDraft.map { store.profile(for: $0) } ?? profile,
      bodyBuffer: store.draftBodyEditorBuffer(for: baseline.draft.id)
    )
  }

  /// Validates that an application request refers to the retained metadata
  /// suggestion for this draft. Generated suggestions install this state with
  /// their request baseline before any caller can apply their values.
  func currentDraftForAIMetadataApplication(
    _ suggestion: AIPublishingMetadataSuggestion,
    requestedDraft: ArticleDraft
  ) -> ArticleDraft? {
    guard let currentDraft = store.draft(for: requestedDraft.id) else {
      aiActionMessage = "找不到要应用 AI 元数据建议的文章。"
      return nil
    }
    guard let retained = aiMetadataSuggestionsByDraftID[requestedDraft.id] else {
      aiActionMessage = "AI 元数据建议已过期，未应用。"
      return nil
    }
    guard let baseline = aiMetadataSuggestionBaselinesByDraftID[requestedDraft.id],
      let profile = aiMetadataSuggestionProfilesByDraftID[requestedDraft.id]
    else {
      removeAIMetadataSuggestion(for: requestedDraft.id)
      aiActionMessage = "AI 元数据建议已过期，未应用。"
      return nil
    }
    guard draftOperationStillMatches(baseline, profile: profile) else {
      removeAIMetadataSuggestion(for: requestedDraft.id)
      aiActionMessage = "AI 元数据建议已过期，未应用。"
      return nil
    }
    guard AIApplicationContract.metadataSuggestion(suggestion, belongsTo: retained) else {
      aiActionMessage = "AI 元数据建议与当前文章不匹配，未应用。"
      return nil
    }
    return currentDraft
  }

  // These small aliases keep the operation helpers from calling the public
  // compatibility setters, whose legacy semantics intentionally clear all
  // running state when set to false.
  private var workspaceIsAIMetadataSuggestionRunning: Bool {
    get { workspace.isAIMetadataSuggestionRunning }
    set { workspace.isAIMetadataSuggestionRunning = newValue }
  }
}
