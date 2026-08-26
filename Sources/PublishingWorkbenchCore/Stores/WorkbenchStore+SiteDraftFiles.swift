import Foundation

public enum SiteDraftFileSaveState: Equatable, Sendable {
  case pending(repositoryPath: String)
  case saved(repositoryPath: String, savedAt: Date)
  case failed(repositoryPath: String, message: String)

  public var repositoryPath: String {
    switch self {
    case .pending(let repositoryPath),
      .saved(let repositoryPath, _),
      .failed(let repositoryPath, _):
      return repositoryPath
    }
  }
}

private struct SiteDraftFileReconciliationCandidate: Sendable {
  let draft: ArticleDraft
  let profile: SiteProfile
  let repositoryPath: String
  let storedProjectFileContentDigest: String?
}

extension WorkbenchStore {
  func scheduleSiteDraftFileAutosave(
    for draft: ArticleDraft,
    immediate: Bool = false
  ) {
    guard !draft.isGeneralDraft else {
      cancelSiteDraftFileAutosave(for: draft.id)
      return
    }
    // New site drafts are local-first.  A missing repository path means the
    // user has not explicitly added this draft to a project yet.
    guard draft.repositoryPath?.nilIfEmpty != nil else {
      cancelSiteDraftFileAutosave(for: draft.id)
      return
    }

    let profile = profile(for: draft)
    let repositoryPath = draft.repositoryPath?.normalizedRelativePath()
      ?? profile.markdownPath(for: draft)
    let generation = (siteDraftFileSaveGenerations[draft.id] ?? 0) &+ 1
    siteDraftFileSaveGenerations[draft.id] = generation
    siteDraftFileSaveStates[draft.id] = .pending(repositoryPath: repositoryPath)

    if siteDraftFileWritesInProgress.contains(draft.id) {
      return
    }

    siteDraftFileAutosaveTasks[draft.id]?.cancel()
    siteDraftFileAutosaveTasks[draft.id] = Task { [weak self] in
      guard let self else { return }
      if !immediate {
        do {
          try await Task.sleep(nanoseconds: 350_000_000)
        } catch {
          return
        }
      }
      guard !Task.isCancelled,
        self.siteDraftFileSaveGenerations[draft.id] == generation,
        let currentDraft = self.drafts.first(where: { $0.id == draft.id }),
        !currentDraft.isGeneralDraft,
        currentDraft.repositoryPath?.nilIfEmpty != nil
      else {
        return
      }

      let currentProfile = self.profile(for: currentDraft)
      self.siteDraftFileWritesInProgress.insert(draft.id)
      do {
        let result = try await self.siteDraftFileStore.writeAsync(
          draft: currentDraft,
          profile: currentProfile
        )
        self.finishSiteDraftFileWrite(
          draftID: draft.id,
          writtenDraft: currentDraft,
          profile: currentProfile,
          writtenDraftUpdatedAt: currentDraft.updatedAt,
          generation: generation,
          result: result
        )
      } catch {
        self.failSiteDraftFileWrite(
          draftID: draft.id,
          generation: generation,
          repositoryPath: currentDraft.repositoryPath?.normalizedRelativePath()
            ?? currentProfile.markdownPath(for: currentDraft),
          error: error
        )
      }
    }
  }

  func scheduleMissingSiteDraftFileWrites() {
    cancelSiteDraftFileReconciliation()

    var candidates: [SiteDraftFileReconciliationCandidate] = []
    for draft in drafts where !draft.isGeneralDraft {
      guard let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty else {
        cancelSiteDraftFileAutosaveIfNeeded(for: draft.id)
        continue
      }
      let profile = profile(for: draft)
      guard profile.localRepositoryRootURL != nil else {
        cancelSiteDraftFileAutosaveIfNeeded(for: draft.id)
        continue
      }
      candidates.append(
        SiteDraftFileReconciliationCandidate(
          draft: draft,
          profile: profile,
          repositoryPath: repositoryPath,
          storedProjectFileContentDigest: draft.repositoryBinding?.projectFileContentDigest
        )
      )
    }

    guard !candidates.isEmpty else { return }

    let generation = siteDraftFileReconciliationGeneration
    siteDraftFileReconciliationTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.finishSiteDraftFileReconciliation(generation: generation)
      }
      await self.waitForPendingDraftWordCountRefreshes()
      guard !Task.isCancelled,
        self.siteDraftFileReconciliationGeneration == generation
      else {
        return
      }
      let digestTask = Self.siteDraftFileReconciliationDigestTask(candidates: candidates)
      let staleCandidates = await withTaskCancellationHandler(operation: {
        await digestTask.value
      }, onCancel: {
        digestTask.cancel()
      })

