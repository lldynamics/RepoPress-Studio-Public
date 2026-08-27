import Foundation

extension PublishingStore {
  public func selectDraft(_ id: UUID?, store: WorkbenchStore) {
    if let id, drafts.contains(where: { $0.id == id }) {
      draftNavigationHistory.recordVisit(id)
    }
    selectedDraftID = id
    store.setAIPublishingAssistantPresented(false)
    store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    store.refreshPreflightForSelection()
    store.scheduleImageWorkbenchReportRefresh()
  }

  @discardableResult
  public func ensureEditableDraftSelected(store: WorkbenchStore) -> ArticleDraft? {
    if let selectedDraftID,
      let draft = writingDrafts.first(where: { $0.id == selectedDraftID })
    {
      return draft
    }

    if let draft = store.writingDrafts.first {
      selectedDraftID = draft.id
      store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
      store.runPreflight()
      store.scheduleImageWorkbenchReportRefresh(for: draft)
      return draft
    }

    let previousSection = selectedSection
    let draft =
      draftListContentScope == .general
      ? ArticleDraft.emptyGeneralDraft(editingProfile: store.activeProfile)
      : ArticleDraft.empty(profile: store.activeProfile)
    drafts.insert(draft, at: 0)
    selectedDraftID = draft.id
    selectedSection = previousSection
    store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh(for: draft)
    store.save()
    store.scheduleDraftWordCountRefresh(for: draft.id, bodyMarkdown: draft.bodyMarkdown)
    return draft
  }

  public func requestEditorFocus(
    draftID: UUID,
    field: String?,
    query: String? = nil,
    selectedRange: NSRange? = nil,
    store: WorkbenchStore
  ) {
    if drafts.contains(where: { $0.id == draftID }) {
      draftNavigationHistory.recordVisit(draftID)
    }
    selectedDraftID = draftID
    store.setAIPublishingAssistantPresented(false)
    store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    editorFocusRequest = EditorFocusRequest(
      draftID: draftID,
      field: field,
      query: query,
      selectedRange: selectedRange
    )
  }

  public func updateActiveEditorSelection(
    draftID: UUID,
    selectedRange: NSRange,
    selectedText: String,
    bodyUTF16Count: Int
  ) {
    let selection = ActiveEditorSelection(
      draftID: draftID,
      range: selectedRange,
      selectedText: selectedText,
      bodyUTF16Count: bodyUTF16Count
    )
    if activeEditorSelection != selection {
      let previousDraftID = activeEditorSelection?.draftID
      activeEditorSelection = selection
      if let previousDraftID, previousDraftID != draftID {
        activeEditorSelectionDidChange.send(previousDraftID)
      }
      activeEditorSelectionDidChange.send(draftID)
    }
  }

  public func clearActiveEditorSelection(for draftID: UUID? = nil) {
    guard let activeEditorSelection else {
      return
    }
    guard draftID == nil || activeEditorSelection.draftID == draftID else {
      return
    }
    let clearedDraftID = activeEditorSelection.draftID
    self.activeEditorSelection = nil
    activeEditorSelectionDidChange.send(clearedDraftID)
  }

  public func activeEditorSelectionRange(for draft: ArticleDraft) -> NSRange? {
    activeEditorSelection?.validatedRange(in: draft)
  }

  public func createDraft(store: WorkbenchStore) {
    let draft = ArticleDraft.empty(profile: store.activeProfile)
    drafts.insert(draft, at: 0)
    draftListContentScope = .currentSite
    draftNavigationHistory.recordVisit(draft.id)
    selectedDraftID = draft.id
    selectedSection = .writing
    store.setAIPublishingAssistantPresented(false)
    store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh(for: draft)
    store.save()
    store.scheduleDraftWordCountRefresh(for: draft.id, bodyMarkdown: draft.bodyMarkdown)
  }

  public func createGeneralDraft(store: WorkbenchStore) {
    let draft = ArticleDraft.emptyGeneralDraft(editingProfile: store.activeProfile)
    drafts.insert(draft, at: 0)
    draftListContentScope = .general
    draftNavigationHistory.recordVisit(draft.id)
    selectedDraftID = draft.id
    selectedSection = .writing
    store.setAIPublishingAssistantPresented(false)
    store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh(for: draft)
    store.save()
    store.scheduleDraftWordCountRefresh(for: draft.id, bodyMarkdown: draft.bodyMarkdown)
  }

