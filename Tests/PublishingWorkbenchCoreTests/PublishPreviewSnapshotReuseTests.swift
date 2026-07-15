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
    XCTAssertEqual(actual.hasToken, expected.hasToken)
    XCTAssertEqual(actual.accessCheck, expected.accessCheck)
    XCTAssertEqual(issueSignatures(actual.blockingIssues), issueSignatures(expected.blockingIssues))
    XCTAssertEqual(issueSignatures(actual.warningIssues), issueSignatures(expected.warningIssues))
  }

  private func issueSignatures(_ issues: [PreflightIssue]) -> [String] {
    issues.map { issue in
      "\(issue.severity)|\(issue.title)|\(issue.message)|\(issue.field ?? "")"
    }
  }
}
