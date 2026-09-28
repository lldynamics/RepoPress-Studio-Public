import Foundation

extension WorkbenchStore {
  public func markdownEditorSessionState(for draftID: UUID) -> MarkdownEditorSessionState {
    publishingStore.markdownEditorSessionStates[draftID] ?? .empty
  }

  public func updateMarkdownEditorSessionState(
    _ state: MarkdownEditorSessionState,
    for draftID: UUID,
    bodyUTF16Count: Int,
    windowID: UUID? = nil
  ) {
    let normalized = mergedInvalidFrontMatterRecovery(
      state.normalized(bodyUTF16Count: bodyUTF16Count),
      existing: publishingStore.markdownEditorSessionStates[draftID],
      windowID: windowID
    )
    guard publishingStore.markdownEditorSessionStates[draftID] != normalized else {
      return
    }
    publishingStore.markdownEditorSessionStates[draftID] = normalized
    scheduleAutosave()
  }

  /// Claims a legacy recovery record on first restoration. Older snapshots did
  /// not store an owner, so they remain recoverable and become safe to clear
  /// only after an actual editor window has adopted them.
  @discardableResult
  public func claimInvalidFrontMatterRecovery(
    for draftID: UUID,
    windowID: UUID,
    activeWindowIDs: Set<UUID> = []
  ) -> MarkdownEditorSessionState {
    guard var state = publishingStore.markdownEditorSessionStates[draftID] else {
      return .empty
    }
    var records = state.invalidFrontMatterRecoveryRecords ?? [:]
    if let recovery = records[windowID] {
      return projecting(recovery, into: state, ownerWindowID: windowID)
    }
    guard let legacyDocument = state.invalidFrontMatterDocument,
      !legacyDocument.isEmpty,
      state.invalidFrontMatterRecoveryOwnerWindowID == nil
    else {
      // A recovery owned by another window must remain invisible here. This
      // window has a normal document and must not be switched to another
      // editor's invalid Front Matter.
      state.invalidFrontMatterDocument = nil
      state.invalidFrontMatterBaseBodyMarkdown = nil
      state.invalidFrontMatterBaseBodyRevision = nil
      state.invalidFrontMatterBaseMetadataRevision = nil
      state.invalidFrontMatterRecoveryOwnerWindowID = nil
      state.invalidFrontMatterRecoveryVersion = nil
      if let orphanedOwner = records.keys
        .filter({ !activeWindowIDs.contains($0) })
        .sorted(by: { $0.uuidString < $1.uuidString })
        .first,
        let orphanedRecovery = records.removeValue(forKey: orphanedOwner)
      {
        records[windowID] = orphanedRecovery
        state.invalidFrontMatterRecoveryRecords = records
        publishingStore.markdownEditorSessionStates[draftID] = state
        scheduleAutosave()
        return projecting(orphanedRecovery, into: state, ownerWindowID: windowID)
      }
      return state
    }
    let recovery = MarkdownInvalidFrontMatterRecovery(
      document: legacyDocument,
      baseBodyMarkdown: state.invalidFrontMatterBaseBodyMarkdown,
      baseBodyRevision: state.invalidFrontMatterBaseBodyRevision,
      baseMetadataRevision: state.invalidFrontMatterBaseMetadataRevision,
      version: state.invalidFrontMatterRecoveryVersion ?? 1
    )
    records[windowID] = recovery
    state.invalidFrontMatterRecoveryRecords = records
    state.invalidFrontMatterDocument = nil
    state.invalidFrontMatterBaseBodyMarkdown = nil
    state.invalidFrontMatterBaseBodyRevision = nil
    state.invalidFrontMatterBaseMetadataRevision = nil
    state.invalidFrontMatterRecoveryOwnerWindowID = nil
    state.invalidFrontMatterRecoveryVersion = nil
    publishingStore.markdownEditorSessionStates[draftID] = state
    scheduleAutosave()
    return projecting(recovery, into: state, ownerWindowID: windowID)
  }

  private func mergedInvalidFrontMatterRecovery(
    _ incoming: MarkdownEditorSessionState,
    existing: MarkdownEditorSessionState?,
    windowID: UUID?
  ) -> MarkdownEditorSessionState {
    var result = incoming
    var records = existing?.invalidFrontMatterRecoveryRecords ?? [:]
    if let ownerWindowID = windowID {
      if let document = incoming.invalidFrontMatterDocument, !document.isEmpty {
        let previous = records[ownerWindowID]
        records[ownerWindowID] = MarkdownInvalidFrontMatterRecovery(
          document: document,
          baseBodyMarkdown: incoming.invalidFrontMatterBaseBodyMarkdown,
          baseBodyRevision: incoming.invalidFrontMatterBaseBodyRevision,
          baseMetadataRevision: incoming.invalidFrontMatterBaseMetadataRevision,
          version: previous?.document == document
            ? (previous?.version ?? 1) : (previous?.version ?? 0) &+ 1
        )
        result.invalidFrontMatterRecoveryOwnerWindowID = ownerWindowID
        result.invalidFrontMatterRecoveryVersion = records[ownerWindowID]?.version
      } else {
        records.removeValue(forKey: ownerWindowID)
      }
    }
    result.invalidFrontMatterRecoveryRecords = records.isEmpty ? nil : records

    // Preserve an unclaimed legacy payload until a window explicitly claims
    // it. Once records exist, scalar payloads are only compatibility mirrors.
    if let existing,
      existing.invalidFrontMatterRecoveryOwnerWindowID == nil,
      existing.invalidFrontMatterDocument?.isEmpty == false,
      incoming.invalidFrontMatterDocument?.isEmpty != false
    {
      result = preservingRecovery(existing, in: result)
      result.invalidFrontMatterRecoveryRecords = records.isEmpty ? nil : records
    }
    return result
  }

  private func preservingRecovery(
    _ recovery: MarkdownEditorSessionState,
    in state: MarkdownEditorSessionState
  ) -> MarkdownEditorSessionState {
    var result = state
    result.invalidFrontMatterDocument = recovery.invalidFrontMatterDocument
    result.invalidFrontMatterBaseBodyMarkdown = recovery.invalidFrontMatterBaseBodyMarkdown
    result.invalidFrontMatterBaseBodyRevision = recovery.invalidFrontMatterBaseBodyRevision
    result.invalidFrontMatterBaseMetadataRevision = recovery.invalidFrontMatterBaseMetadataRevision
    result.invalidFrontMatterRecoveryOwnerWindowID =
      recovery.invalidFrontMatterRecoveryOwnerWindowID
    result.invalidFrontMatterRecoveryVersion = recovery.invalidFrontMatterRecoveryVersion
    return result
  }

  private func projecting(
    _ recovery: MarkdownInvalidFrontMatterRecovery,
    into state: MarkdownEditorSessionState,
    ownerWindowID: UUID
  ) -> MarkdownEditorSessionState {
    var result = state
    result.invalidFrontMatterDocument = recovery.document
    result.invalidFrontMatterBaseBodyMarkdown = recovery.baseBodyMarkdown
    result.invalidFrontMatterBaseBodyRevision = recovery.baseBodyRevision
    result.invalidFrontMatterBaseMetadataRevision = recovery.baseMetadataRevision
    result.invalidFrontMatterRecoveryOwnerWindowID = ownerWindowID
    result.invalidFrontMatterRecoveryVersion = recovery.version
    return result
  }

}
