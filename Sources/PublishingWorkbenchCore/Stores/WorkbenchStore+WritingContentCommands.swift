import Foundation

extension WorkbenchStore {
  public func makeVideoAttachment(from url: URL, draft: ArticleDraft) -> DraftAttachment {
    let filename = url.lastPathComponent.nilIfEmpty ?? "video-\(UUID().uuidString).mp4"
    let byteSize = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0
    let profile = profile(for: draft)
    return DraftAttachment(
      originalFilename: filename,
      relativePublishPath: profile.publicVideoPath(filename: filename, draft: draft),
      repositoryPath: profile.videoRepositoryPath(filename: filename, draft: draft),
      byteSize: byteSize,
      sourceFilePath: url.path
    )
  }

  public func runPreflight() {
    flushDraftBodyEditorBuffers()
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
    flushDraftBodyEditorBuffers()
    publishingStore.refreshPublishPreview(for: draft, store: self)
  }

  public func refreshPublishPreviewInBackground(for draft: ArticleDraft? = nil) {
    flushDraftBodyEditorBuffers()
    publishingStore.schedulePublishPreviewRefresh(for: draft, store: self)
  }

  public func refreshBatchPublishPlan() {
    flushDraftBodyEditorBuffers()
    publishingStore.refreshBatchPublishPlan(store: self)
  }

  public func refreshBatchPublishPlanInBackground() {
    flushDraftBodyEditorBuffers()
    publishingStore.scheduleBatchPublishPlanRefresh(store: self)
  }

  public func refreshBatchPublishPlanAsync() async {
    refreshBatchPublishPlanInBackground()
    await publishingStore.waitForBatchPublishPlanRefresh()
  }

  public func publishingPackage(for draft: ArticleDraft) -> PublishPackage {
    flushDraftBodyEditorBuffer(for: draft.id)
    let currentDraft = drafts.first(where: { $0.id == draft.id }) ?? draft
    return publishingStore.publishingPackage(for: currentDraft, store: self)
  }

  public func localPublishPreview(for draft: ArticleDraft) -> LocalPublishPreview {
    flushDraftBodyEditorBuffer(for: draft.id)
    let currentDraft = drafts.first(where: { $0.id == draft.id }) ?? draft
    return publishingStore.localPublishPreview(for: currentDraft, store: self)
  }

  public func cachedLocalPublishPreview(for draft: ArticleDraft) -> LocalPublishPreview? {
    guard publishPackage?.draftID == draft.id else { return nil }
    return localPublishPreview
  }

  public func cachedRemotePublishPreview(for draft: ArticleDraft) -> RemoteRepositoryPublishPreview? {
    guard publishPackage?.draftID == draft.id else { return nil }
    return remotePublishPreviewSnapshot
  }

  public func cachedRemoteReviewDraft(for draft: ArticleDraft) -> RemoteReviewDraft? {
    guard publishPackage?.draftID == draft.id else { return nil }
    return remoteReviewDraft
  }

  public func localSitePreviewPlan(for draft: ArticleDraft) -> LocalSitePreviewPlan? {
    publishingStore.localSitePreviewPlan(for: draft, store: self)
  }

  public func localSitePreviewURL(for draft: ArticleDraft) -> URL? {
    publishingStore.localSitePreviewURL(for: draft, store: self)
  }

  public func repositoryReport(for draft: ArticleDraft) -> RepositoryScanReport? {
    repositoryReport(for: profile(for: draft))
  }

  public func repositoryReport(for profile: SiteProfile) -> RepositoryScanReport? {
    repositoryStore.repositoryReport(for: profile, store: self)
  }

  public func remoteReviewDraft(for draft: ArticleDraft) -> RemoteReviewDraft {
    flushDraftBodyEditorBuffer(for: draft.id)
    let currentDraft = drafts.first(where: { $0.id == draft.id }) ?? draft
    return publishingStore.remoteReviewDraft(for: currentDraft, store: self)
  }

  public func draftComparisonContent(for draft: ArticleDraft) -> DraftComparisonContent {
    publishingStore.draftComparisonContent(for: draft, store: self)
  }

  public func publishingAIPrompt(for draft: ArticleDraft) -> String {
    publishingStore.publishingAIPrompt(for: draft, store: self)
  }

  /// Builds file-system-backed publishing context away from the main actor
  /// before formatting the clipboard prompt.
  public func publishingAIPromptInBackground(for draft: ArticleDraft) async -> String {
    let artifacts = await aiPublishingRequestArtifacts(for: draft)
    return publishingStore.publishingAIPrompt(from: artifacts, store: self)
  }

  public func selectDraft(_ id: UUID?) {
    flushDraftBodyEditorBuffers()
    publishingStore.selectDraft(id, store: self)
  }

