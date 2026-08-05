import Foundation

public struct DraftBodyEditorBuffer: Hashable, Sendable {
  public var draftID: UUID
  public var bodyMarkdown: String
  public var revision: UInt64
  public var isDirty: Bool

  public init(draftID: UUID, bodyMarkdown: String, revision: UInt64, isDirty: Bool) {
    self.draftID = draftID
    self.bodyMarkdown = bodyMarkdown
    self.revision = revision
    self.isDirty = isDirty
  }
}

public struct DraftBodyEditorBufferStageResult: Hashable, Sendable {
  public var buffer: DraftBodyEditorBuffer
  public var wasAccepted: Bool

  public init(buffer: DraftBodyEditorBuffer, wasAccepted: Bool) {
    self.buffer = buffer
    self.wasAccepted = wasAccepted
  }
}

struct DraftOperationBaseline: Equatable, Sendable {
  let draft: ArticleDraft
  let bodyRevision: UInt64
}

extension WorkbenchStore {
  func draftOperationBaseline(for draftID: UUID) -> DraftOperationBaseline? {
    guard let draft = drafts.first(where: { $0.id == draftID }) else { return nil }
    return DraftOperationBaseline(
      draft: draft,
      bodyRevision: draftBodyEditorBuffer(for: draftID).revision
    )
  }

  func draftStillMatchesOperationBaseline(_ baseline: DraftOperationBaseline) -> Bool {
    guard drafts.first(where: { $0.id == baseline.draft.id }) == baseline.draft else {
      return false
    }
    let buffer = draftBodyEditorBuffer(for: baseline.draft.id)
    return !buffer.isDirty && buffer.revision == baseline.bodyRevision
  }

  public func draftBodyEditorBuffer(for draftID: UUID) -> DraftBodyEditorBuffer {
    if let buffer = publishingStore.draftBodyEditorBuffers[draftID] {
      return buffer
    }

    return DraftBodyEditorBuffer(
      draftID: draftID,
      bodyMarkdown: drafts.first(where: { $0.id == draftID })?.bodyMarkdown ?? "",
      revision: 0,
      isDirty: false
    )
  }

  @discardableResult
  public func stageDraftBody(
    _ bodyMarkdown: String,
    for draftID: UUID,
    baseRevision: UInt64,
    replacingBaseBody baseBodyMarkdown: String? = nil,
    notifyEditorObservers: Bool = true
  ) -> DraftBodyEditorBufferStageResult? {
    guard drafts.contains(where: { $0.id == draftID }) else { return nil }

    let current = draftBodyEditorBuffer(for: draftID)
    let canRebaseUnchangedBody = baseBodyMarkdown == current.bodyMarkdown
    guard baseRevision == current.revision
      || bodyMarkdown == current.bodyMarkdown
      || canRebaseUnchangedBody
    else {
      return DraftBodyEditorBufferStageResult(buffer: current, wasAccepted: false)
    }

    guard bodyMarkdown != current.bodyMarkdown else {
      return DraftBodyEditorBufferStageResult(buffer: current, wasAccepted: true)
    }

    let staged = DraftBodyEditorBuffer(
      draftID: draftID,
      bodyMarkdown: bodyMarkdown,
      revision: current.revision &+ 1,
      isDirty: true
    )
    if let draft = drafts.first(where: { $0.id == draftID }) {
      recordDraftRecovery(for: draft, bodyMarkdown: bodyMarkdown)
    }
    publishingStore.setDraftBodyEditorBuffer(
      staged,
      for: draftID,
      notifyObservers: notifyEditorObservers
    )
    persistenceStore.markUnsavedChanges()
    scheduleDraftBodyCommit(for: draftID)
    return DraftBodyEditorBufferStageResult(buffer: staged, wasAccepted: true)
  }

  @discardableResult
  public func replaceDraftBody(
    _ bodyMarkdown: String,
    for draftID: UUID,
    expectedRevision: UInt64,
    notifyEditorObservers: Bool = true
  ) -> DraftBodyEditorBufferStageResult? {
    stageDraftBody(
      bodyMarkdown,
      for: draftID,
      baseRevision: expectedRevision,
      notifyEditorObservers: notifyEditorObservers
    )
  }

  public func flushDraftBodyEditorBuffer(for draftID: UUID) {
    draftBodyCommitTasks[draftID]?.cancel()
    draftBodyCommitTasks[draftID] = nil
    draftBodyCommitFirstStagedAt[draftID] = nil

    guard var buffer = publishingStore.draftBodyEditorBuffers[draftID], buffer.isDirty else { return }
    guard var draft = drafts.first(where: { $0.id == draftID }) else {
      publishingStore.removeDraftBodyEditorBuffer(for: draftID)
      return
    }

    let imageInputsDidChange = ImageWorkbenchMarkdownReferenceSignature(
      markdown: draft.bodyMarkdown
    ) != ImageWorkbenchMarkdownReferenceSignature(markdown: buffer.bodyMarkdown)
    draft.bodyMarkdown = buffer.bodyMarkdown
    publishingStore.updateDraft(draft, store: self)
    buffer.isDirty = false
    publishingStore.setDraftBodyEditorBuffer(buffer, for: draftID)
    invalidateBodyEditingDerivedCaches(
      for: draftID,
      imageInputsDidChange: imageInputsDidChange
    )
  }

  public func flushDraftBodyEditorBuffers() {
    for draftID in Array(publishingStore.draftBodyEditorBuffers.keys) {
      flushDraftBodyEditorBuffer(for: draftID)
    }
  }

  func discardDraftBodyEditorBuffer(for draftID: UUID) {
    draftBodyCommitTasks[draftID]?.cancel()
    draftBodyCommitTasks[draftID] = nil
    draftBodyCommitFirstStagedAt[draftID] = nil
    publishingStore.removeDraftBodyEditorBuffer(for: draftID)
  }

  private func scheduleDraftBodyCommit(for draftID: UUID) {
    draftBodyCommitTasks[draftID]?.cancel()
    let now = Date()
    let firstStagedAt = draftBodyCommitFirstStagedAt[draftID] ?? now
    draftBodyCommitFirstStagedAt[draftID] = firstStagedAt
    let idleDelayNanoseconds: UInt64 = 1_500_000_000
    let maximumDelayNanoseconds = UInt64(max(
      0,
      firstStagedAt.addingTimeInterval(5).timeIntervalSince(now) * 1_000_000_000
    ))
    let delayNanoseconds = min(idleDelayNanoseconds, maximumDelayNanoseconds)
    draftBodyCommitTasks[draftID] = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: delayNanoseconds)
      } catch {
        return
      }
      guard !Task.isCancelled, let self else { return }
      self.draftBodyCommitTasks[draftID] = nil
      self.flushDraftBodyEditorBuffer(for: draftID)
    }
  }

  func synchronizeDraftBodyEditorBuffer(with draft: ArticleDraft) {
    guard var buffer = publishingStore.draftBodyEditorBuffers[draft.id] else {
      publishingStore.setDraftBodyEditorBuffer(DraftBodyEditorBuffer(
        draftID: draft.id,
        bodyMarkdown: draft.bodyMarkdown,
        revision: 1,
        isDirty: false
      ), for: draft.id)
      return
    }
    guard !buffer.isDirty, buffer.bodyMarkdown != draft.bodyMarkdown else {
      return
    }
    buffer.bodyMarkdown = draft.bodyMarkdown
    buffer.revision &+= 1
    publishingStore.setDraftBodyEditorBuffer(buffer, for: draft.id)
  }
}
