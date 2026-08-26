import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class PublishPreviewSnapshotReuseTests: XCTestCase {
  func testRefreshReusesPreflightSnapshotsWithoutChangingPreviewResults() throws {
    let store = try TestWorkbenchFactory.makeStore()

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .reviewRequest
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.localRepositoryRootPath = "/tmp/publish-preview-snapshot-reuse"
    store.updateActiveProfile(profile)

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Snapshot Reuse",
      slug: "snapshot-reuse",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for publish preview snapshot reuse coverage."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setRepositoryReport(RepositoryScanReport(
      rootPath: profile.localRepositoryRootPath,
      detectedKind: profile.siteKind,
      expectedKind: profile.siteKind,
      hasGitDirectory: false,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 0,
      imageFileCount: 0,
      changedFiles: [],
      remoteChangedFiles: [
        RepositoryChangedFile(
          status: "M",
          path: "content/posts/snapshot-reuse.md",
          kind: .modified
        ),
      ],
      preflightIssues: [
        PreflightIssue(
          severity: .error,
          title: "未发现 .git",
          message: "当前目录不是 Git 仓库。",
          field: "repository"
        ),
      ]
    ))

    let package = store.publishingPackage(for: draft)
    let localPreview = store.localPublishPreview(for: draft)
    let expectedReviewDraft = store.remoteReviewDraft(for: draft)
    let expectedContext = DraftExecutionContext(
      draftID: draft.id,
      profileID: profile.id,
      bodyRevision: store.draftBodyEditorBuffer(for: draft.id).revision
    )
    let issuesWithoutRepository = store.preflightIssues(
      for: draft,
      includeRepositoryReadiness: false
    )
    let issuesWithRepository = store.preflightIssues(
      for: draft,
      includeRepositoryReadiness: true
    )
    XCTAssertNotEqual(issuesWithoutRepository, issuesWithRepository)

    let expectedReadiness = store.makeLocalPublishReadiness(
      package: package,
      profile: profile,
      preview: localPreview
    )
    let reusedReadiness = store.publishingStore.makeLocalPublishReadiness(
      package: package,
      profile: profile,
      preview: localPreview,
      draftIssuesWithoutRepository: issuesWithoutRepository,
      draftIssuesWithRepository: issuesWithRepository,
      store: store
    )
    assertEquivalent(reusedReadiness, expectedReadiness)

    let mode = store.preferredRemoteRepositoryPublishMode(for: profile)
    let expectedRemotePreview = store.remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: mode,
      localPreview: localPreview
    )
    let reusedRemotePreview = store.publishingStore.remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: mode,
      localPreview: localPreview,
      draftIssuesWithRepository: issuesWithRepository,
      store: store
    )
    assertEquivalent(reusedRemotePreview, expectedRemotePreview)

    store.refreshPublishPreview(for: draft)

    assertEquivalent(try XCTUnwrap(store.localPublishReadiness), expectedReadiness)
    assertEquivalent(try XCTUnwrap(store.remotePublishPreviewSnapshot), expectedRemotePreview)

    let snapshot = try XCTUnwrap(store.cachedPublishPreview(for: draft.id))
    assertEquivalent(
      snapshot,
      context: expectedContext,
      package: package,
      localPreview: localPreview,
      readiness: expectedReadiness,
      remotePreview: expectedRemotePreview,
      reviewDraft: expectedReviewDraft
    )
  }

  private func assertEquivalent(
    _ actual: LocalPublishReadiness,
    _ expected: LocalPublishReadiness
  ) {
    XCTAssertEqual(actual.writeReadiness, expected.writeReadiness)
    XCTAssertEqual(actual.commitReadiness, expected.commitReadiness)
    XCTAssertEqual(actual.changedFileCount, expected.changedFileCount)
    XCTAssertEqual(actual.fileCount, expected.fileCount)
    XCTAssertEqual(issueSignatures(actual.writeBlockingIssues), issueSignatures(expected.writeBlockingIssues))
    XCTAssertEqual(issueSignatures(actual.commitBlockingIssues), issueSignatures(expected.commitBlockingIssues))
    XCTAssertEqual(issueSignatures(actual.warningIssues), issueSignatures(expected.warningIssues))
  }

  private func assertEquivalent(
    _ actual: RemoteRepositoryPublishPreview,
    _ expected: RemoteRepositoryPublishPreview
  ) {
    XCTAssertEqual(actual.provider, expected.provider)
    XCTAssertEqual(actual.repositoryName, expected.repositoryName)
    XCTAssertEqual(actual.mode, expected.mode)
    XCTAssertEqual(actual.branchName, expected.branchName)
    XCTAssertEqual(actual.targetBranch, expected.targetBranch)
    XCTAssertEqual(actual.changedPaths, expected.changedPaths)
    XCTAssertEqual(actual.remoteConflictPaths, expected.remoteConflictPaths)
    XCTAssertEqual(actual.remoteRiskState, expected.remoteRiskState)
    XCTAssertEqual(actual.hasToken, expected.hasToken)
    XCTAssertEqual(actual.accessCheck, expected.accessCheck)
    XCTAssertEqual(issueSignatures(actual.blockingIssues), issueSignatures(expected.blockingIssues))
    XCTAssertEqual(issueSignatures(actual.warningIssues), issueSignatures(expected.warningIssues))
  }

  private func assertEquivalent(
    _ snapshot: DraftPublishPreviewSnapshot,
    context: DraftExecutionContext,
    package: PublishPackage,
    localPreview: LocalPublishPreview,
    readiness: LocalPublishReadiness,
    remotePreview: RemoteRepositoryPublishPreview,
    reviewDraft: RemoteReviewDraft
  ) {
    // Treat all six values as one transaction: every derived value must point
    // at the same draft/profile context, and issue comparisons intentionally
    // ignore UUIDs assigned to independently generated issues.
    XCTAssertEqual(snapshot.context, context)
    XCTAssertEqual(snapshot.publishPackage.draftID, context.draftID)
    XCTAssertEqual(snapshot.localPublishPreview.package.draftID, context.draftID)
    XCTAssertEqual(snapshot.remotePublishPreview.changedPaths, remotePreview.changedPaths)
    XCTAssertEqual(snapshot.remoteReviewDraft, reviewDraft)
    assertEquivalent(snapshot.publishPackage, package)
    assertEquivalent(snapshot.localPublishPreview, localPreview)
    assertEquivalent(snapshot.localPublishReadiness, readiness)
    assertEquivalent(snapshot.remotePublishPreview, remotePreview)
  }

  private func assertEquivalent(_ actual: LocalPublishPreview, _ expected: LocalPublishPreview) {
    assertEquivalent(actual.package, expected.package)
    XCTAssertEqual(actual.fileDiffs, expected.fileDiffs)
    XCTAssertEqual(issueSignatures(actual.issues), issueSignatures(expected.issues))
  }

  private func assertEquivalent(_ actual: PublishPackage, _ expected: PublishPackage) {
    XCTAssertEqual(actual.draftID, expected.draftID)
    XCTAssertEqual(actual.title, expected.title)
    XCTAssertEqual(actual.draftSummary, expected.draftSummary)
    XCTAssertEqual(actual.draftCoverAltText, expected.draftCoverAltText)
    XCTAssertEqual(actual.markdownPath, expected.markdownPath)
    XCTAssertEqual(actual.files, expected.files)
    XCTAssertEqual(actual.commitMessage, expected.commitMessage)
    XCTAssertEqual(actual.reviewBranchName, expected.reviewBranchName)
    XCTAssertEqual(actual.reviewTitle, expected.reviewTitle)
    XCTAssertEqual(actual.reviewChecklist, expected.reviewChecklist)
  }

  private func issueSignatures(_ issues: [PreflightIssue]) -> [String] {
    issues.map { issue in
      "\(issue.severity)|\(issue.title)|\(issue.message)|\(issue.field ?? "")"
    }
  }
}
