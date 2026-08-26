import Foundation

extension WorkbenchAIStore {
  /// Returns the latest metadata suggestion retained for a particular draft.
  /// This is intentionally independent of the compatibility projection shown
  /// by the current editor selection.
  public func aiMetadataSuggestion(for draft: ArticleDraft)
    -> AIPublishingMetadataSuggestion?
  {
    aiMetadataSuggestion(for: draft.id)
  }

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

  public func isAIMetadataSuggestionRunning(for draft: ArticleDraft) -> Bool {
    isAIMetadataSuggestionRunning(for: draft.id)
  }

  public func isAIMetadataSuggestionRunning(for draftID: UUID) -> Bool {
    aiMetadataSuggestionRunningDraftIDs.contains(draftID)
  }

  /// Returns the latest image-text suggestions retained for a particular
  /// draft. A missing cache is intentionally presented as an empty list.
  public func aiImageTextSuggestions(for draft: ArticleDraft)
    -> [AIPublishingImageTextSuggestion]
  {
    aiImageTextSuggestions(for: draft.id)
  }

  public func aiImageTextSuggestions(for draftID: UUID)
    -> [AIPublishingImageTextSuggestion]
  {
    guard let suggestions = aiImageTextSuggestionsByDraftID[draftID],
      let baseline = aiImageTextSuggestionBaselinesByDraftID[draftID],
      let profile = aiImageTextSuggestionProfilesByDraftID[draftID],
      let signature = aiImageTextSuggestionSignaturesByDraftID[draftID],
      draftOperationStillMatches(baseline, profile: profile),
      let currentDraft = store.draft(for: draftID),
      ImageWorkbenchReportInputSignature(
        draft: currentDraft,
        profile: store.profile(for: currentDraft)
      ) == signature
    else {
      return []
    }
    return suggestions
  }

  public func isAIImageTextRunning(for draft: ArticleDraft) -> Bool {
    isAIImageTextRunning(for: draft.id)
  }

