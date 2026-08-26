import Foundation

extension PublishingStore {
  typealias AsyncLocalPublishPreviewProvider = @Sendable (
    PublishPackage,
    SiteProfile
  ) async -> LocalPublishPreview

  /// Compatibility entry point. Work is keyed by the requested draft, so a
  /// non-selected draft can refresh without replacing the selected draft's
  /// five legacy projection fields.
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

  /// Compatibility entry point retained for deterministic tests and custom
  /// file-system providers.
  func schedulePublishPreviewRefresh(
    for draft: ArticleDraft? = nil,
    store: WorkbenchStore,
    previewProvider: @escaping AsyncLocalPublishPreviewProvider
  ) {
    let draftID = draft?.id ?? store.selectedDraftID
    guard let draftID else {
      cancelPublishPreviewRefresh()
      projectSelectedDraftPublishPreview()
      return
    }
    schedulePublishPreviewRefresh(
      for: draftID,
      store: store,
      previewProvider: previewProvider
    )
  }

  /// Draft-ID-scoped asynchronous refresh. The selected-draft projection is
  /// updated only when `draftID` is still selected when the complete result is
  /// installed; other drafts retain their own cache and can refresh in
  /// parallel.
  func schedulePublishPreviewRefresh(
    for draftID: UUID,
    store: WorkbenchStore,
    previewProvider: @escaping AsyncLocalPublishPreviewProvider
  ) {
    store.flushDraftBodyEditorBuffer(for: draftID)
    guard let draft = store.draft(for: draftID) else {
      cancelPublishPreviewRefresh(for: draftID)
      removeDraftPublishPreviewSnapshot(for: draftID)
      forgetDraftPublishPreviewInputBaseline(for: draftID)
      return
    }

    cancelPublishPreviewRefresh(for: draftID)

    guard !draft.isGeneralDraft else {
      removeDraftPublishPreviewSnapshot(for: draftID)
      forgetDraftPublishPreviewInputBaseline(for: draftID)
      projectSelectedDraftPublishPreview()
      return
    }

    let profile = store.profile(for: draft)
    let bodyRevision = store.draftBodyEditorBuffer(for: draftID).revision
    let baseline = makeDraftPublishPreviewInputBaseline(
      for: draft,
      store: store,
      bodyRevision: bodyRevision
    )
    let package = publishPackageBuilder.build(
      draft: baseline.draft,
      profile: baseline.profile
    )
    let allDrafts = store.drafts
      .filter { $0.belongs(toSiteProfileID: profile.id) }
      .sorted { $0.id.uuidString < $1.id.uuidString }
    let duplicateIndex = PreflightDuplicateIndex(
      drafts: allDrafts,
      profile: profile
    )
    let preflightService = self.preflightService
    let generalDraftPublishingIssue = self.generalDraftPublishingIssue
    let preflightTask: Task<([PreflightIssue]?, [PreflightIssue]?), Never> =
      Task.detached(priority: .userInitiated) {
      guard !Task.isCancelled else { return (nil, nil) }
      let withoutRepository = preflightService.run(
        draft: baseline.draft,
        allDrafts: allDrafts,
        profile: baseline.profile,
        repositoryReport: baseline.repositoryReport,
        includeRepositoryReadiness: false,
        duplicateIndex: duplicateIndex
      )
      let withRepository = preflightService.run(
        draft: baseline.draft,
        allDrafts: allDrafts,
        profile: baseline.profile,
        repositoryReport: baseline.repositoryReport,
        includeRepositoryReadiness: true,
        duplicateIndex: duplicateIndex
      )
      if baseline.draft.isGeneralDraft {
        return ([generalDraftPublishingIssue], [generalDraftPublishingIssue])
      }
      return (withoutRepository, withRepository)
    }

    let generation = advanceDraftPublishPreviewRefreshGeneration(for: draftID)
    if store.selectedDraftID == draftID && store.activeProfileID == profile.id {
      refreshLocalSitePreviewPlan(for: profile)
    }

    let task = Task { [weak self, weak store] in
      let preview = await previewProvider(package, profile)
      let (draftIssuesWithoutRepository, draftIssuesWithRepository) =
        await preflightTask.value
      guard let self, let store,
            !Task.isCancelled,
            generation == self.draftPublishPreviewRefreshGenerations[draftID]
      else {
        return
      }

      defer {
        if generation == self.draftPublishPreviewRefreshGenerations[draftID] {
          self.setDraftPublishPreviewRefreshTask(nil, for: draftID)
        }
      }

      guard let draftIssuesWithoutRepository,
            let draftIssuesWithRepository,
            self.isCurrentDraftPublishPreviewInput(
              baseline,
              for: draftID,
              store: store
            )
      else {
        return
      }

      let readiness = self.makeLocalPublishReadiness(
        package: package,
        profile: profile,
        preview: preview,
        draftIssuesWithoutRepository: draftIssuesWithoutRepository,
        draftIssuesWithRepository: draftIssuesWithRepository,
        store: store
      )
      let remotePreview = self.remoteRepositoryPublishPreview(
        package: package,
        profile: profile,
        mode: self.preferredRemoteRepositoryPublishMode(for: profile),
        localPreview: preview,
        draftIssuesWithRepository: draftIssuesWithRepository,
        repositoryReport: baseline.repositoryReport,
        tokenAvailability: baseline.tokenAvailability,
        accessCheck: baseline.remoteRepositoryAccessCheck,
        store: store
      )
      let snapshot = DraftPublishPreviewSnapshot(
        context: baseline.context,
        publishPackage: package,
        localPublishPreview: preview,
        localPublishReadiness: readiness,
        remotePublishPreview: remotePreview,
        remoteReviewDraft: self.remoteReviewDraftBuilder.build(
          package: package,
          profile: profile
        )
      )

      guard self.isCurrentDraftPublishPreviewInput(
        baseline,
        for: draftID,
        store: store
      ) else {
        return
      }
      self.rememberDraftPublishPreviewInputBaseline(baseline, for: draftID)
      _ = self.installDraftPublishPreviewSnapshot(snapshot, for: draftID)
    }
    setDraftPublishPreviewRefreshTask(task, for: draftID)
  }