  @discardableResult
  public func ensureEditableDraftSelected() -> ArticleDraft? {
    publishingStore.ensureEditableDraftSelected(store: self)
  }

  /// Adds any missing software guides to the active site without replacing
  /// user content. Guide identity is independent from editable slugs, and a
  /// colliding user slug is resolved by suffixing the new guide.
  @discardableResult
  public func installSoftwareGuides() -> Int {
    flushDraftBodyEditorBuffers()
    let guides = ArticleDraft.samples(profile: activeProfile)
    let installedGuideIDs = Set(visibleDrafts.compactMap(\.softwareGuideID))
    var occupiedSlugs = Set(visibleDrafts.map { normalizedSoftwareGuideSlug($0.slug) })
    let missingGuides = guides
      .filter { guide in
        guard let guideID = guide.softwareGuideID else { return false }
        return !installedGuideIDs.contains(guideID)
      }
      .map { guide in
        var resolvedGuide = guide
        let baseSlug = guide.slug
        var candidateSlug = baseSlug
        var suffix = 2
        while occupiedSlugs.contains(normalizedSoftwareGuideSlug(candidateSlug)) {
          candidateSlug = "\(baseSlug)-\(suffix)"
          suffix += 1
        }
        resolvedGuide.slug = candidateSlug
        occupiedSlugs.insert(normalizedSoftwareGuideSlug(candidateSlug))
        return resolvedGuide
      }

    if !missingGuides.isEmpty {
      publishingStore.drafts.insert(contentsOf: missingGuides, at: 0)
    }

    if let firstGuideID = guides.first?.softwareGuideID,
       let firstGuide = visibleDrafts.first(where: { $0.softwareGuideID == firstGuideID }) {
      setAIPublishingAssistantPresented(false)
      _ = publishingStore.focusDraft(firstGuide.id, section: .writing, store: self)
    }

    if !missingGuides.isEmpty {
      save()
    }
    return missingGuides.count
  }

  private func normalizedSoftwareGuideSlug(_ slug: String) -> String {
    slug.trimmedForPublishing.lowercased()
  }