  public func setDraftListContentScope(_ scope: DraftListContentScope, store: WorkbenchStore) {
    guard draftListContentScope != scope else { return }
    draftListContentScope = scope
    selectedDraftID = writingDrafts.first?.id
    if let selectedDraftID {
      draftNavigationHistory.recordVisit(selectedDraftID)
    }
    store.setAIPublishingAssistantPresented(false)
    store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh(for: store.selectedDraft)
    store.refreshPublishPreviewInBackground(for: store.selectedDraft)
  }

  public func updateDraft(_ draft: ArticleDraft, store: WorkbenchStore) {
    let existingIndex = drafts.firstIndex { $0.id == draft.id }
    let hasUnsavedDraftChange = existingIndex.map { drafts[$0] != draft } ?? true
    var updated = draft
    if let existingIndex,
      drafts[existingIndex].slug.trimmedForPublishing != updated.slug.trimmedForPublishing
    {
      let existing = drafts[existingIndex]
      let profile = store.profile(for: existing)
      let resolver = SiteArticleURLResolver()
      let previousRoute = resolver.relativeWebPath(
        from: profile.markdownPath(for: existing),
        profile: profile,
        permalink: existing.permalink
      )
      let nextRoute = resolver.relativeWebPath(
        from: profile.markdownPath(for: updated),
        profile: profile,
        permalink: updated.permalink
      )
      if previousRoute != nextRoute {
        updated.recordPendingSlugRedirectPath(previousRoute)
        updated.pendingSlugRedirectPaths.removeAll { $0 == nextRoute }
      }
    }
    if hasUnsavedDraftChange,
      let existingIndex,
      drafts[existingIndex].softwareGuideID != nil,
      updated.softwareGuideID == drafts[existingIndex].softwareGuideID
    {
      updated.softwareGuideTemplateVersion = 0
    }
    // Repository CAS state, attachments and other persistence details are
    // intentionally outside the list projection. They may still require
    // content/preflight invalidation, but only a list-visible metadata change
    // advances the list ordering timestamp and its observation boundary.
    let isListMetadataChange = existingIndex.map {
      !drafts[$0].hasSameListMetadata(as: updated)
    } ?? true
    if hasUnsavedDraftChange {
      if let existingIndex {
        updated.markUpdated(replacing: drafts[existingIndex])
      } else {
        updated.markMetadataUpdated()
      }
    }
    if let index = existingIndex {
      if hasUnsavedDraftChange {
        // DraftLifecycleService applies the time/size threshold before doing
        // the full content comparison. This keeps metadata keystrokes cheap
        // while still preserving a snapshot for a substantial body change.
        recordAutomaticVersionIfNeeded(for: drafts[index])
      }
      drafts[index] = updated
    } else {
      drafts.insert(updated, at: 0)
      draftNavigationHistory.recordVisit(updated.id)
      selectedDraftID = updated.id
      store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    }
    if automaticallyRefreshPreflightOnEdit {
      store.schedulePreflightRefresh(
        for: updated.id,
        notifyingDraftList: isListMetadataChange
      )
    }
    if hasUnsavedDraftChange {
      store.scheduleAutosave()
      store.scheduleSiteDraftFileAutosave(for: updated)
    }
  }

  func updateDraftWordCount(
    _ count: Int,
    for draftID: UUID,
    matching bodyMarkdown: String,
    store: WorkbenchStore
  ) {
    guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
    var draft = drafts[index]
    guard draft.wordCountNeedsRefresh,
      draft.storeWordCount(count, for: bodyMarkdown)
    else { return }
    drafts[index] = draft
    store.scheduleAutosave()
  }

  public func deleteSelectedDraft(store: WorkbenchStore) {
    guard let selectedDraftID else { return }
    deleteDraft(id: selectedDraftID, store: store)
  }

