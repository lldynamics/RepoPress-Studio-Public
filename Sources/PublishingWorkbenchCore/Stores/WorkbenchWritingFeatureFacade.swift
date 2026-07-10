import Foundation

@MainActor
public final class WorkbenchWritingFeatureFacade {
  private unowned let store: WorkbenchStore

  init(store: WorkbenchStore) {
    self.store = store
  }

  public var profiles: [SiteProfile] {
    store.profiles
  }

  public var activeProfile: SiteProfile {
    store.activeProfile
  }

  public var drafts: [ArticleDraft] {
    store.drafts
  }

  public var visibleDrafts: [ArticleDraft] {
    store.visibleDrafts
  }

  public var selectedDraftID: UUID? {
    store.selectedDraftID
  }

  public var selectedDraft: ArticleDraft? {
    store.selectedDraft
  }

  public var editorDisplayMode: EditorDisplayMode {
    store.editorDisplayMode
  }

  public var editorFocusRequest: EditorFocusRequest? {
    store.editorFocusRequest
  }

  public var activeEditorSelection: ActiveEditorSelection? {
    store.activeEditorSelection
  }

  public var lastSaveStatus: String {
    store.lastSaveStatus
  }

  public func selectDraft(_ id: UUID?) {
    store.selectDraft(id)
  }

  @discardableResult
  public func ensureEditableDraftSelected() -> ArticleDraft? {
    store.ensureEditableDraftSelected()
  }

  public func createDraft() {
    store.createDraft()
  }

  public func updateDraft(_ draft: ArticleDraft) {
    store.updateDraft(draft)
  }

  public func deleteDraft(id draftID: UUID) {
    store.deleteDraft(id: draftID)
  }

  @discardableResult
  public func focusDraft(_ id: UUID, section: WorkspaceSection? = nil) -> Bool {
    store.focusDraft(id, section: section)
  }

  public func save() {
    store.save()
  }
}