  public func isAIImageTextRunning(for draftID: UUID) -> Bool {
    aiImageTextSuggestionRunningDraftIDs.contains(draftID)
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
    var knownDraftIDs = Set(aiMetadataSuggestionsByDraftID.keys)
        .union(aiImageTextSuggestionsByDraftID.keys)
        .union(aiMetadataSuggestionBaselinesByDraftID.keys)
        .union(aiMetadataSuggestionProfilesByDraftID.keys)
        .union(aiImageTextSuggestionBaselinesByDraftID.keys)
        .union(aiImageTextSuggestionProfilesByDraftID.keys)
        .union(aiImageTextSuggestionSignaturesByDraftID.keys)
        .union(aiMetadataSuggestionGenerationsByDraftID.keys)
        .union(aiImageTextSuggestionGenerationsByDraftID.keys)
        .union(aiMetadataSuggestionRunningDraftIDs)
        .union(aiImageTextSuggestionRunningDraftIDs)
        .union(aiMetadataSuggestionCancellationHandlersByDraftID.keys)
        .union(aiImageTextSuggestionCancellationHandlersByDraftID.keys)
    if let projectedDraftID = workspace.aiMetadataSuggestionDraftID {
      knownDraftIDs.insert(projectedDraftID)
    }
    if let projectedDraftID = workspace.aiImageTextSuggestionDraftID {
      knownDraftIDs.insert(projectedDraftID)
    }
    let removedDraftIDs = knownDraftIDs.subtracting(validDraftIDs)
    var didChange = false

    for draftID in removedDraftIDs {
      if let cancellation = aiMetadataSuggestionCancellationHandlersByDraftID
        .removeValue(forKey: draftID)
      {
        cancellation()
        didChange = true
      }
      if let cancellation = aiImageTextSuggestionCancellationHandlersByDraftID
        .removeValue(forKey: draftID)
      {
        cancellation()
        didChange = true
      }
      if aiMetadataSuggestionsByDraftID.removeValue(forKey: draftID) != nil {
        didChange = true
      }
      if aiImageTextSuggestionsByDraftID.removeValue(forKey: draftID) != nil {
        didChange = true
      }
      if aiMetadataSuggestionBaselinesByDraftID.removeValue(forKey: draftID) != nil {
        didChange = true
      }
      if aiMetadataSuggestionProfilesByDraftID.removeValue(forKey: draftID) != nil {
        didChange = true
      }
      if aiImageTextSuggestionBaselinesByDraftID.removeValue(forKey: draftID) != nil {
        didChange = true
      }
      if aiImageTextSuggestionProfilesByDraftID.removeValue(forKey: draftID) != nil {
        didChange = true
      }
      if aiImageTextSuggestionSignaturesByDraftID.removeValue(forKey: draftID) != nil {
        didChange = true
      }
      if aiMetadataSuggestionGenerationsByDraftID.removeValue(forKey: draftID) != nil {
        didChange = true
      }
      if aiImageTextSuggestionGenerationsByDraftID.removeValue(forKey: draftID) != nil {
        didChange = true
      }
      if aiMetadataSuggestionRunningDraftIDs.remove(draftID) != nil {
        didChange = true
      }
      if aiImageTextSuggestionRunningDraftIDs.remove(draftID) != nil {
        didChange = true
      }
    }

    let nextMetadataRunning = !aiMetadataSuggestionRunningDraftIDs.isEmpty
    if workspaceIsAIMetadataSuggestionRunning != nextMetadataRunning {
      workspaceIsAIMetadataSuggestionRunning = nextMetadataRunning
      didChange = true
    }
    let nextImageTextRunning = !aiImageTextSuggestionRunningDraftIDs.isEmpty
    if workspaceIsAIImageTextRunning != nextImageTextRunning {
      workspaceIsAIImageTextRunning = nextImageTextRunning
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
    guard aiMetadataSuggestionGenerationsByDraftID[draftID] == generation else {
      handler()
      return
    }
    aiMetadataSuggestionCancellationHandlersByDraftID[draftID] = handler
  }

  func registerAIImageTextSuggestionCancellationHandler(
    for draftID: UUID,
    generation: UInt64,
    handler: @escaping () -> Void
  ) {
    guard aiImageTextSuggestionGenerationsByDraftID[draftID] == generation else {
      handler()
      return
    }
    aiImageTextSuggestionCancellationHandlersByDraftID[draftID] = handler
  }

  func beginAIMetadataSuggestionOperation(for draftID: UUID) -> UInt64 {
    aiMetadataSuggestionCancellationHandlersByDraftID.removeValue(forKey: draftID)?()
    let generation = (aiMetadataSuggestionGenerationsByDraftID[draftID] ?? 0) &+ 1
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
    guard aiMetadataSuggestionGenerationsByDraftID[draftID] == generation else {
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

  func beginAIImageTextSuggestionOperation(for draftID: UUID) -> UInt64 {
    aiImageTextSuggestionCancellationHandlersByDraftID.removeValue(forKey: draftID)?()
    let generation = (aiImageTextSuggestionGenerationsByDraftID[draftID] ?? 0) &+ 1
    aiImageTextSuggestionGenerationsByDraftID[draftID] = generation
    aiImageTextSuggestionRunningDraftIDs.insert(draftID)
    workspaceIsAIImageTextRunning = true
    if store.selectedDraftID == draftID {
      restoreDraftSuggestionProjectionForCurrentSelection()
    } else {
      bumpAIDraftSuggestionStateRevision()
    }
    return generation
  }

  func finishAIImageTextSuggestionOperation(for draftID: UUID, generation: UInt64) {
    guard aiImageTextSuggestionGenerationsByDraftID[draftID] == generation else { return }
    aiImageTextSuggestionCancellationHandlersByDraftID.removeValue(forKey: draftID)
    aiImageTextSuggestionRunningDraftIDs.remove(draftID)
    workspaceIsAIImageTextRunning = !aiImageTextSuggestionRunningDraftIDs.isEmpty
    bumpAIDraftSuggestionStateRevision()
  }

  @discardableResult
  func installAIImageTextSuggestions(
    _ suggestions: [AIPublishingImageTextSuggestion],
    for draftID: UUID,
    generation: UInt64
  ) -> Bool {
    guard aiImageTextSuggestionGenerationsByDraftID[draftID] == generation else {
      return false
    }
    guard let baseline = store.draftOperationBaseline(for: draftID) else {
      return false
    }
    let profile = store.profile(for: baseline.draft)
    aiImageTextSuggestionsByDraftID[draftID] = suggestions
    aiImageTextSuggestionBaselinesByDraftID[draftID] = baseline
    aiImageTextSuggestionProfilesByDraftID[draftID] = profile
    aiImageTextSuggestionSignaturesByDraftID[draftID] =
      ImageWorkbenchReportInputSignature(draft: baseline.draft, profile: profile)
    if store.selectedDraftID == draftID {
      restoreDraftSuggestionProjectionForCurrentSelection()
    } else {
      bumpAIDraftSuggestionStateRevision()
    }
    return true
  }

  func removeAIImageTextSuggestions(
    withIDs suggestionIDs: Set<String>,
    for draftID: UUID
  ) {
    guard var cached = aiImageTextSuggestionsByDraftID[draftID] else { return }
    cached.removeAll { suggestionIDs.contains($0.id) }
    if cached.isEmpty {
      aiImageTextSuggestionsByDraftID.removeValue(forKey: draftID)
      aiImageTextSuggestionBaselinesByDraftID.removeValue(forKey: draftID)
      aiImageTextSuggestionProfilesByDraftID.removeValue(forKey: draftID)
      aiImageTextSuggestionSignaturesByDraftID.removeValue(forKey: draftID)
    } else {
      aiImageTextSuggestionsByDraftID[draftID] = cached
    }
    if store.selectedDraftID == draftID {
      restoreDraftSuggestionProjectionForCurrentSelection()
    } else {
      bumpAIDraftSuggestionStateRevision()
    }
  }

  func removeAllAIImageTextSuggestions(for draftID: UUID) {
    aiImageTextSuggestionsByDraftID.removeValue(forKey: draftID)
    aiImageTextSuggestionBaselinesByDraftID.removeValue(forKey: draftID)
    aiImageTextSuggestionProfilesByDraftID.removeValue(forKey: draftID)
    aiImageTextSuggestionSignaturesByDraftID.removeValue(forKey: draftID)
    if store.selectedDraftID == draftID {
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
    let nextImageTextSuggestions = selectedDraftID.flatMap {
      aiImageTextSuggestions(for: $0)
    } ?? []

    let didChange =
      workspace.aiMetadataSuggestionDraftID != selectedDraftID
      || workspace.aiMetadataSuggestion != nextMetadataSuggestion
      || workspace.aiImageTextSuggestionDraftID != selectedDraftID
      || workspace.aiImageTextSuggestions != nextImageTextSuggestions

    if workspace.aiMetadataSuggestionDraftID != selectedDraftID {
      workspace.aiMetadataSuggestionDraftID = selectedDraftID
    }
    if workspace.aiMetadataSuggestion != nextMetadataSuggestion {
      workspace.aiMetadataSuggestion = nextMetadataSuggestion
    }
    if workspace.aiImageTextSuggestionDraftID != selectedDraftID {
      workspace.aiImageTextSuggestionDraftID = selectedDraftID
    }
    if workspace.aiImageTextSuggestions != nextImageTextSuggestions {
      workspace.aiImageTextSuggestions = nextImageTextSuggestions
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
    store.flushDraftBodyEditorBuffer(for: draftID)
    while let wordCountTask = store.draftWordCountRefreshTasks[draftID] {
      await wordCountTask.value
      await Task.yield()
    }
    guard !Task.isCancelled else { return nil }
    return store.draftOperationBaseline(for: draftID)
  }

  func draftOperationStillMatches(
    _ baseline: DraftOperationBaseline,
    profile: SiteProfile
  ) -> Bool {
    guard let currentDraft = store.draft(for: baseline.draft.id) else {
      return false
    }
    let buffer = store.draftBodyEditorBuffer(for: baseline.draft.id)
    guard !buffer.isDirty, buffer.revision == baseline.bodyRevision else {
      return false
    }
    var baselineDraft = baseline.draft
    var normalizedCurrentDraft = currentDraft
    _ = baselineDraft.storeWordCount(0, for: baselineDraft.bodyMarkdown)
    _ = normalizedCurrentDraft.storeWordCount(0, for: normalizedCurrentDraft.bodyMarkdown)
    return normalizedCurrentDraft == baselineDraft
      && store.profile(for: currentDraft) == profile
  }

  // These small aliases keep the operation helpers from calling the public
  // compatibility setters, whose legacy semantics intentionally clear all
  // running state when set to false.
  private var workspaceIsAIMetadataSuggestionRunning: Bool {
    get { workspace.isAIMetadataSuggestionRunning }
    set { workspace.isAIMetadataSuggestionRunning = newValue }
  }

  private var workspaceIsAIImageTextRunning: Bool {
    get { workspace.isAIImageTextRunning }
    set { workspace.isAIImageTextRunning = newValue }
  }
}
