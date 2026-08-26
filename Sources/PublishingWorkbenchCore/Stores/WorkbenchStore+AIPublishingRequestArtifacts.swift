import Foundation

struct AIPublishingRequestArtifacts: Sendable {
  let draft: ArticleDraft
  let profile: SiteProfile
  let preflightIssues: [PreflightIssue]
  let publishPackage: PublishPackage
  let remoteReviewDraft: RemoteReviewDraft
  let workflowContext: AIPublishingWorkflowContext
}

extension WorkbenchStore {
  func aiPublishingRequestArtifacts(for draft: ArticleDraft) async -> AIPublishingRequestArtifacts {
    flushDraftBodyEditorBuffer(for: draft.id)
    var currentDraft = drafts.first(where: { $0.id == draft.id }) ?? draft
    var requestProfile = profile(for: currentDraft)

    await imageStore.refreshImageWorkbenchReportInBackground(for: currentDraft)
    let latestDraft = drafts.first(where: { $0.id == draft.id }) ?? currentDraft
    if latestDraft != currentDraft {
      if latestDraft.siteProfileID != currentDraft.siteProfileID {
        requestProfile = profile(for: latestDraft)
      }
      currentDraft = latestDraft
      await imageStore.refreshImageWorkbenchReportInBackground(for: currentDraft)
    }
    let imageReport = imageStore.cachedImageWorkbenchReport(for: currentDraft)
      ?? imageStore.imageWorkbenchReport(for: currentDraft)

    return await publishingStore.aiPublishingRequestArtifacts(
      for: currentDraft,
      profile: requestProfile,
      imageReport: imageReport,
      store: self
    )
  }
}

extension PublishingStore {
  func aiPublishingRequestArtifacts(
    for draft: ArticleDraft,
    profile: SiteProfile,
    imageReport: ImageWorkbenchReport,
    store: WorkbenchStore
  ) async -> AIPublishingRequestArtifacts {
    let package = publishPackageBuilder.build(draft: draft, profile: profile)
    let currentBaseline = makeDraftPublishPreviewInputBaseline(
      for: draft,
      store: store
    )
    let cachedSnapshot = draftPublishPreviewSnapshot(for: draft.id)
    let canReuseCachedArtifacts =
      cachedSnapshot?.publishPackage.hasSamePublishingPayload(as: package) == true
      && rememberedDraftPublishPreviewInputBaseline(for: draft.id) == currentBaseline

    let preview: LocalPublishPreview
    if canReuseCachedArtifacts, let cachedPreview = cachedSnapshot?.localPublishPreview {
      preview = LocalPublishPreview(
        package: package,
        fileDiffs: cachedPreview.fileDiffs,
        issues: cachedPreview.issues,
        generatedAt: cachedPreview.generatedAt
      )
    } else {
      preview = await localPublishPreviewService.previewAsync(package: package, profile: profile)
    }

    let reviewDraft = canReuseCachedArtifacts
      ? (cachedSnapshot?.remoteReviewDraft
        ?? remoteReviewDraftBuilder.build(package: package, profile: profile))
      : remoteReviewDraftBuilder.build(package: package, profile: profile)

    return AIPublishingRequestArtifacts(
      draft: draft,
      profile: profile,
      preflightIssues: preflightIssues(for: draft, store: store),
      publishPackage: package,
      remoteReviewDraft: reviewDraft,
      workflowContext: AIPublishingWorkflowContext(
        publishPreview: preview,
        localSitePreviewPlan: localSitePreviewPlan(for: draft, store: store),
        imageReport: imageReport
      )
    )
  }
}

private extension PublishPackage {
  func hasSamePublishingPayload(as other: PublishPackage) -> Bool {
    draftID == other.draftID
      && title == other.title
      && draftSummary == other.draftSummary
      && draftCoverAltText == other.draftCoverAltText
      && markdownPath == other.markdownPath
      && files == other.files
      && commitMessage == other.commitMessage
      && reviewBranchName == other.reviewBranchName
      && reviewTitle == other.reviewTitle
      && reviewChecklist == other.reviewChecklist
  }
}
