import Foundation

extension WorkbenchStore {
  /// Activates the draft remembered by a key window without flushing editor
  /// buffers staged by other windows. The shared PublishingStore remains the
  /// compatibility context until sidebar, editor, Inspector, preview, and
  /// publishing projections can move to one window-owned context atomically.
  @discardableResult
  public func activateDraftSelectionContext(_ id: UUID?) -> UUID? {
    guard let id else {
      if let selectedDraftID {
        flushDraftBodyEditorBuffer(for: selectedDraftID)
      }
      publishingStore.selectDraft(nil, store: self)
      return nil
    }
    guard let draft = drafts.first(where: { $0.id == id }) else {
      let fallbackDraft = selectedDraft ?? writingDrafts.first
      guard let fallbackDraft else {
        publishingStore.selectDraft(nil, store: self)
        return nil
      }
      return activateDraftSelectionContext(fallbackDraft.id)
    }

    if selectedDraftID != draft.id, let selectedDraftID {
      flushDraftBodyEditorBuffer(for: selectedDraftID)
    }
    if draft.isGeneralDraft {
      publishingStore.draftListContentScope = .general
    } else {
      publishingStore.activeProfileID = draft.siteProfileID
      publishingStore.draftListContentScope = .currentSite
    }
    if selectedDraftID != draft.id {
      publishingStore.selectDraft(draft.id, store: self)
    }
    return draft.id
  }

}
