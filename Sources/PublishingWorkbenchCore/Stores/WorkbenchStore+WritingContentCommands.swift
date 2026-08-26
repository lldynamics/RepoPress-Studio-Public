import Foundation

extension WorkbenchStore {
  public func makeVideoAttachment(
    from url: URL,
    draft: ArticleDraft,
    fileStore: ManagedAttachmentFileStore? = nil
  ) async throws -> DraftAttachment {
    let resolvedFileStore = fileStore ?? managedAttachmentFileStore
    let attachmentID = UUID()
    let filename = url.lastPathComponent.nilIfEmpty ?? "video-\(UUID().uuidString).mp4"
    let managedURL = try await Task.detached(priority: .userInitiated) {
      try resolvedFileStore.storeFile(at: url, attachmentID: attachmentID)
    }.value
    do {
      try Task.checkCancellation()
    } catch {
      try resolvedFileStore.discardStoredFile(at: managedURL)
      throw error
    }
    let byteSize =
      ((try? managedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        .map(Int64.init)) ?? 0
    let profile = profile(for: draft)
    return DraftAttachment(
      id: attachmentID,
      originalFilename: filename,
      relativePublishPath: profile.publicVideoPath(filename: filename, draft: draft),
      repositoryPath: profile.videoRepositoryPath(filename: filename, draft: draft),
      byteSize: byteSize,
      sourceFilePath: managedURL.path
    )
  }

  public func runPreflight() {
    let requestedDraftID = selectedDraftID
    schedulePreflightCalculation(
      for: requestedDraftID,
      flushEditorBuffer: true,
      invalidateDerivedCaches: true
    )
  }

  /// Refreshes preflight for a selection change without treating navigation as
  /// a content mutation. Selection is a frequent UI operation, so it must not
  /// flush editor buffers belonging to other windows or invalidate the list,
  /// task-queue, and image-workbench caches for every draft.
  func refreshPreflightForSelection() {
    let requestedDraftID = selectedDraftID
    schedulePreflightCalculation(
      for: requestedDraftID,
      flushEditorBuffer: false,
      invalidateDerivedCaches: false
    )
  }

  private func schedulePreflightCalculation(
    for draftID: UUID?,
    flushEditorBuffer: Bool,
    invalidateDerivedCaches: Bool
  ) {
    if flushEditorBuffer, let draftID {
      flushDraftBodyEditorBuffer(for: draftID)
    }
    preflightRefreshTask?.cancel()
    preflightRefreshGeneration &+= 1
    let generation = preflightRefreshGeneration
    if invalidateDerivedCaches {
      invalidateDraftDerivedCaches()
    }

    guard let draftID else {
      preflightRefreshTask = nil
      publishingStore.preflightIssues = []
      return
    }

    guard selectedDraftID == draftID,
      let selectedDraft = drafts.first(where: { $0.id == draftID })
    else {
      preflightRefreshTask = nil
      if selectedDraftID == draftID {
        publishingStore.preflightIssues = []
      }
      return
    }

    let selectedDraftSnapshot = selectedDraft
    let profileSnapshot = profile(for: selectedDraft)
    let sameSiteDraftsSnapshot = drafts.filter {
      $0.belongs(toSiteProfileID: selectedDraft.siteProfileID)
    }
    let repositoryReportSnapshot = repositoryReport(for: selectedDraft)
    let preflightService = publishingStore.preflightService
    let generalDraftPublishingIssue = publishingStore.generalDraftPublishingIssue

    preflightRefreshTask = Task { [weak self] in
      let calculationTask: Task<[PreflightIssue]?, Never> = Task.detached(priority: .userInitiated)
      {
        guard !Task.isCancelled else { return nil }
        if selectedDraftSnapshot.isGeneralDraft {
          return [generalDraftPublishingIssue]
        }
        let duplicateIndex = PreflightDuplicateIndex(
          drafts: sameSiteDraftsSnapshot,
          profile: profileSnapshot
        )
        let baseIssues = preflightService.run(
          draft: selectedDraftSnapshot,
          allDrafts: sameSiteDraftsSnapshot,
          profile: profileSnapshot,
          repositoryReport: repositoryReportSnapshot,
          includeRepositoryReadiness: true,
          duplicateIndex: duplicateIndex
        )
        return SiteLinkAuditService().report(
          drafts: sameSiteDraftsSnapshot,
          profile: profileSnapshot
        ).mergingPreflightIssues(baseIssues, for: selectedDraftSnapshot)
      }
      let issues: [PreflightIssue]? = await withTaskCancellationHandler(
        operation: {
          await calculationTask.value
        },
        onCancel: {
          calculationTask.cancel()
        })

      guard !Task.isCancelled,
        let issues,
        let self,
        self.preflightRefreshGeneration == generation,
        self.selectedDraftID == draftID,
        let currentDraft = self.drafts.first(where: { $0.id == draftID }),
        currentDraft.hasSamePreflightInput(as: selectedDraftSnapshot),
        self.profile(for: currentDraft) == profileSnapshot,
        self.drafts.filter({
          $0.belongs(toSiteProfileID: currentDraft.siteProfileID)
        }).count == sameSiteDraftsSnapshot.count,
        zip(
          self.drafts.filter({
            $0.belongs(toSiteProfileID: currentDraft.siteProfileID)
          }),
          sameSiteDraftsSnapshot
        ).allSatisfy({ current, snapshot in
          current.id == snapshot.id && current.hasSamePreflightInput(as: snapshot)
        }),
        self.repositoryReport(for: currentDraft) == repositoryReportSnapshot
      else {
        if let self, self.preflightRefreshGeneration == generation {
          self.preflightRefreshTask = nil
        }
        return
      }

      self.publishingStore.preflightIssues = issues
      self.preflightRefreshTask = nil
    }
  }

  /// Starts a background preflight and waits until its result has been applied.
  /// UI editing paths should use `runPreflight()` so the main actor stays free.
  public func runPreflightAndWait() async {
    runPreflight()
    await preflightRefreshTask?.value
  }

  func schedulePreflightRefresh() {
    let requestedDraftID = selectedDraftID
    guard let requestedDraftID else {
      schedulePreflightCalculation(
        for: nil,
        flushEditorBuffer: false,
        invalidateDerivedCaches: true
      )
      return
    }
    schedulePreflightRefresh(for: requestedDraftID)
  }

  func schedulePreflightRefresh(for draftID: UUID) {
    guard selectedDraftID == draftID else { return }
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
      guard self.selectedDraftID == draftID else {
        self.preflightRefreshTask = nil
        return
      }
      self.schedulePreflightCalculation(
        for: draftID,
        flushEditorBuffer: true,
        invalidateDerivedCaches: true
      )
    }
  }

