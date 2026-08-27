import Foundation

/// The small, deterministic portion of a preview's input which is not
/// represented by the rendered preview values themselves.  Keeping this
/// value separate from the task makes stale-result checks explicit and keeps
/// remote credentials out of the package builder.
struct DraftPublishPreviewCollisionInput: Hashable, Sendable {
  let draftID: UUID
  let title: String
  let markdownPath: String

  init(draftID: UUID, title: String, markdownPath: String) {
    self.draftID = draftID
    self.title = title
    self.markdownPath = markdownPath
  }
}

/// Complete immutable input baseline for one draft-scoped publish preview.
/// `draft` has its derived word count normalised because that field is updated
/// asynchronously and is not a publishing input.
struct DraftPublishPreviewInputBaseline: Hashable, Sendable {
  let context: DraftExecutionContext
  let draft: ArticleDraft
  let profile: SiteProfile
  let collisionInputs: [DraftPublishPreviewCollisionInput]
  let repositoryReport: RepositoryScanReport?
  let tokenAvailability: KeychainTokenAvailability
  let remoteRepositoryAccessCheck: RemoteRepositoryAccessCheck?

  init(
    context: DraftExecutionContext,
    draft: ArticleDraft,
    profile: SiteProfile,
    collisionInputs: [DraftPublishPreviewCollisionInput],
    repositoryReport: RepositoryScanReport?,
    tokenAvailability: KeychainTokenAvailability,
    remoteRepositoryAccessCheck: RemoteRepositoryAccessCheck?
  ) {
    self.context = context
    self.draft = draft
    self.profile = profile
    self.collisionInputs = collisionInputs
    self.repositoryReport = repositoryReport
    self.tokenAvailability = tokenAvailability
    self.remoteRepositoryAccessCheck = remoteRepositoryAccessCheck
  }
}

extension PublishingStore {
  func normalizedDraftPublishPreviewDraft(_ draft: ArticleDraft) -> ArticleDraft {
    var normalized = draft
    _ = normalized.storeWordCount(0, for: normalized.bodyMarkdown)
    return normalized
  }

  func repositoryTokenAvailabilityForPreview(
    profile: SiteProfile,
    store: WorkbenchStore
  ) -> KeychainTokenAvailability {
    // RepositoryStore owns the already-resolved state for the active profile,
    // including structured Keychain read failures. Keep using that projection
    // so preview code and repository settings agree. A background refresh for
    // another profile has no scalar projection and must read its scoped key.
    if profile.id == store.activeProfileID {
      return store.repositoryStore.repositoryTokenAvailability
    }
    do {
      return try repositoryTokenStore.repositoryTokenAvailability(for: profile)
    } catch {
      return KeychainTokenAvailability(accessFailure: error)
    }
  }

  /// Returns only a profile-matching and fresh access proof.  The active
  /// profile projection in `RepositoryStore` is deliberately not consulted;
  /// a background refresh may target a different profile.
  func freshRemoteRepositoryAccessCheckForPreview(
    profile: SiteProfile,
    store: WorkbenchStore,
    now: Date = Date()
  ) -> RemoteRepositoryAccessCheck? {
    guard let check = store.repositoryStore.remoteRepositoryAccessCheckByProfileID[profile.id],
          check.isFresh(at: now),
          check.provider == profile.repositoryProvider,
          check.repositoryName == profile.repositoryDisplayName
    else {
      return nil
    }

    guard let checkedAPIBaseURL = check.apiBaseURL?.nilIfEmpty else {
      return check
    }
    let profileAPIBaseURL: URL
    do {
      profileAPIBaseURL = try remoteRepositoryPublishService.apiBaseURL(for: profile)
    } catch {
      return nil
    }
    let normalizedChecked = checkedAPIBaseURL
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard normalizedChecked == remoteRepositoryPublishService
      .normalizedAPIBaseURLString(profileAPIBaseURL)
    else {
      return nil
    }
    return check
  }

  func makeDraftPublishPreviewInputBaseline(
    for draft: ArticleDraft,
    store: WorkbenchStore,
    bodyRevision: UInt64? = nil
  ) -> DraftPublishPreviewInputBaseline {
    let profile = store.profile(for: draft)
    let normalizedDraft = normalizedDraftPublishPreviewDraft(draft)
    let collisionInputs = store.drafts
      .filter { $0.belongs(toSiteProfileID: profile.id) }
      .map { collisionDraft in
        DraftPublishPreviewCollisionInput(
          draftID: collisionDraft.id,
          title: collisionDraft.title,
          markdownPath: profile.markdownPath(for: collisionDraft)
        )
      }
      .sorted { lhs, rhs in
        lhs.draftID.uuidString < rhs.draftID.uuidString
      }
    let resolvedBodyRevision = bodyRevision
      ?? store.draftBodyEditorBuffer(for: draft.id).revision
    return DraftPublishPreviewInputBaseline(
      context: DraftExecutionContext(
        draftID: draft.id,
        profileID: profile.id,
        bodyRevision: resolvedBodyRevision
      ),
      draft: normalizedDraft,
      profile: profile,
      collisionInputs: collisionInputs,
      repositoryReport: store.repositoryReport(for: profile),
      tokenAvailability: repositoryTokenAvailabilityForPreview(
        profile: profile,
        store: store
      ),
      remoteRepositoryAccessCheck: freshRemoteRepositoryAccessCheckForPreview(
        profile: profile,
        store: store
      )
    )
  }

  func currentDraftPublishPreviewInputBaseline(
    for draftID: UUID,
    store: WorkbenchStore
  ) -> DraftPublishPreviewInputBaseline? {
    guard let draft = store.draft(for: draftID) else { return nil }
    return makeDraftPublishPreviewInputBaseline(for: draft, store: store)
  }

  func isCurrentDraftPublishPreviewInput(
    _ baseline: DraftPublishPreviewInputBaseline,
    for draftID: UUID,
    store: WorkbenchStore
  ) -> Bool {
    guard draftID == baseline.context.draftID,
          let current = currentDraftPublishPreviewInputBaseline(
            for: draftID,
            store: store
          )
    else {
      return false
    }
    return current == baseline
  }

  func rememberDraftPublishPreviewInputBaseline(
    _ baseline: DraftPublishPreviewInputBaseline,
    for draftID: UUID
  ) {
    draftPublishPreviewInputBaselines[draftID] = baseline
  }

  func rememberedDraftPublishPreviewInputBaseline(
    for draftID: UUID
  ) -> DraftPublishPreviewInputBaseline? {
    draftPublishPreviewInputBaselines[draftID]
  }

  func forgetDraftPublishPreviewInputBaseline(for draftID: UUID) {
    draftPublishPreviewInputBaselines.removeValue(forKey: draftID)
  }

  func forgetAllDraftPublishPreviewInputBaselines() {
    draftPublishPreviewInputBaselines.removeAll(keepingCapacity: true)
  }
}
