import Foundation

extension PublishingStore {
  public func selectDraft(_ id: UUID?, store: WorkbenchStore) {
    selectedDraftID = id
    store.setAIPublishingAssistantPresented(false)
    if selectedSection == .writing {
      editorDisplayMode = .edit
    }
    store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh()
  }

  @discardableResult
  public func ensureEditableDraftSelected(store: WorkbenchStore) -> ArticleDraft? {
    if let selectedDraftID,
       let draft = drafts.first(where: { $0.id == selectedDraftID && $0.siteProfileID == activeProfileID }) {
      return draft
    }

    if let draft = store.visibleDrafts.first {
      selectedDraftID = draft.id
      store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
      store.runPreflight()
      store.scheduleImageWorkbenchReportRefresh(for: draft)
      return draft
    }

    let previousSection = selectedSection
    let draft = ArticleDraft.empty(profile: store.activeProfile)
    drafts.insert(draft, at: 0)
    selectedDraftID = draft.id
    selectedSection = previousSection
    store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh(for: draft)
    store.save()
    return draft
  }

  public func requestEditorFocus(
    draftID: UUID,
    field: String?,
    query: String? = nil,
    store: WorkbenchStore
  ) {
    selectedDraftID = draftID
    store.setAIPublishingAssistantPresented(false)
    store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    editorFocusRequest = EditorFocusRequest(draftID: draftID, field: field, query: query)
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
      activeEditorSelection = selection
    }
  }

  public func clearActiveEditorSelection(for draftID: UUID? = nil) {
    guard let activeEditorSelection else {
      return
    }
    guard draftID == nil || activeEditorSelection.draftID == draftID else {
      return
    }
    self.activeEditorSelection = nil
  }

  public func activeEditorSelectionRange(for draft: ArticleDraft) -> NSRange? {
    activeEditorSelection?.validatedRange(in: draft)
  }

  public func createDraft(store: WorkbenchStore) {
    let draft = ArticleDraft.empty(profile: store.activeProfile)
    drafts.insert(draft, at: 0)
    selectedDraftID = draft.id
    selectedSection = .writing
    store.setAIPublishingAssistantPresented(false)
    store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh(for: draft)
    store.save()
  }

  public func updateDraft(_ draft: ArticleDraft, store: WorkbenchStore) {
    let existingIndex = drafts.firstIndex { $0.id == draft.id }
    let hasUnsavedDraftChange = existingIndex.map { drafts[$0] != draft } ?? true
    var updated = draft
    updated.touch()
    if let index = existingIndex {
      if hasUnsavedDraftChange {
        recordAutomaticVersionIfNeeded(for: drafts[index])
      }
      drafts[index] = updated
    } else {
      drafts.insert(updated, at: 0)
      selectedDraftID = updated.id
      store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    }
    if automaticallyRefreshPreflightOnEdit {
      store.schedulePreflightRefresh()
    }
    if hasUnsavedDraftChange {
      store.scheduleAutosave()
    }
  }

  public func deleteSelectedDraft(store: WorkbenchStore) {
    guard let selectedDraftID else { return }
    deleteDraft(id: selectedDraftID, store: store)
  }

  public func deleteDraft(id draftID: UUID, store: WorkbenchStore) {
    guard let draft = drafts.first(where: { $0.id == draftID }) else { return }
    let deletedSelectedDraft = selectedDraftID == draftID
    moveDraftToRecycleBin(draft)
    drafts.removeAll { $0.id == draftID }
    if deletedSelectedDraft || !drafts.contains(where: { $0.id == selectedDraftID }) {
      selectedDraftID = store.visibleDrafts.first?.id
    }
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh()
    store.refreshPublishPreviewInBackground(for: store.selectedDraft)
    store.setPublishActionMessage(
      draft.repositoryPath?.trimmedForPublishing.nilIfEmpty == nil
        ? "已将文章移到回收站。"
        : "已将文章移到回收站，并加入仓库待清理队列。"
    )
    store.save()
  }

  @discardableResult
  public func focusDraft(_ id: UUID, section: WorkspaceSection? = nil, store: WorkbenchStore) -> Bool {
    guard let draft = drafts.first(where: { $0.id == id }) else { return false }
    activeProfileID = draft.siteProfileID
    selectedDraftID = id
    if let section { selectedSection = section }
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
    privateRepository: Bool = false,
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
    selectedDraftID = store.visibleDrafts.first?.id
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
    selectedDraftID = nil
    store.runPreflight()
    store.refreshPublishPreviewInBackground(for: nil)
    store.save()
    return profile
  }

  public func duplicateActiveProfile(store: WorkbenchStore) -> SiteProfile {
    var profile = store.activeProfile
    profile.id = UUID()
    profile.name += " 副本"
    profiles.append(profile)
    activeProfileID = profile.id
    selectedDraftID = nil
    store.runPreflight()
    store.refreshPublishPreviewInBackground(for: nil)
    store.save()
    return profile
  }

  public func activeProfileDraftCount() -> Int {
    drafts.filter { $0.siteProfileID == activeProfileID }.count
  }

  @discardableResult
  public func deleteActiveProfile(store: WorkbenchStore) -> RecentlyDeletedProfile? {
    guard profiles.count > 1 else {
      store.setPublishActionMessage("至少需要保留一个站点 Profile。")
      return nil
    }
    let removed = activeProfileID
    guard let profile = profiles.first(where: { $0.id == removed }) else { return nil }
    let removedDrafts = drafts.filter { $0.siteProfileID == removed }
    recentlyDeletedProfile = RecentlyDeletedProfile(
      profile: profile,
      drafts: removedDrafts,
      deletedAt: Date()
    )
    profiles.removeAll { $0.id == removed }
    drafts.removeAll { $0.siteProfileID == removed }
    activeProfileID = profiles[0].id
    selectedDraftID = store.visibleDrafts.first?.id
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh()
    store.refreshPublishPreviewInBackground(for: store.selectedDraft)
    store.save()
    return recentlyDeletedProfile
  }

  @discardableResult
  public func restoreRecentlyDeletedProfile(store: WorkbenchStore) -> Bool {
    guard let recentlyDeletedProfile,
          !profiles.contains(where: { $0.id == recentlyDeletedProfile.profile.id }) else {
      return false
    }
    profiles.append(recentlyDeletedProfile.profile)
    drafts.append(contentsOf: recentlyDeletedProfile.drafts)
    activeProfileID = recentlyDeletedProfile.profile.id
    selectedDraftID = recentlyDeletedProfile.drafts.first?.id
    self.recentlyDeletedProfile = nil
    store.save()
    return true
  }

}
