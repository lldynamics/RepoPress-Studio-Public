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

extension WorkbenchStore {
  func scheduleSiteDraftFileAutosave(
    for draft: ArticleDraft,
    immediate: Bool = false
  ) {
    guard !draft.isGeneralDraft else {
      cancelSiteDraftFileAutosave(for: draft.id)
      return
    }

    let profile = profile(for: draft)
    let repositoryPath = profile.markdownPath(for: draft)
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
        !currentDraft.isGeneralDraft
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
        guard !Task.isCancelled else { return }
        self.finishSiteDraftFileWrite(
          draftID: draft.id,
          writtenDraftUpdatedAt: currentDraft.updatedAt,
          generation: generation,
          result: result
        )
      } catch {
        guard !Task.isCancelled else { return }
        self.failSiteDraftFileWrite(
          draftID: draft.id,
          generation: generation,
          repositoryPath: currentProfile.markdownPath(for: currentDraft),
          error: error
        )
      }
    }
  }

  func scheduleMissingSiteDraftFileWrites() {
    for draft in drafts where !draft.isGeneralDraft && draft.repositoryPath?.nilIfEmpty == nil {
      let profile = profile(for: draft)
      guard profile.localRepositoryRootURL != nil else { continue }
      scheduleSiteDraftFileAutosave(for: draft, immediate: true)
    }
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
      .union(
        drafts.compactMap { draft in
          guard !draft.isGeneralDraft,
            draft.repositoryPath?.nilIfEmpty == nil,
            profile(for: draft).localRepositoryRootURL != nil
          else {
            return nil
          }
          return draft.id
        })

    for draftID in pendingIDs {
      siteDraftFileSaveGenerations[draftID] = (siteDraftFileSaveGenerations[draftID] ?? 0) &+ 1
      siteDraftFileAutosaveTasks[draftID]?.cancel()
    }
    siteDraftFileAutosaveTasks.removeAll()
    siteDraftFileWritesInProgress.removeAll()

    var succeeded = true
    for draftID in pendingIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let draft = drafts.first(where: { $0.id == draftID }),
        !draft.isGeneralDraft
      else {
        siteDraftFileSaveStates[draftID] = nil
        continue
      }
      let profile = profile(for: draft)
      let repositoryPath = profile.markdownPath(for: draft)
      do {
        let result = try siteDraftFileStore.write(draft: draft, profile: profile)
        applyWrittenSiteDraftRepositoryPath(result.repositoryPath, to: draftID)
        siteDraftFileSaveStates[draftID] = .saved(
          repositoryPath: result.repositoryPath,
          savedAt: Date()
        )
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

  func waitForPendingSiteDraftFileWrites() async {
    while !siteDraftFileAutosaveTasks.isEmpty || !siteDraftFileWritesInProgress.isEmpty {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  private func finishSiteDraftFileWrite(
    draftID: UUID,
    writtenDraftUpdatedAt: Date,
    generation: UInt64,
    result: SiteDraftFileWriteResult
  ) {
    siteDraftFileAutosaveTasks[draftID] = nil
    siteDraftFileWritesInProgress.remove(draftID)
    applyWrittenSiteDraftRepositoryPath(result.repositoryPath, to: draftID)

    guard let currentDraft = drafts.first(where: { $0.id == draftID }),
      !currentDraft.isGeneralDraft
    else {
      siteDraftFileSaveStates[draftID] = nil
      return
    }

    let needsAnotherWrite =
      siteDraftFileSaveGenerations[draftID] != generation
      || currentDraft.updatedAt != writtenDraftUpdatedAt
      || profile(for: currentDraft).markdownPath(for: currentDraft) != result.repositoryPath
    if needsAnotherWrite {
      scheduleSiteDraftFileAutosave(for: currentDraft, immediate: true)
      return
    }

    siteDraftFileSaveStates[draftID] = .saved(
      repositoryPath: result.repositoryPath,
      savedAt: Date()
    )
    scheduleAutosave()
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
    to draftID: UUID
  ) {
    guard let index = publishingStore.drafts.firstIndex(where: { $0.id == draftID }),
      publishingStore.drafts[index].repositoryPath != repositoryPath
    else {
      return
    }
    publishingStore.drafts[index].repositoryPath = repositoryPath
    publishingStore.drafts[index].repositorySHA = nil
    scheduleAutosave()
  }

  private func setSiteDraftFileFailureMessage(_ error: Error) {
    if case LocalPublishPreviewError.missingRepositoryRoot = error {
      setPublishActionMessage(
        CoreL10n.text("当前站点未选择本地项目；站点草稿暂存在软件中，选择项目后会自动写入。")
      )
    } else {
      setPublishActionMessage(
        CoreL10n.format("站点草稿写入项目失败：%@", error.localizedDescription)
      )
    }
  }
}