  public func refreshPublishPreview(for draft: ArticleDraft? = nil) {
    let targetDraftID = draft?.id ?? selectedDraftID
    if let targetDraftID {
      flushDraftBodyEditorBuffer(for: targetDraftID)
    }
    publishingStore.refreshPublishPreview(for: draft, store: self)
  }

  public func refreshPublishPreview(for draftID: UUID) {
    if let draft = draft(for: draftID) {
      refreshPublishPreview(for: draft)
    } else {
      publishingStore.refreshPublishPreview(for: draftID, store: self)
    }
  }

  public func refreshPublishPreviewInBackground(for draft: ArticleDraft? = nil) {
    let targetDraftID = draft?.id ?? selectedDraftID
    if let targetDraftID {
      flushDraftBodyEditorBuffer(for: targetDraftID)
    }
    publishingStore.schedulePublishPreviewRefresh(for: draft, store: self)
  }

  /// Refreshes one explicit draft without changing the active profile or
  /// selected draft. The returned value is present only when the complete
  /// input baseline is still current after asynchronous file-system work.
  public func refreshPublishPreview(
    for draftID: UUID
  ) async -> DraftPublishPreviewSnapshot? {
    flushDraftBodyEditorBuffer(for: draftID)
    publishingStore.schedulePublishPreviewRefresh(forDraftID: draftID, store: self)
    await publishingStore.waitForPublishPreviewRefresh(for: draftID)
    return cachedPublishPreview(for: draftID)
  }

