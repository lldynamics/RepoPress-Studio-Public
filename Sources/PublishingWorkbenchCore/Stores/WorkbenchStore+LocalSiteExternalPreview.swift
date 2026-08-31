import Foundation

extension WorkbenchStore {
  private struct LocalSiteExternalPreviewValidationSnapshot: Equatable, Sendable {
    let previewGeneration: UInt64
    let processIdentifier: Int32
    let processStartedAt: Date
    let rootURL: URL
    let repositoryPath: String
    let expectedContentDigest: String
  }

  /// A monotonically increasing token shared by every local-preview entry
  /// point. Starting, stopping, or replacing a plan invalidates older opens.
  public var localSitePreviewValidationGeneration: UInt64 {
    publishingStore.localSitePreviewGeneration
  }

  /// Flushes one editor buffer and waits for only that draft's project write.
  /// Other windows may continue autosaving without delaying this preview.
  public func prepareLocalSiteExternalPreview(
    for draftID: UUID
  ) async throws -> LocalSiteExternalPreviewPreparation {
    guard let initialDraft = drafts.first(where: { $0.id == draftID }) else {
      throw LocalSiteExternalPreviewPreparationError.draftNotFound
    }
    guard !initialDraft.isGeneralDraft else {
      throw LocalSiteExternalPreviewPreparationError.generalDraftRequiresProject
    }
    guard initialDraft.belongs(toSiteProfileID: activeProfileID) else {
      throw LocalSiteExternalPreviewPreparationError.inactiveSite
    }
    guard initialDraft.repositoryPath?.normalizedRelativePath().nilIfEmpty != nil else {
      throw LocalSiteExternalPreviewPreparationError.draftNotAddedToProject
    }

    var stableWrite: (draft: ArticleDraft, bodyRevision: UInt64)?
    for _ in 0..<3 {
      flushDraftBodyEditorBuffer(for: draftID)
      try Task.checkCancellation()

      guard let flushedDraft = drafts.first(where: { $0.id == draftID }) else {
        throw LocalSiteExternalPreviewPreparationError.draftNotFound
      }
      guard !flushedDraft.isGeneralDraft else {
        throw LocalSiteExternalPreviewPreparationError.generalDraftRequiresProject
      }
      guard flushedDraft.belongs(toSiteProfileID: activeProfileID) else {
        throw LocalSiteExternalPreviewPreparationError.inactiveSite
      }
      guard flushedDraft.repositoryPath?.normalizedRelativePath().nilIfEmpty != nil else {
        throw LocalSiteExternalPreviewPreparationError.draftNotAddedToProject
      }

      let bodyRevision = draftBodyEditorBuffer(for: draftID).revision
      scheduleSiteDraftFileAutosave(for: flushedDraft, immediate: true)
      try await waitForPendingSiteDraftFileWrite(for: draftID)

      guard let writtenDraft = drafts.first(where: { $0.id == draftID }) else {
        throw LocalSiteExternalPreviewPreparationError.draftNotFound
      }
      switch siteDraftFileSaveStates[draftID] {
      case .failed(_, let message):
        throw LocalSiteExternalPreviewPreparationError.projectSaveFailed(message)
      case .saved:
        break
      case .pending, nil:
        throw LocalSiteExternalPreviewPreparationError.projectSaveFailed(
          CoreL10n.text("未能确认项目文件已写入。")
        )
      }

      let currentBuffer = draftBodyEditorBuffer(for: draftID)
      guard !currentBuffer.isDirty, currentBuffer.revision == bodyRevision else {
        continue
      }
      stableWrite = (writtenDraft, bodyRevision)
      break
    }

    guard let stableWrite else {
      throw LocalSiteExternalPreviewPreparationError.projectSaveFailed(
        CoreL10n.text("正文仍在变化，请停止输入后重试。")
      )
    }
    let writtenDraft = stableWrite.draft
    let bodyRevision = stableWrite.bodyRevision

    let profile = profile(for: writtenDraft)
    guard profile.id == activeProfileID,
      writtenDraft.belongs(toSiteProfileID: activeProfileID)
    else {
      throw LocalSiteExternalPreviewPreparationError.inactiveSite
    }
    let renderedDigest = writtenDraft.renderedRepositoryContentDigest(profile: profile)
    guard writtenDraft.repositoryBinding?.projectFileContentDigest == renderedDigest else {
      throw LocalSiteExternalPreviewPreparationError.projectSaveFailed(
        CoreL10n.text("项目文件与当前正文不一致。")
      )
    }

    publishingStore.refreshLocalSitePreviewPlan(
      for: profile,
      repositoryReport: repositoryReport(for: profile)
    )
    guard let plan = publishingStore.localSitePreviewPlan(for: writtenDraft, store: self),
      plan.executionIdentity?.profileID == activeProfileID,
      let articleURL = publishingStore.localSitePreviewURL(for: writtenDraft, store: self)
    else {
      throw LocalSiteExternalPreviewPreparationError.previewUnavailable
    }

    return LocalSiteExternalPreviewPreparation(
      draftID: draftID,
      profileID: profile.id,
      bodyRevision: bodyRevision,
      siteURL: plan.previewURL,
      articleURL: articleURL
    )
  }

