import Combine
import Foundation

@MainActor
public final class WorkbenchPublishingFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()
  public let editorDisplayModePublisher: AnyPublisher<EditorDisplayMode, Never>

  init(store: WorkbenchStore) {
    self.store = store
    editorDisplayModePublisher = store.publishingStore.$editorDisplayMode.eraseToAnyPublisher()
    store.publishingStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    store.publishingStore.draftBodyEditorBufferWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }

  public var profiles: [SiteProfile] {
    store.profiles
  }

  public var activeProfileID: UUID {
    store.activeProfileID
  }

  public var activeProfile: SiteProfile {
    store.activeProfile
  }

  public var drafts: [ArticleDraft] {
    store.drafts
  }

  public var selectedSection: WorkspaceSection {
    store.selectedSection
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

  public func draftBodyEditorBuffer(for draftID: UUID) -> DraftBodyEditorBuffer {
    store.draftBodyEditorBuffer(for: draftID)
  }

  public var visibleDrafts: [ArticleDraft] {
    store.visibleDrafts
  }

  public func profile(for draft: ArticleDraft) -> SiteProfile {
    store.profile(for: draft)
  }

  public func selectDraft(_ id: UUID?) {
    store.selectDraft(id)
  }

  public func selectProfile(_ id: UUID) {
    store.selectProfile(id)
  }

  public func selectSection(_ section: WorkspaceSection) {
    store.selectSection(section)
  }

  @discardableResult
  public func ensureEditableDraftSelected() -> ArticleDraft? {
    store.ensureEditableDraftSelected()
  }

  @discardableResult
  public func focusDraft(_ id: UUID, section: WorkspaceSection? = nil) -> Bool {
    store.focusDraft(id, section: section)
  }

  public func updateDraft(_ draft: ArticleDraft) {
    store.updateDraft(draft)
  }

  public func runPreflight() {
    store.runPreflight()
  }

  public func refreshPublishPreview(for draft: ArticleDraft? = nil) {
    store.refreshPublishPreview(for: draft)
  }

  public func refreshPublishPreviewInBackground(for draft: ArticleDraft? = nil) {
    store.refreshPublishPreviewInBackground(for: draft)
  }

  public var isPublishPreviewRefreshing: Bool {
    store.publishingStore.isPublishPreviewRefreshing
  }

  public func save() {
    store.save()
  }

  public func activeEditorSelectionRange(for draft: ArticleDraft) -> NSRange? {
    store.activeEditorSelectionRange(for: draft)
  }

  public func package(for draft: ArticleDraft) -> PublishPackage {
    store.publishingPackage(for: draft)
  }

  public func preflightIssues(
    for draft: ArticleDraft,
    includeRepositoryReadiness: Bool = true
  ) -> [PreflightIssue] {
    store.preflightIssues(
      for: draft,
      includeRepositoryReadiness: includeRepositoryReadiness
    )
  }

  public func refreshImageWorkbenchReport() {
    store.refreshImageWorkbenchReport()
  }

  public func imageWorkbenchReport(for draft: ArticleDraft) -> ImageWorkbenchReport {
    store.imageWorkbenchReport(for: draft)
  }

  public func relatedArticleSuggestions(
    for draft: ArticleDraft,
    limit: Int = 5
  ) -> [SiteRelationSuggestion] {
    store.relatedArticleSuggestions(for: draft, limit: limit)
  }

  public var preflightIssues: [PreflightIssue] {
    store.preflightIssues
  }

  public func refreshBatchPublishPlanInBackground() {
    store.refreshBatchPublishPlanInBackground()
  }

  public var batchPublishPlan: BatchPublishPlan? {
    store.batchPublishPlan
  }
}
