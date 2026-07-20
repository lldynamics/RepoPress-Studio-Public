import Foundation

extension WorkbenchStore {
  public func generalDraftSourceFieldDiffs(for draft: ArticleDraft) -> [String] {
    publishingStore.generalDraftSourceFieldDiffs(for: draft)
  }

  public var generalDraftLibraryReport: GeneralDraftLibraryReport {
    publishingStore.generalDraftLibraryReport()
  }

  @discardableResult
  public func copyDraft(_ draftID: UUID, toProfileID profileID: UUID) -> ArticleDraft? {
    publishingStore.copyDraft(draftID, toProfileID: profileID, store: self)
  }

  public var canUndoLatestDraftOwnershipTransfer: Bool {
    publishingStore.canUndoLatestDraftOwnershipTransfer
  }

  public func draftOwnershipTransferPlan(
    draftIDs: [UUID],
    operation: DraftOwnershipTransferOperation,
    targetProfileID: UUID? = nil
  ) -> DraftOwnershipTransferPlan {
    flushDraftBodyEditorBuffers()
    return publishingStore.draftOwnershipTransferPlan(
      draftIDs: draftIDs,
      operation: operation,
      targetProfileID: targetProfileID
    )
  }

  @discardableResult
  public func applyDraftOwnershipTransfer(
    _ plan: DraftOwnershipTransferPlan
  ) -> DraftOwnershipTransferResult? {
    flushDraftBodyEditorBuffers()
    return publishingStore.applyDraftOwnershipTransfer(plan, store: self)
  }

  @discardableResult
  public func undoLatestDraftOwnershipTransfer(expectedUndoID: UUID? = nil) -> Bool {
    flushDraftBodyEditorBuffers()
    return publishingStore.undoLatestDraftOwnershipTransfer(
      expectedUndoID: expectedUndoID,
      store: self
    )
  }

}