  /// Revalidates the complete prepared-preview invariant immediately before
  /// handing a URL to the system browser.
  ///
  /// The project file is read off the main actor through the bounded safe-file
  /// reader. State and process identity are checked both before and after that
  /// read so stop/restart, profile, editor, plan, and manifest changes fail
  /// closed.
  public func isLocalSiteExternalPreviewCurrent(
    _ preparation: LocalSiteExternalPreviewPreparation,
    targetURL: URL,
    executionFingerprint: String,
    previewGeneration: UInt64
  ) async -> Bool {
    guard
      let initialSnapshot = localSiteExternalPreviewValidationSnapshot(
        preparation,
        targetURL: targetURL,
        executionFingerprint: executionFingerprint,
        previewGeneration: previewGeneration
      )
    else {
      return false
    }

    let diskContentMatches = await Task.detached(priority: .userInitiated) {
      guard
        let contents = try? BoundedFileReader.utf8String(
          relativePath: initialSnapshot.repositoryPath,
          under: initialSnapshot.rootURL,
          maximumByteCount: WorkbenchContentFileReadLimits.textDocumentByteCount
        )
      else {
        return false
      }
      return ArticleDraft.repositoryDocumentDigest(contents)
        == initialSnapshot.expectedContentDigest
    }.value
    guard diskContentMatches else { return false }

    return localSiteExternalPreviewValidationSnapshot(
      preparation,
      targetURL: targetURL,
      executionFingerprint: executionFingerprint,
      previewGeneration: previewGeneration
    ) == initialSnapshot
  }

  private func localSiteExternalPreviewValidationSnapshot(
    _ preparation: LocalSiteExternalPreviewPreparation,
    targetURL: URL,
    executionFingerprint: String,
    previewGeneration: UInt64
  ) -> LocalSiteExternalPreviewValidationSnapshot? {
    guard publishingStore.localSitePreviewGeneration == previewGeneration,
      activeProfileID == preparation.profileID,
      let plan = localSitePreviewPlan,
      plan.executionIdentity?.profileID == preparation.profileID,
      plan.executionIdentity?.fingerprint == executionFingerprint,
      plan.previewURL == preparation.siteURL,
      publishingStore.localSitePreviewProcessService.isExecutionCurrent(for: plan)
    else {
      return nil
    }

    let publishedRuntime = localSitePreviewRuntimeStatus
    let processRuntime = publishingStore.localSitePreviewProcessService.status
    guard publishedRuntime.isRunning,
      processRuntime.isRunning,
      let publishedProcessIdentifier = publishedRuntime.processIdentifier,
      publishedProcessIdentifier == processRuntime.processIdentifier,
      let publishedStartedAt = publishedRuntime.startedAt,
      publishedStartedAt == processRuntime.startedAt,
      publishedRuntime.previewURL == plan.previewURL,
      processRuntime.previewURL == plan.previewURL
    else {
      return nil
    }

    guard let draft = draft(for: preparation.draftID),
      draft.belongs(toSiteProfileID: preparation.profileID)
    else {
      return nil
    }
    let editorBuffer = draftBodyEditorBuffer(for: preparation.draftID)
    guard !editorBuffer.isDirty, editorBuffer.revision == preparation.bodyRevision else {
      return nil
    }

    let profile = profile(for: draft)
    let expectedContentDigest = draft.renderedRepositoryContentDigest(profile: profile)
    guard profile.id == preparation.profileID,
      draft.repositoryBinding?.projectFileContentDigest == expectedContentDigest,
      let rootURL = profile.localRepositoryRootURL,
      let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty,
      publishingStore.localSitePreviewURL(for: draft, store: self)
        == preparation.articleURL,
      targetURL == preparation.siteURL || targetURL == preparation.articleURL
    else {
      return nil
    }

    return LocalSiteExternalPreviewValidationSnapshot(
      previewGeneration: previewGeneration,
      processIdentifier: publishedProcessIdentifier,
      processStartedAt: publishedStartedAt,
      rootURL: rootURL,
      repositoryPath: repositoryPath,
      expectedContentDigest: expectedContentDigest
    )
  }

  private func waitForPendingSiteDraftFileWrite(for draftID: UUID) async throws {
    while true {
      try Task.checkCancellation()
      if let task = siteDraftFileAutosaveTasks[draftID] {
        await task.value
        continue
      }
      guard siteDraftFileWritesInProgress.contains(draftID) else { return }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}