  /// Explicit spelling for call sites that already have a draft ID and want
  /// to make the scoping visible at the call site.
  func schedulePublishPreviewRefresh(
    forDraftID draftID: UUID,
    store: WorkbenchStore,
    previewProvider: @escaping AsyncLocalPublishPreviewProvider
  ) {
    schedulePublishPreviewRefresh(
      for: draftID,
      store: store,
      previewProvider: previewProvider
    )
  }

  func schedulePublishPreviewRefresh(for draftID: UUID, store: WorkbenchStore) {
    let service = localPublishPreviewService
    schedulePublishPreviewRefresh(
      for: draftID,
      store: store,
      previewProvider: { package, profile in
        await service.previewAsync(package: package, profile: profile)
      }
    )
  }

  func schedulePublishPreviewRefresh(forDraftID draftID: UUID, store: WorkbenchStore) {
    schedulePublishPreviewRefresh(for: draftID, store: store)
  }

  /// Cancels only one draft's work. A cached complete result remains valid
  /// until a replacement is installed or the caller explicitly removes it.
  func cancelPublishPreviewRefresh(for draftID: UUID) {
    _ = advanceDraftPublishPreviewRefreshGeneration(for: draftID)
    draftPublishPreviewRefreshTasks[draftID]?.cancel()
    setDraftPublishPreviewRefreshTask(nil, for: draftID)
  }

  /// Legacy no-argument cancellation is scoped to the selected draft. This
  /// prevents a background refresh for another draft from being interrupted
  /// by a toolbar action in the selected window.
  func cancelPublishPreviewRefresh() {
    guard let selectedDraftID else {
      publishPreviewRefreshGeneration &+= 1
      publishPreviewRefreshTask?.cancel()
      publishPreviewRefreshTask = nil
      isPublishPreviewRefreshing = false
      return
    }
    cancelPublishPreviewRefresh(for: selectedDraftID)
  }

  func waitForPublishPreviewRefresh(for draftID: UUID) async {
    let task = draftPublishPreviewRefreshTasks[draftID]
    await task?.value
  }

  func waitForPublishPreviewRefresh() async {
    if let selectedDraftID {
      await waitForPublishPreviewRefresh(for: selectedDraftID)
    } else {
      let task = publishPreviewRefreshTask
      await task?.value
    }
  }

  func isPublishPreviewRefreshing(forDraftID draftID: UUID) -> Bool {
    isPublishPreviewRefreshing(for: draftID)
  }
}