  public func cachedPublishPreview(
    for draftID: UUID
  ) -> DraftPublishPreviewSnapshot? {
    guard
      let snapshot = publishingStore.draftPublishPreviewSnapshot(for: draftID),
      let rememberedBaseline = publishingStore.rememberedDraftPublishPreviewInputBaseline(
        for: draftID
      ),
      let currentBaseline = publishingStore.currentDraftPublishPreviewInputBaseline(
        for: draftID,
        store: self
      ),
      rememberedBaseline == currentBaseline
    else {
      return nil
    }
    return snapshot
  }

  public func waitForPublishPreviewRefresh(for draftID: UUID) async {
    await publishingStore.waitForPublishPreviewRefresh(for: draftID)
  }

  public func cancelPublishPreviewRefresh(for draftID: UUID) {
    publishingStore.cancelPublishPreviewRefresh(for: draftID)
  }

  public func refreshPublishPreviewInBackground(for draftID: UUID) {
    flushDraftBodyEditorBuffer(for: draftID)
    publishingStore.schedulePublishPreviewRefresh(for: draftID, store: self)
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
    publishingStore.draftPublishPreviewSnapshot(for: draft.id)?.localPublishPreview
  }

  public func cachedRemotePublishPreview(for draft: ArticleDraft) -> RemoteRepositoryPublishPreview?
  {
    publishingStore.draftPublishPreviewSnapshot(for: draft.id)?.remotePublishPreview
  }

  public func cachedRemoteReviewDraft(for draft: ArticleDraft) -> RemoteReviewDraft? {
    publishingStore.draftPublishPreviewSnapshot(for: draft.id)?.remoteReviewDraft
  }

  public func cachedDraftPublishPreviewSnapshot(
    for draftID: UUID
  ) -> DraftPublishPreviewSnapshot? {
    cachedPublishPreview(for: draftID)
  }

