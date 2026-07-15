import Foundation

extension PublishingStore {
  typealias AsyncLocalPublishPreviewProvider = @Sendable (
    PublishPackage,
    SiteProfile
  ) async -> LocalPublishPreview

  /// Refreshes the file-system-backed publish diff away from the main actor.
  /// A generation and value baseline prevent an older scan from replacing a
  /// preview for a newer draft or profile.
  func schedulePublishPreviewRefresh(
    for draft: ArticleDraft? = nil,
    store: WorkbenchStore
  ) {
    let service = localPublishPreviewService
    schedulePublishPreviewRefresh(
      for: draft,
      store: store,
      previewProvider: { package, profile in
        await service.previewAsync(package: package, profile: profile)
      }
    )
  }

  func schedulePublishPreviewRefresh(
    for draft: ArticleDraft? = nil,
    store: WorkbenchStore,
    previewProvider: @escaping AsyncLocalPublishPreviewProvider
  ) {
    if let draft {
      let requestedProfile = store.profile(for: draft)
      guard store.selectedDraftID == draft.id,
            store.activeProfileID == requestedProfile.id else {
        return
      }
    }

    publishPreviewRefreshTask?.cancel()
    publishPreviewRefreshGeneration &+= 1
    let generation = publishPreviewRefreshGeneration

    let selectedDraft = draft ?? store.selectedDraft
    let profile = selectedDraft.map { store.profile(for: $0) } ?? store.activeProfile
    refreshLocalSitePreviewPlan(for: profile)

    guard let selectedDraft else {
      publishPreviewRefreshTask = nil
      isPublishPreviewRefreshing = false
      publishPackage = nil
      localPublishPreview = nil
      localPublishReadiness = nil
      remotePublishPreviewSnapshot = nil
      remoteReviewDraft = nil
      return
    }

    let package = publishingPackage(for: selectedDraft, store: store)
    let activeProfileID = store.activeProfileID
    let selectedDraftID = store.selectedDraftID
    guard selectedDraft.id == selectedDraftID,
          profile.id == activeProfileID else {
      publishPreviewRefreshTask = nil
      isPublishPreviewRefreshing = false
      return
    }
    let repositoryReport = store.repositoryReport(for: profile)
    let profileDrafts = store.drafts.filter { $0.siteProfileID == selectedDraft.siteProfileID }
    let duplicateIndex = PreflightDuplicateIndex(drafts: profileDrafts, profile: profile)
    let draftIssuesWithoutRepository = preflightIssues(
      for: selectedDraft,
      includeRepositoryReadiness: false,
      allDrafts: profileDrafts,
      duplicateIndex: duplicateIndex,
      store: store
    )
    let draftIssuesWithRepository = preflightIssues(
      for: selectedDraft,
      includeRepositoryReadiness: true,
      allDrafts: profileDrafts,
      duplicateIndex: duplicateIndex,
      store: store
    )
    isPublishPreviewRefreshing = true

    publishPreviewRefreshTask = Task { [weak self, weak store] in
      let preview = await previewProvider(package, profile)
      guard let self, let store,
            generation == self.publishPreviewRefreshGeneration else {
        return
      }

      defer {
        if generation == self.publishPreviewRefreshGeneration {
          self.publishPreviewRefreshTask = nil
          self.isPublishPreviewRefreshing = false
        }
      }

      guard !Task.isCancelled,
            store.activeProfileID == activeProfileID,
            store.selectedDraftID == selectedDraftID,
            store.drafts.first(where: { $0.id == selectedDraft.id }) == selectedDraft,
            store.profiles.first(where: { $0.id == profile.id }) == profile,
            store.repositoryReport(for: profile) == repositoryReport else {
        return
      }

      self.publishPackage = package
      self.localPublishPreview = preview
      self.localPublishReadiness = self.makeLocalPublishReadiness(
        package: package,
        profile: profile,
        preview: preview,
        draftIssuesWithoutRepository: draftIssuesWithoutRepository,
        draftIssuesWithRepository: draftIssuesWithRepository,
        store: store
      )
      self.remotePublishPreviewSnapshot = self.remoteRepositoryPublishPreview(
        package: package,
        profile: profile,
        mode: self.preferredRemoteRepositoryPublishMode(for: profile),
        localPreview: preview,
        draftIssuesWithRepository: draftIssuesWithRepository,
        store: store
      )
      self.remoteReviewDraft = self.remoteReviewDraftBuilder.build(
        package: package,
        profile: profile
      )
    }
  }

  func cancelPublishPreviewRefresh() {
    publishPreviewRefreshGeneration &+= 1
    publishPreviewRefreshTask?.cancel()
    publishPreviewRefreshTask = nil
    isPublishPreviewRefreshing = false
  }

  func waitForPublishPreviewRefresh() async {
    let task = publishPreviewRefreshTask
    await task?.value
  }
}