  public func deleteDraft(id draftID: UUID, store: WorkbenchStore) {
    guard let draft = drafts.first(where: { $0.id == draftID }) else { return }
    let deletedSelectedDraft = selectedDraftID == draftID
    moveDraftToRecycleBin(draft, store: store)
    drafts.removeAll { $0.id == draftID }
    draftNavigationHistory.remove(draftID)
    if deletedSelectedDraft || !drafts.contains(where: { $0.id == selectedDraftID }) {
      selectedDraftID = store.writingDrafts.first?.id
      if let selectedDraftID {
        draftNavigationHistory.recordVisit(selectedDraftID)
      }
    }
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh()
    store.refreshPublishPreviewInBackground(for: store.selectedDraft)
    store.setPublishActionMessage(
      draft.repositoryPath?.trimmedForPublishing.nilIfEmpty == nil
        ? "已将文章移到回收站。"
        : "已将文章移到回收站，并加入仓库待清理队列。",
      status: .success
    )
    store.save()
  }

  @discardableResult
  public func focusDraft(_ id: UUID, section: WorkspaceSection? = nil, store: WorkbenchStore)
    -> Bool
  {
    guard let draft = drafts.first(where: { $0.id == id }) else { return false }
    draftNavigationHistory.recordVisit(id)
    if draft.isGeneralDraft {
      draftListContentScope = .general
    } else {
      activeProfileID = draft.siteProfileID
      draftListContentScope = .currentSite
    }
    selectedDraftID = id
    if let section { selectedSection = section }
    store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh(for: draft)
    store.refreshPublishPreviewInBackground(for: draft)
    return true
  }

  public var canNavigateBackwardInDraftHistory: Bool {
    draftNavigationHistory.canNavigateBackward(availableDraftIDs: Set(drafts.map(\.id)))
  }

  public var canNavigateForwardInDraftHistory: Bool {
    draftNavigationHistory.canNavigateForward(availableDraftIDs: Set(drafts.map(\.id)))
  }

  @discardableResult
  public func navigateBackwardInDraftHistory(store: WorkbenchStore) -> Bool {
    let availableDraftIDs = Set(drafts.map(\.id))
    guard
      let draftID = draftNavigationHistory.navigateBackward(
        availableDraftIDs: availableDraftIDs
      )
    else {
      return false
    }
    return activateDraftFromHistory(draftID, store: store)
  }

  @discardableResult
  public func navigateForwardInDraftHistory(store: WorkbenchStore) -> Bool {
    let availableDraftIDs = Set(drafts.map(\.id))
    guard
      let draftID = draftNavigationHistory.navigateForward(
        availableDraftIDs: availableDraftIDs
      )
    else {
      return false
    }
    return activateDraftFromHistory(draftID, store: store)
  }

  private func activateDraftFromHistory(_ draftID: UUID, store: WorkbenchStore) -> Bool {
    guard let draft = drafts.first(where: { $0.id == draftID }) else { return false }
    if draft.isGeneralDraft {
      draftListContentScope = .general
    } else {
      activeProfileID = draft.siteProfileID
      draftListContentScope = .currentSite
    }
    selectedDraftID = draftID
    selectedSection = .writing
    store.setAIPublishingAssistantPresented(false)
    store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh(for: draft)
    store.refreshPublishPreviewInBackground(for: draft)
    return true
  }

  public func updateActiveProfile(_ update: (inout SiteProfile) -> Void, store: WorkbenchStore) {
    var profile = store.activeProfile
    update(&profile)
    store.updateActiveProfile(profile)
    store.save()
    store.scheduleMissingSiteDraftFileWrites()
  }

  public func applySiteKindDefaults(_ siteKind: SiteKind, store: WorkbenchStore) {
    var profile = store.activeProfile
    profile.applyPublishingDefaults(for: siteKind)
    store.updateActiveProfile(profile)
    store.runPreflight()
    store.save()
  }

  @discardableResult
  public func createGitHubRepositoryForActiveProfile(
    privateRepository: Bool = true,
    store: WorkbenchStore
  ) async -> RemoteRepositoryCreationResult? {
    if store.activeProfile.repositoryProvider != .github {
      var profile = store.activeProfile
      profile.repositoryProvider = .github
      profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
      store.updateActiveProfile(profile)
    }
    return await store.createRemoteRepositoryForActiveProfile(privateRepository: privateRepository)
  }

