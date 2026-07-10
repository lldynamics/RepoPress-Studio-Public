import Foundation

extension WorkbenchStore {
  public func runPreflight() {
    preflightRefreshTask?.cancel()
    preflightRefreshTask = nil
    publishingStore.runPreflight(store: self)
    invalidateDraftDerivedCaches()
  }

  func schedulePreflightRefresh() {
    preflightRefreshTask?.cancel()
    preflightRefreshTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 600_000_000)
      } catch {
        return
      }
      guard !Task.isCancelled, let self else {
        return
      }
      self.preflightRefreshTask = nil
      self.runPreflight()
    }
  }

  public func refreshPublishPreview(for draft: ArticleDraft? = nil) {
    publishingStore.refreshPublishPreview(for: draft, store: self)
  }

  public func refreshBatchPublishPlan() {
    publishingStore.refreshBatchPublishPlan(store: self)
  }

  public func publishingPackage(for draft: ArticleDraft) -> PublishPackage {
    publishingStore.publishingPackage(for: draft, store: self)
  }

  public func localPublishPreview(for draft: ArticleDraft) -> LocalPublishPreview {
    publishingStore.localPublishPreview(for: draft, store: self)
  }

  public func localSitePreviewPlan(for draft: ArticleDraft) -> LocalSitePreviewPlan? {
    publishingStore.localSitePreviewPlan(for: draft, store: self)
  }

  public func repositoryReport(for draft: ArticleDraft) -> RepositoryScanReport? {
    repositoryReport(for: profile(for: draft))
  }

  public func repositoryReport(for profile: SiteProfile) -> RepositoryScanReport? {
    repositoryStore.repositoryReport(for: profile, store: self)
  }

  public func remoteReviewDraft(for draft: ArticleDraft) -> RemoteReviewDraft {
    publishingStore.remoteReviewDraft(for: draft, store: self)
  }

  public func draftComparisonContent(for draft: ArticleDraft) -> DraftComparisonContent {
    publishingStore.draftComparisonContent(for: draft, store: self)
  }

  public func publishingAIPrompt(for draft: ArticleDraft) -> String {
    publishingStore.publishingAIPrompt(for: draft, store: self)
  }

  public func selectDraft(_ id: UUID?) {
    publishingStore.selectDraft(id, store: self)
  }

  @discardableResult
  public func ensureEditableDraftSelected() -> ArticleDraft? {
    publishingStore.ensureEditableDraftSelected(store: self)
  }

  public func requestEditorFocus(draftID: UUID, field: String?, query: String? = nil) {
    publishingStore.requestEditorFocus(draftID: draftID, field: field, query: query, store: self)
  }

  public func updateActiveEditorSelection(
    draftID: UUID,
    selectedRange: NSRange,
    selectedText: String,
    bodyUTF16Count: Int
  ) {
    publishingStore.updateActiveEditorSelection(
      draftID: draftID,
      selectedRange: selectedRange,
      selectedText: selectedText,
      bodyUTF16Count: bodyUTF16Count
    )
  }

  public func clearActiveEditorSelection(for draftID: UUID? = nil) {
    publishingStore.clearActiveEditorSelection(for: draftID)
  }

  public func activeEditorSelectionRange(for draft: ArticleDraft) -> NSRange? {
    publishingStore.activeEditorSelectionRange(for: draft)
  }

  public func setEditorDisplayMode(_ mode: EditorDisplayMode) {
    publishingStore.editorDisplayMode = mode
  }

  public func setInspectorPresented(_ isPresented: Bool) {
    publishingStore.isInspectorPresented = isPresented
  }

  public func setAutomaticallyRefreshPreflightOnEdit(_ isEnabled: Bool) {
    publishingStore.automaticallyRefreshPreflightOnEdit = isEnabled
  }

  public func setLastSaveStatus(_ status: String) {
    persistenceStore.markStatus(status)
  }

  public func recordPersistenceSaveSucceeded(backupWarning: String? = nil) {
    persistenceStore.recordSuccess(backupWarning: backupWarning)
  }

  public func recordPersistenceSaveFailed(_ error: Error) {
    persistenceStore.recordFailure(error)
  }

  public func dismissPersistenceRecoveryMessage() {
    persistenceStore.setRecoveryMessage(nil)
  }

  public func createDraft() {
    publishingStore.createDraft(store: self)
    invalidateDraftDerivedCaches()
  }

  public func updateDraft(_ draft: ArticleDraft) {
    let previousDraft = drafts.first { $0.id == draft.id }
    var previousWithoutBody = previousDraft
    previousWithoutBody?.bodyMarkdown = ""
    var updatedWithoutBody = draft
    updatedWithoutBody.bodyMarkdown = ""
    let isBodyOnlyEdit = previousDraft != nil && previousWithoutBody == updatedWithoutBody
    publishingStore.updateDraft(draft, store: self)
    if isBodyOnlyEdit {
      invalidateBodyEditingDerivedCaches(for: draft.id)
    } else {
      invalidateDraftDerivedCaches()
    }
  }

  public func deleteSelectedDraft() {
    publishingStore.deleteSelectedDraft(store: self)
    invalidateDraftDerivedCaches()
  }

  public func deleteDraft(id draftID: UUID) {
    publishingStore.deleteDraft(id: draftID, store: self)
    invalidateDraftDerivedCaches()
  }

  public func focusDraft(_ id: UUID, section: WorkspaceSection? = nil) -> Bool {
    publishingStore.focusDraft(id, section: section, store: self)
  }

  public func restoreSEOSocialPreviewSnapshotForCurrentSelection() {
    aiStore.restoreSEOSocialPreviewSnapshotForCurrentSelection()
  }

  public func preflightIssues(
    for draft: ArticleDraft,
    includeRepositoryReadiness: Bool = true
  ) -> [PreflightIssue] {
    publishingStore.preflightIssues(
      for: draft,
      includeRepositoryReadiness: includeRepositoryReadiness,
      store: self
    )
  }

  public var sitePreflightIssues: [PreflightIssue] {
    publishingStore.sitePreflightIssues(store: self)
  }

  public var contentHealthSummaries: [DraftPreflightSummary] {
    publishingStore.contentHealthSummaries(store: self)
  }

  public var publicRiskSummary: PublicRiskSummary {
    publishingStore.publicRiskSummary(store: self)
  }

  public func publicRiskSummary(for draft: ArticleDraft) -> PublicRiskSummary {
    publishingStore.publicRiskSummary(for: draft, store: self)
  }

  public var publicRiskDraftSummaries: [DraftPreflightSummary] {
    publishingStore.publicRiskDraftSummaries(store: self)
  }

  public var aiFixQueueItems: [AIPublishingFixQueueItem] {
    publishingStore.aiFixQueueItems(store: self)
  }
}
