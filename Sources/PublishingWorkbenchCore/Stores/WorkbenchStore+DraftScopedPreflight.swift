import Foundation

private struct DraftScopedPreflightSnapshot: Sendable {
  let draft: ArticleDraft
  let profile: SiteProfile
  let sameSiteDrafts: [ArticleDraft]
  let repositoryReport: RepositoryScanReport?
  let context: DraftExecutionContext
}

private func hasSamePreflightInputs(_ lhs: [ArticleDraft], _ rhs: [ArticleDraft]) -> Bool {
  guard lhs.count == rhs.count else { return false }
  return zip(lhs, rhs).allSatisfy { current, snapshot in
    current.hasSamePreflightInput(as: snapshot)
  }
}

extension WorkbenchStore {
  /// Runs preflight for an explicit draft without depending on the active
  /// editor selection or mutating the shared preflight projection.
  ///
  /// The editor buffer for only `draftID` is committed before the immutable
  /// snapshot is captured. Detached work is discarded when any input that can
  /// affect duplicate, profile, or repository checks changes before it
  /// finishes.
  public func runPreflight(for draftID: UUID) async -> DraftPreflightResult? {
    flushDraftBodyEditorBuffer(for: draftID)
    if let wordCountRefreshTask = draftWordCountRefreshTasks[draftID] {
      await wordCountRefreshTask.value
    }
    guard !Task.isCancelled else { return nil }

    guard let draftSnapshot = draft(for: draftID) else { return nil }
    let profileSnapshot = profile(for: draftSnapshot)
    let sameSiteDrafts = drafts
      .filter { $0.belongs(toSiteProfileID: draftSnapshot.siteProfileID) }
      .sorted { $0.id.uuidString < $1.id.uuidString }
    let repositoryReportSnapshot = repositoryReport(for: profileSnapshot)
    let bodyRevision = draftBodyEditorBuffer(for: draftID).revision
    let snapshot = DraftScopedPreflightSnapshot(
      draft: draftSnapshot,
      profile: profileSnapshot,
      sameSiteDrafts: sameSiteDrafts,
      repositoryReport: repositoryReportSnapshot,
      context: DraftExecutionContext(
        draftID: draftID,
        profileID: profileSnapshot.id,
        bodyRevision: bodyRevision
      )
    )
    let preflightService = publishingStore.preflightService
    let generalDraftPublishingIssue = publishingStore.generalDraftPublishingIssue

    let calculationTask: Task<[PreflightIssue]?, Never> = Task.detached(
      priority: .userInitiated
    ) {
      guard !Task.isCancelled else { return nil }
      if snapshot.draft.isGeneralDraft {
        return [generalDraftPublishingIssue]
      }

      let duplicateIndex = PreflightDuplicateIndex(
        drafts: snapshot.sameSiteDrafts,
        profile: snapshot.profile
      )
      return preflightService.run(
        draft: snapshot.draft,
        allDrafts: snapshot.sameSiteDrafts,
        profile: snapshot.profile,
        repositoryReport: snapshot.repositoryReport,
        includeRepositoryReadiness: true,
        duplicateIndex: duplicateIndex
      )
    }
    let issues = await withTaskCancellationHandler(
      operation: {
        await calculationTask.value
      },
      onCancel: {
        calculationTask.cancel()
      }
    )

    guard let currentDraft = draft(for: draftID) else { return nil }
    let currentBodyBuffer = draftBodyEditorBuffer(for: draftID)
    let currentSameSiteDrafts = drafts
      .filter { $0.belongs(toSiteProfileID: currentDraft.siteProfileID) }
      .sorted { $0.id.uuidString < $1.id.uuidString }
    let currentProfile = profile(for: currentDraft)
    let currentRepositoryReport = repositoryReport(for: currentProfile)

    guard
      !Task.isCancelled,
      let issues,
      currentDraft.hasSamePreflightInput(as: snapshot.draft),
      currentBodyBuffer.revision == snapshot.context.bodyRevision,
      !currentBodyBuffer.isDirty,
      currentProfile == snapshot.profile,
      hasSamePreflightInputs(currentSameSiteDrafts, snapshot.sameSiteDrafts),
      currentRepositoryReport == snapshot.repositoryReport
    else {
      return nil
    }

    return DraftPreflightResult(context: snapshot.context, issues: issues)
  }
}