  public func selectProfile(_ id: UUID, store: WorkbenchStore) {
    guard profiles.contains(where: { $0.id == id }) else { return }
    activeProfileID = id
    selectedDraftID = writingDrafts.first?.id
    if let selectedDraftID {
      draftNavigationHistory.recordVisit(selectedDraftID)
    }
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh()
    store.refreshPublishPreviewInBackground(for: store.selectedDraft)
  }

  public func selectSection(_ section: WorkspaceSection) {
    selectedSection = section
  }

  public func createProfile(named name: String? = nil, store: WorkbenchStore) -> SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.id = UUID()
    profile.name = name?.nilIfEmpty ?? "新站点"
    profiles.append(profile)
    activeProfileID = profile.id
    draftListContentScope = .currentSite
    selectedDraftID = nil
    store.runPreflight()
    store.refreshPublishPreviewInBackground(for: nil)
    store.save()
    return profile
  }

  public func duplicateActiveProfile(store: WorkbenchStore) -> SiteProfile {
    var profile = store.activeProfile
    let sourceProfileID = profile.id
    profile.id = UUID()
    profile.name += " 副本"
    profiles.append(profile)
    let duplicatedSnippets =
      customMarkdownSnippets
      .filter { $0.siteProfileID == sourceProfileID }
      .map { snippet in
        var duplicate = snippet
        duplicate.id = "custom-\(UUID().uuidString.lowercased())"
        duplicate.siteProfileID = profile.id
        return duplicate
      }
    customMarkdownSnippets.append(contentsOf: duplicatedSnippets)
    activeProfileID = profile.id
    draftListContentScope = .currentSite
    selectedDraftID = nil
    store.runPreflight()
    store.refreshPublishPreviewInBackground(for: nil)
    store.save()
    return profile
  }

  public func activeProfileDraftCount() -> Int {
    DraftListProjection.statistics(drafts, activeProfileID: activeProfileID).siteDraftCount
  }

  @discardableResult
  public func deleteActiveProfile(store: WorkbenchStore) -> RecentlyDeletedProfile? {
    guard profiles.count > 1 else {
      store.setPublishActionMessage(
        CoreL10n.text("至少需要保留一个站点 Profile。"),
        status: .warning
      )
      return nil
    }
    let removed = activeProfileID
    guard let profile = profiles.first(where: { $0.id == removed }) else { return nil }
    // Capture the editor's latest debounced body in the reversible deletion
    // payload instead of restoring the older baseline after an undo.
    store.flushDraftBodyEditorBuffers()
    let removedDrafts = drafts.filter { $0.belongs(toSiteProfileID: removed) }
    let removedSnippets = customMarkdownSnippets.filter { $0.siteProfileID == removed }
    let removedRecycledDrafts = recycledDrafts.filter {
      $0.draft.belongs(toSiteProfileID: removed)
    }
    let removedDraftIDs = Set(
      removedDrafts.map(\.id) + removedRecycledDrafts.map(\.id)
    )
    let survivingDraftsByID = Dictionary(
      (drafts + recycledDrafts.map(\.draft))
        .filter { !removedDraftIDs.contains($0.id) }
        .map { ($0.id, $0) },
      uniquingKeysWith: { active, _ in active }
    )
    let referencesRemovedProfile: (ArticleDraft) -> Bool = { draft in
      draft.siteProfileID == removed || draft.belongs(toSiteProfileID: removed)
    }
    let removedDraftVersions = draftVersions.filter { version in
      removedDraftIDs.contains(version.draftID)
        || (referencesRemovedProfile(version.draft)
          && survivingDraftsByID[version.draftID] == nil)
    }
    let removedDraftVersionIDs = Set(removedDraftVersions.map(\.id))
    let removedCleanupRequests = draftRepositoryCleanupRequests.filter {
      $0.siteProfileID == removed
    }
    let removedEditorSessionStates = markdownEditorSessionStates.filter {
      removedDraftIDs.contains($0.key)
    }
    recentlyDeletedProfile = RecentlyDeletedProfile(
      profile: profile,
      drafts: removedDrafts,
      customMarkdownSnippets: removedSnippets,
      draftVersions: removedDraftVersions,
      recycledDrafts: removedRecycledDrafts,
      draftRepositoryCleanupRequests: removedCleanupRequests,
      markdownEditorSessionStates: removedEditorSessionStates,
      deletedAt: Date()
    )
    profiles.removeAll { $0.id == removed }
    drafts.removeAll { $0.belongs(toSiteProfileID: removed) }
    customMarkdownSnippets.removeAll { $0.siteProfileID == removed }
    draftVersions.removeAll { removedDraftVersionIDs.contains($0.id) }
    recycledDrafts.removeAll { $0.draft.belongs(toSiteProfileID: removed) }
    draftRepositoryCleanupRequests.removeAll { $0.siteProfileID == removed }
    for draftID in removedDraftIDs {
      markdownEditorSessionStates.removeValue(forKey: draftID)
      draftNavigationHistory.remove(draftID)
      store.discardDraftBodyEditorBuffer(for: draftID)
    }
    if let activeEditorSelection,
      removedDraftIDs.contains(activeEditorSelection.draftID)
    {
      let clearedDraftID = activeEditorSelection.draftID
      self.activeEditorSelection = nil
      activeEditorSelectionDidChange.send(clearedDraftID)
    }
    activeProfileID = profiles[0].id
    for index in drafts.indices
    where drafts[index].isGeneralDraft && drafts[index].siteProfileID == removed {
      let previous = drafts[index]
      var rebound = previous
      rebound.assignToGeneralDraft(editingProfileID: activeProfileID)
      rebound.markUpdated(replacing: previous)
      drafts[index] = rebound
    }
    for index in recycledDrafts.indices
    where recycledDrafts[index].draft.isGeneralDraft
      && recycledDrafts[index].draft.siteProfileID == removed
    {
      recycledDrafts[index].draft.assignToGeneralDraft(editingProfileID: activeProfileID)
    }
    let reboundDraftsByID = Dictionary(
      (drafts + recycledDrafts.map(\.draft)).map { ($0.id, $0) },
      uniquingKeysWith: { active, _ in active }
    )
    for index in draftVersions.indices
    where referencesRemovedProfile(draftVersions[index].draft) {
      guard let currentDraft = reboundDraftsByID[draftVersions[index].draftID] else {
        continue
      }
      switch currentDraft.scope {
      case .general:
        draftVersions[index].draft.assignToGeneralDraft(
          editingProfileID: currentDraft.siteProfileID
        )
      case .site(let profileID):
        draftVersions[index].draft.assignToSite(profileID)
      }
    }
    selectedDraftID = writingDrafts.first?.id
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh()
    store.refreshPublishPreviewInBackground(for: store.selectedDraft)
    store.save()
    return recentlyDeletedProfile
  }

  @discardableResult
  public func restoreRecentlyDeletedProfile(store: WorkbenchStore) -> Bool {
    guard let recentlyDeletedProfile,
      !profiles.contains(where: { $0.id == recentlyDeletedProfile.profile.id })
    else {
      return false
    }
    profiles.append(recentlyDeletedProfile.profile)
    drafts.append(contentsOf: recentlyDeletedProfile.drafts)
    customMarkdownSnippets.append(contentsOf: recentlyDeletedProfile.customMarkdownSnippets)
    draftVersions.append(contentsOf: recentlyDeletedProfile.draftVersions)
    recycledDrafts.append(contentsOf: recentlyDeletedProfile.recycledDrafts)
    draftRepositoryCleanupRequests.append(
      contentsOf: recentlyDeletedProfile.draftRepositoryCleanupRequests
    )
    markdownEditorSessionStates.merge(
      recentlyDeletedProfile.markdownEditorSessionStates,
      uniquingKeysWith: { _, restored in restored }
    )
    activeProfileID = recentlyDeletedProfile.profile.id
    draftListContentScope = .currentSite
    selectedDraftID = recentlyDeletedProfile.drafts.first?.id
    self.recentlyDeletedProfile = nil
    store.save()
    return true
  }

}