      guard !Task.isCancelled,
        self.siteDraftFileReconciliationGeneration == generation
      else {
        return
      }

      for staleCandidate in staleCandidates {
        guard !Task.isCancelled,
          let currentDraft = self.drafts.first(where: {
            $0.id == staleCandidate.draft.id
          }),
          currentDraft == staleCandidate.draft,
          currentDraft.repositoryPath?.normalizedRelativePath().nilIfEmpty
            == staleCandidate.repositoryPath
        else {
          continue
        }
        self.scheduleSiteDraftFileAutosave(for: currentDraft, immediate: true)
      }
    }
  }

  private nonisolated static func siteDraftFileReconciliationDigestTask(
    candidates: [SiteDraftFileReconciliationCandidate]
  ) -> Task<[SiteDraftFileReconciliationCandidate], Never> {
    Task.detached(priority: .utility) {
      candidates.compactMap { candidate -> SiteDraftFileReconciliationCandidate? in
        guard !Task.isCancelled else { return nil }
        let renderedContentDigest = candidate.draft.renderedRepositoryContentDigest(
          profile: candidate.profile
        )
        guard candidate.storedProjectFileContentDigest != renderedContentDigest else {
          return nil
        }
        return candidate
      }
    }
  }

  private func cancelSiteDraftFileAutosaveIfNeeded(for draftID: UUID) {
    guard siteDraftFileAutosaveTasks[draftID] != nil
      || siteDraftFileWritesInProgress.contains(draftID)
      || siteDraftFileSaveStates[draftID] != nil
    else {
      return
    }
    cancelSiteDraftFileAutosave(for: draftID)
  }

  private func cancelSiteDraftFileReconciliation() {
    siteDraftFileReconciliationGeneration &+= 1
    siteDraftFileReconciliationTask?.cancel()
    siteDraftFileReconciliationTask = nil
  }

  private func finishSiteDraftFileReconciliation(generation: UInt64) {
    guard siteDraftFileReconciliationGeneration == generation else { return }
    siteDraftFileReconciliationTask = nil
  }

  func refreshSiteDraftFileAutosave(for draftIDs: [UUID]) {
    for draftID in draftIDs {
      guard let draft = drafts.first(where: { $0.id == draftID }) else {
        cancelSiteDraftFileAutosave(for: draftID)
        continue
      }
      if draft.isGeneralDraft {
        cancelSiteDraftFileAutosave(for: draftID)
      } else {
        scheduleSiteDraftFileAutosave(for: draft, immediate: true)
      }
    }
  }

  func cancelSiteDraftFileAutosave(for draftID: UUID) {
    siteDraftFileSaveGenerations[draftID] = (siteDraftFileSaveGenerations[draftID] ?? 0) &+ 1
    siteDraftFileAutosaveTasks[draftID]?.cancel()
    siteDraftFileAutosaveTasks[draftID] = nil
    siteDraftFileWritesInProgress.remove(draftID)
    siteDraftFileSaveStates[draftID] = nil
  }

  /// Forces the latest site-draft Markdown to disk before termination or a
  /// publish operation. General drafts are deliberately excluded.
  @discardableResult
  func flushPendingSiteDraftFileWrites() -> Bool {
    cancelSiteDraftFileReconciliation()
    let pendingIDs = Set(siteDraftFileAutosaveTasks.keys)
      .union(siteDraftFileWritesInProgress)
      .union(
        siteDraftFileSaveStates.compactMap { id, state in
          switch state {
          case .pending, .failed:
            return id
          case .saved:
            return nil
          }
        }
      )

    for draftID in pendingIDs {
      siteDraftFileSaveGenerations[draftID] = (siteDraftFileSaveGenerations[draftID] ?? 0) &+ 1
      siteDraftFileAutosaveTasks[draftID]?.cancel()
    }
    siteDraftFileAutosaveTasks.removeAll()
    siteDraftFileWritesInProgress.removeAll()

    var succeeded = true
    for draftID in pendingIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let draft = drafts.first(where: { $0.id == draftID }),
        !draft.isGeneralDraft,
        draft.repositoryPath?.nilIfEmpty != nil
      else {
        siteDraftFileSaveStates[draftID] = nil
        continue
      }
      let profile = profile(for: draft)
      let repositoryPath = draft.repositoryPath?.normalizedRelativePath()
        ?? profile.markdownPath(for: draft)
      do {
        let result = try siteDraftFileStore.write(draft: draft, profile: profile)
        applyWrittenSiteDraftRepositoryPath(
          result.repositoryPath,
          to: draftID,
          writtenDraft: draft,
          profile: profile
        )
        siteDraftFileSaveStates[draftID] = .saved(
          repositoryPath: result.repositoryPath,
          savedAt: Date()
        )
        scheduleDueOperationalRefresh()
      } catch {
        if case LocalPublishPreviewError.missingRepositoryRoot = error {
          // The app-level recovery copy remains available until the user
          // selects a project folder, so this does not make termination unsafe.
        } else {
          succeeded = false
        }
        siteDraftFileSaveStates[draftID] = .failed(
          repositoryPath: repositoryPath,
          message: error.localizedDescription
        )
        setSiteDraftFileFailureMessage(error)
      }
    }
    return succeeded
  }

  /// Explicitly adds a local-first site draft to the configured project.
  ///
  /// This is the only path that may write a draft whose repository binding is
  /// still empty. The file write happens first; only after it succeeds do we
  /// record the project path and rendered-content digest together, publish the
  /// save state, and persist the workbench snapshot. A failed write leaves the
  /// app-owned draft intact.
  @discardableResult
  public func writeSiteDraftToProject(draftID: UUID) async -> Bool {
    guard let draft = drafts.first(where: { $0.id == draftID }) else {
      setPublishActionMessage(CoreL10n.text("找不到要加入项目的草稿。"), status: .warning)
      return false
    }
    guard !draft.isGeneralDraft else {
      setPublishActionMessage(
        CoreL10n.text("通用草稿只保存在软件中；请使用导出功能选择保存位置。"),
        status: .warning
      )
      return false
    }
    guard !siteDraftFileWritesInProgress.contains(draftID) else {
      setPublishActionMessage(CoreL10n.text("这篇草稿正在写入项目，请稍候。"), status: .warning)
      return false
    }

    siteDraftFileAutosaveTasks[draftID]?.cancel()
    siteDraftFileAutosaveTasks[draftID] = nil
    let generation = (siteDraftFileSaveGenerations[draftID] ?? 0) &+ 1
    siteDraftFileSaveGenerations[draftID] = generation
    let profile = profile(for: draft)
    let repositoryPath = draft.repositoryPath?.normalizedRelativePath()
      ?? profile.markdownPath(for: draft)
    siteDraftFileSaveStates[draftID] = .pending(repositoryPath: repositoryPath)
    siteDraftFileWritesInProgress.insert(draftID)

    do {
      let result = try await siteDraftFileStore.writeAsync(
        draft: draft,
        profile: profile
      )
      siteDraftFileWritesInProgress.remove(draftID)

      guard let currentDraft = drafts.first(where: { $0.id == draftID }),
        !currentDraft.isGeneralDraft
      else {
        siteDraftFileSaveStates[draftID] = nil
        return true
      }

      let currentUpdatedAt = currentDraft.updatedAt
      applyWrittenSiteDraftRepositoryPath(
        result.repositoryPath,
        to: draftID,
        writtenDraft: draft,
        profile: profile
      )

      guard let latestDraft = drafts.first(where: { $0.id == draftID }) else {
        siteDraftFileSaveStates[draftID] = nil
        return true
      }
      let needsAnotherWrite =
        siteDraftFileSaveGenerations[draftID] != generation
        || currentUpdatedAt != draft.updatedAt
        || self.profile(for: latestDraft).markdownPath(for: latestDraft) != result.repositoryPath
      if needsAnotherWrite {
        scheduleSiteDraftFileAutosave(for: latestDraft, immediate: true)
        return true
      }

      siteDraftFileSaveStates[draftID] = .saved(
        repositoryPath: result.repositoryPath,
        savedAt: Date()
      )
      setPublishActionMessage(CoreL10n.text("已将草稿加入项目并写入文件。"), status: .success)
      save()
      scheduleDueOperationalRefresh()
      return true
    } catch {
      siteDraftFileWritesInProgress.remove(draftID)
      guard siteDraftFileSaveGenerations[draftID] == generation else {
        if let currentDraft = drafts.first(where: { $0.id == draftID }),
          !currentDraft.isGeneralDraft,
          currentDraft.repositoryPath?.nilIfEmpty != nil
        {
          scheduleSiteDraftFileAutosave(for: currentDraft, immediate: true)
        }
        return false
      }
      siteDraftFileSaveStates[draftID] = .failed(
        repositoryPath: repositoryPath,
        message: error.localizedDescription
      )
      setSiteDraftFileFailureMessage(error)
      return false
    }
  }

  func waitForPendingSiteDraftFileWrites() async {
    while true {
      if let reconciliationTask = siteDraftFileReconciliationTask {
        await reconciliationTask.value
        continue
      }
      guard !siteDraftFileAutosaveTasks.isEmpty || !siteDraftFileWritesInProgress.isEmpty else {
        return
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  private func finishSiteDraftFileWrite(
    draftID: UUID,
    writtenDraft: ArticleDraft,
    profile: SiteProfile,
    writtenDraftUpdatedAt: Date,
    generation: UInt64,
    result: SiteDraftFileWriteResult
  ) {
    siteDraftFileAutosaveTasks[draftID] = nil
    siteDraftFileWritesInProgress.remove(draftID)

    guard let currentDraft = drafts.first(where: { $0.id == draftID }),
      !currentDraft.isGeneralDraft,
      currentDraft.repositoryPath?.nilIfEmpty != nil,
      currentDraft.belongs(toSiteProfileID: profile.id)
    else {
      siteDraftFileSaveStates[draftID] = nil
      return
    }

    let currentUpdatedAt = currentDraft.updatedAt
    applyWrittenSiteDraftRepositoryPath(
      result.repositoryPath,
      to: draftID,
      writtenDraft: writtenDraft,
      profile: profile
    )

    guard let latestDraft = drafts.first(where: { $0.id == draftID }) else {
      siteDraftFileSaveStates[draftID] = nil
      return
    }
    let needsAnotherWrite =
      siteDraftFileSaveGenerations[draftID] != generation
      || currentUpdatedAt != writtenDraftUpdatedAt
      || self.profile(for: latestDraft).markdownPath(for: latestDraft) != result.repositoryPath
    if needsAnotherWrite {
      scheduleSiteDraftFileAutosave(for: latestDraft, immediate: true)
      return
    }

    siteDraftFileSaveStates[draftID] = .saved(
      repositoryPath: result.repositoryPath,
      savedAt: Date()
    )
    scheduleAutosave()
    scheduleDueOperationalRefresh()
  }

  private func failSiteDraftFileWrite(
    draftID: UUID,
    generation: UInt64,
    repositoryPath: String,
    error: Error
  ) {
    siteDraftFileAutosaveTasks[draftID] = nil
    siteDraftFileWritesInProgress.remove(draftID)
    guard siteDraftFileSaveGenerations[draftID] == generation else {
      if let currentDraft = drafts.first(where: { $0.id == draftID }),
        !currentDraft.isGeneralDraft
      {
        scheduleSiteDraftFileAutosave(for: currentDraft, immediate: true)
      }
      return
    }
    siteDraftFileSaveStates[draftID] = .failed(
      repositoryPath: repositoryPath,
      message: error.localizedDescription
    )
    setSiteDraftFileFailureMessage(error)
  }

  private func applyWrittenSiteDraftRepositoryPath(
    _ repositoryPath: String,
    to draftID: UUID,
    writtenDraft: ArticleDraft,
    profile: SiteProfile
  ) {
    guard let index = publishingStore.drafts.firstIndex(where: { $0.id == draftID }) else {
      return
    }
    guard publishingStore.drafts[index].belongs(toSiteProfileID: profile.id) else {
      return
    }
    var updatedDraft = publishingStore.drafts[index]
    updatedDraft.recordProjectFile(
      profile: profile,
      repositoryPath: repositoryPath,
      renderedContentDigest: writtenDraft.renderedRepositoryContentDigest(profile: profile)
    )
    // Keep the content timestamp stable: it participates in rendered Markdown.
    // Editor writes preserve the current repository state separately, so
    // changing `updatedAt` here would only invalidate the digest we just wrote
    // and force another full rewrite on the next launch.
    publishingStore.drafts[index] = updatedDraft
    scheduleAutosave()
  }

  private func setSiteDraftFileFailureMessage(_ error: Error) {
    if case LocalPublishPreviewError.missingRepositoryRoot = error {
      setPublishActionMessage(
        CoreL10n.text("当前站点未选择本地项目；站点草稿仍保存在软件中，请选择项目后使用“加入项目”重试。"),
        status: .warning
      )
    } else {
      setPublishActionMessage(
        CoreL10n.format("站点草稿写入项目失败：%@", error.localizedDescription),
        status: .failure
      )
    }
  }
}