  public func isPublishPreviewRefreshing(for draftID: UUID) -> Bool {
    publishingStore.isPublishPreviewRefreshing(for: draftID)
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
    // Navigation only needs to commit the draft that is leaving the active
    // editor. Buffers staged by another window remain isolated until that
    // window explicitly commits them.
    if let selectedDraftID {
      flushDraftBodyEditorBuffer(for: selectedDraftID)
    }
    publishingStore.selectDraft(id, store: self)
  }

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
    publishingStore.selectDraft(draft.id, store: self)
    return draft.id
  }

  @discardableResult
  public func ensureEditableDraftSelected() -> ArticleDraft? {
    publishingStore.ensureEditableDraftSelected(store: self)
  }

  /// Restores missing guides and refreshes unmodified built-in guides in the
  /// general draft library without replacing customized user content. Guide identity is
  /// independent from editable slugs, and a colliding user slug is resolved by
  /// suffixing the new guide.
  @discardableResult
  public func installSoftwareGuides() -> Int {
    flushDraftBodyEditorBuffers()
    let guides = ArticleDraft.samples(profile: activeProfile)
    let synchronization = ArticleDraft.synchronizeSoftwareGuides(
      in: publishingStore.drafts,
      profile: activeProfile,
      previousSeedVersion: softwareGuideSeedVersion,
      restorePreviouslyRemovedGuides: true
    )
    let shouldPersistSeedVersion =
      softwareGuideSeedVersion < ArticleDraft.currentSoftwareGuideSeedVersion

    if synchronization.drafts != publishingStore.drafts {
      publishingStore.drafts = synchronization.drafts
      invalidateDraftDerivedCaches()
    }

    setDraftListContentScope(.general)
    if let firstGuideID = guides.first?.softwareGuideID,
      let firstGuide = writingDrafts.first(where: { $0.softwareGuideID == firstGuideID })
    {
      setAIPublishingAssistantPresented(false)
      _ = publishingStore.focusDraft(firstGuide.id, section: .writing, store: self)
    }

    softwareGuideSeedVersion = ArticleDraft.currentSoftwareGuideSeedVersion
    if synchronization.addedGuideCount > 0
      || synchronization.refreshedGuideCount > 0
      || shouldPersistSeedVersion
    {
      save()
    }
    return synchronization.addedGuideCount
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
      profiles.contains(where: { $0.id == siteProfileID })
    else {
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
    guard
      publishingStore.customMarkdownSnippets.contains(where: {
        $0.id == id && $0.siteProfileID == siteProfileID
      })
    else {
      return
    }
    publishingStore.customMarkdownSnippets = MarkdownSnippetLibraryService.removingCustomSnippet(
      id: id,
      from: publishingStore.customMarkdownSnippets
    )
    scheduleAutosave()
  }

  public func setInspectorPresented(_ isPresented: Bool) {
    guard publishingStore.isInspectorPresented != isPresented else { return }
    publishingStore.isInspectorPresented = isPresented
  }

  public func setAutomaticallyRefreshPreflightOnEdit(_ isEnabled: Bool) {
    guard publishingStore.automaticallyRefreshPreflightOnEdit != isEnabled else { return }
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
    if bufferedDraft.wordCountNeedsRefresh {
      scheduleDraftWordCountRefresh(
        for: bufferedDraft.id,
        bodyMarkdown: bufferedDraft.bodyMarkdown
      )
    }
    if !buffer.isDirty, previousDraft?.bodyMarkdown != bufferedDraft.bodyMarkdown {
      synchronizeDraftBodyEditorBuffer(with: bufferedDraft)
    }
    if isBodyOnlyEdit {
      let imageInputsDidChange =
        previousDraft.map {
          ImageWorkbenchMarkdownReferenceSignature(markdown: $0.bodyMarkdown)
            != ImageWorkbenchMarkdownReferenceSignature(markdown: bufferedDraft.bodyMarkdown)
        } ?? true
      invalidateBodyEditingDerivedCaches(
        for: bufferedDraft.id,
        imageInputsDidChange: imageInputsDidChange
      )
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
      setPublishActionMessage(
        CoreL10n.text("另一窗口已更新这篇文章，刚才的陈旧元数据未写入；编辑器已同步到最新版本。"),
        status: .warning
      )
      persistenceStore.markStatus("编辑冲突：已保留另一窗口的最新版本")
      return false
    }
    var contentUpdate = draft
    contentUpdate.preserveRepositoryState(from: current)
    updateDraft(contentUpdate)
    return true
  }

  public func deleteSelectedDraft() {
    publishingStore.deleteSelectedDraft(store: self)
    invalidateDraftDerivedCaches()
  }

  public func deleteDraft(id draftID: UUID) {
    discardDraftBodyEditorBuffer(for: draftID)
    cancelSiteDraftFileAutosave(for: draftID)
    publishingStore.deleteDraft(id: draftID, store: self)
    invalidateDraftDerivedCaches()
  }

  @discardableResult
  public func unpublishDraft(id draftID: UUID) async -> RemoteRepositoryPublishResult? {
    discardDraftBodyEditorBuffer(for: draftID)
    cancelSiteDraftFileAutosave(for: draftID)
    let result = await publishingStore.unpublishDraft(id: draftID, store: self)
    invalidateDraftDerivedCaches()
    refreshBatchPublishPlanInBackground()
    return result
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

  public var pendingRemoteRepositoryCleanupRequests: [DraftRepositoryCleanupRequest] {
    publishingStore.pendingRemoteRepositoryCleanupRequests(profileID: activeProfileID)
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

  @discardableResult
  public func acknowledgeRemoteCleanupReviewClosed(_ requestID: UUID) -> Bool {
    publishingStore.acknowledgeRemoteCleanupReviewClosed(
      requestID: requestID,
      store: self
    )
  }

  @discardableResult
  public func publishRepositoryCleanupRequestOnline(
    _ requestID: UUID
  ) async -> RemoteRepositoryPublishResult? {
    let result = await publishingStore.publishRepositoryCleanupRequestOnline(
      requestID,
      store: self
    )
    refreshBatchPublishPlanInBackground()
    return result
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
    imageStore.restoreImageWorkbenchReportProjectionForCurrentSelection()
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