  public func requestEditorFocus(
    draftID: UUID,
    field: String?,
    query: String? = nil,
    selectedRange: NSRange? = nil
  ) {
    publishingStore.requestEditorFocus(
      draftID: draftID,
      field: field,
      query: query,
      selectedRange: selectedRange,
      store: self
    )
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

  public func saveCustomMarkdownSnippet(_ snippet: MarkdownSnippet) {
    guard let siteProfileID = snippet.siteProfileID,
          profiles.contains(where: { $0.id == siteProfileID }) else {
      return
    }
    publishingStore.customMarkdownSnippets = MarkdownSnippetLibraryService.savingCustomSnippet(
      id: snippet.id,
      title: snippet.title,
      detail: snippet.detail,
      kind: snippet.kind,
      markdown: snippet.markdown,
      siteProfileID: siteProfileID,
      in: publishingStore.customMarkdownSnippets
    )
    scheduleAutosave()
  }

  public func deleteCustomMarkdownSnippet(id: String, siteProfileID: UUID) {
    guard publishingStore.customMarkdownSnippets.contains(where: {
      $0.id == id && $0.siteProfileID == siteProfileID
    }) else {
      return
    }
    publishingStore.customMarkdownSnippets = MarkdownSnippetLibraryService.removingCustomSnippet(
      id: id,
      from: publishingStore.customMarkdownSnippets
    )
    scheduleAutosave()
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

  public func createGeneralDraft() {
    publishingStore.createGeneralDraft(store: self)
    invalidateDraftDerivedCaches()
  }

  public func setDraftListContentScope(_ scope: DraftListContentScope) {
    flushDraftBodyEditorBuffers()
    publishingStore.setDraftListContentScope(scope, store: self)
    invalidateDraftDerivedCaches()
  }

  public func updateDraft(_ draft: ArticleDraft) {
    let buffer = draftBodyEditorBuffer(for: draft.id)
    var bufferedDraft = draft
    if buffer.isDirty {
      bufferedDraft.bodyMarkdown = buffer.bodyMarkdown
    }

    let previousDraft = drafts.first { $0.id == bufferedDraft.id }
    var previousWithoutBody = previousDraft
    previousWithoutBody?.bodyMarkdown = ""
    var updatedWithoutBody = bufferedDraft
    updatedWithoutBody.bodyMarkdown = ""
    let isBodyOnlyEdit = previousDraft != nil && previousWithoutBody == updatedWithoutBody
    publishingStore.updateDraft(bufferedDraft, store: self)
    if !buffer.isDirty, previousDraft?.bodyMarkdown != bufferedDraft.bodyMarkdown {
      synchronizeDraftBodyEditorBuffer(with: bufferedDraft)
    }
    if isBodyOnlyEdit {
      invalidateBodyEditingDerivedCaches(for: bufferedDraft.id)
    } else {
      invalidateDraftDerivedCaches()
    }
  }

  /// Applies a draft value originating from a live editor binding.
  ///
  /// Independent windows can retain an older value while another window edits
  /// the same article. The timestamp is the editor's optimistic-lock token: a
  /// stale metadata write is rejected instead of replacing newer fields. Body
  /// text has its own revisioned buffer and remains protected there.
  @discardableResult
  public func updateDraftFromEditor(_ draft: ArticleDraft) -> Bool {
    guard let current = drafts.first(where: { $0.id == draft.id }) else {
      updateDraft(draft)
      return true
    }
    guard draft.updatedAt == current.updatedAt else {
      setPublishActionMessage(CoreL10n.text("另一窗口已更新这篇文章，刚才的陈旧元数据未写入；编辑器已同步到最新版本。"))
      persistenceStore.markStatus("编辑冲突：已保留另一窗口的最新版本")
      return false
    }
    updateDraft(draft)
    return true
  }

  public func deleteSelectedDraft() {
    publishingStore.deleteSelectedDraft(store: self)
    invalidateDraftDerivedCaches()
  }

  public func deleteDraft(id draftID: UUID) {
    discardDraftBodyEditorBuffer(for: draftID)
    publishingStore.deleteDraft(id: draftID, store: self)
    invalidateDraftDerivedCaches()
  }

  public func versions(for draftID: UUID) -> [DraftVersionSnapshot] {
    publishingStore.versions(for: draftID)
  }

  @discardableResult
  public func createManualVersion(for draftID: UUID) -> Bool {
    flushDraftBodyEditorBuffer(for: draftID)
    return publishingStore.createManualVersion(for: draftID, store: self)
  }

  @discardableResult
  func recordVersionsBeforeBatchProcessing(draftIDs: Set<UUID>) -> Int {
    flushDraftBodyEditorBuffers()
    return publishingStore.recordVersionsBeforeBatchProcessing(
      draftIDs: draftIDs,
      store: self
    )
  }

  @discardableResult
  public func restoreDraftVersion(_ versionID: UUID) -> Bool {
    flushDraftBodyEditorBuffers()
    let restored = publishingStore.restoreDraftVersion(versionID, store: self)
    if restored {
      invalidateDraftDerivedCaches()
    }
    return restored
  }

  @discardableResult
  public func restoreRecycledDraft(_ draftID: UUID) -> Bool {
    let restored = publishingStore.restoreRecycledDraft(draftID, store: self)
    if restored {
      invalidateDraftDerivedCaches()
    }
    return restored
  }

  @discardableResult
  public func permanentlyDeleteRecycledDraft(_ draftID: UUID) -> Bool {
    publishingStore.permanentlyDeleteRecycledDraft(draftID, store: self)
  }

  public var pendingRepositoryCleanupRequests: [DraftRepositoryCleanupRequest] {
    publishingStore.pendingRepositoryCleanupRequests()
  }

  public func repositoryCleanupPreview(for requestID: UUID) -> LocalPublishPreview? {
    publishingStore.repositoryCleanupPreview(for: requestID)
  }

  @discardableResult
  public func performLocalRepositoryCleanup(
    _ requestID: UUID,
    preview: LocalPublishPreview? = nil
  ) -> Bool {
    publishingStore.performLocalRepositoryCleanup(requestID, preview: preview, store: self)
  }

  @discardableResult
  public func keepRepositoryFile(_ requestID: UUID) -> Bool {
    publishingStore.keepRepositoryFile(requestID, store: self)
  }

  public func focusDraft(_ id: UUID, section: WorkspaceSection? = nil) -> Bool {
    flushDraftBodyEditorBuffers()
    return publishingStore.focusDraft(id, section: section, store: self)
  }

  public var canNavigateBackwardInDraftHistory: Bool {
    publishingStore.canNavigateBackwardInDraftHistory
  }

  public var canNavigateForwardInDraftHistory: Bool {
    publishingStore.canNavigateForwardInDraftHistory
  }

  @discardableResult
  public func navigateBackwardInDraftHistory() -> Bool {
    flushDraftBodyEditorBuffers()
    return publishingStore.navigateBackwardInDraftHistory(store: self)
  }

  @discardableResult
  public func navigateForwardInDraftHistory() -> Bool {
    flushDraftBodyEditorBuffers()
    return publishingStore.navigateForwardInDraftHistory(store: self)
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

  public var contentHealthReport: ContentHealthReport {
    publishingStore.contentHealthReport(store: self)
  }

  public func contentHealthReportAsync() async throws -> ContentHealthReport {
    try await publishingStore.contentHealthReportAsync(store: self)
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
