import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class PreviewPromotionPresentationTests: XCTestCase {
  func testPreviewBranchIsEligibleToCreateAReview() {
    let record = record(kind: .remotePreviewBranch)

    XCTAssertEqual(
      PreviewPromotionPresentation.eligibility(for: record),
      .eligible(.createReview)
    )
  }

  func testSingleOpenGitHubReviewIsEligibleToInspectAndMerge() {
    let record = record(kind: .remoteReviewRequest)

    XCTAssertEqual(
      PreviewPromotionPresentation.eligibility(for: record),
      .eligible(.inspectAndMerge)
    )
  }

  func testGitLabBatchAndMissingArticleRecordsAreNotEligible() {
    var gitLab = record(kind: .remotePreviewBranch)
    gitLab.repositoryProvider = .gitlab
    XCTAssertEqual(
      PreviewPromotionPresentation.eligibility(for: gitLab),
      .unavailable(.unsupportedProvider)
    )

    var batch = record(kind: .remotePreviewBranch)
    batch.batchItems = [
      ReleaseRecordBatchItem(
        draftID: UUID(), draftTitle: "另一篇", markdownPath: "content/other.md", changedPaths: []
      )
    ]
    XCTAssertEqual(
      PreviewPromotionPresentation.eligibility(for: batch),
      .unavailable(.batchRecord)
    )

    var missingArticle = record(kind: .remotePreviewBranch)
    missingArticle.markdownPath = nil
    XCTAssertEqual(
      PreviewPromotionPresentation.eligibility(for: missingArticle),
      .unavailable(.missingArticle)
    )
  }

  func testActionDisablesForPrivacyProtectionAndRemoteOperation() {
    let record = record(kind: .remotePreviewBranch)

    XCTAssertEqual(
      PreviewPromotionPresentation.actionState(
        for: record, canUseProtectedWorkbench: false, isRemoteRepositoryPublishing: false
      ),
      .disabled(.protectedWorkbenchUnavailable)
    )
    XCTAssertEqual(
      PreviewPromotionPresentation.actionState(
        for: record, canUseProtectedWorkbench: true, isRemoteRepositoryPublishing: true
      ),
      .disabled(.remoteOperationRunning)
    )
  }

  func testGitHubTokenSettingsLinkIsOnlyOfferedForDefaultGitHubCloud() {
    let cloudRecord = record(kind: .remoteReviewRequest)
    XCTAssertTrue(PreviewPromotionPresentation.offersGitHubTokenSettingsLink(for: cloudRecord))

    var enterpriseRecord = cloudRecord
    enterpriseRecord.repositoryBaseURL = "https://github.example.com/api/v3"
    XCTAssertFalse(
      PreviewPromotionPresentation.offersGitHubTokenSettingsLink(for: enterpriseRecord))

    var legacyRecord = cloudRecord
    legacyRecord.repositoryBaseURL = ""
    XCTAssertFalse(
      PreviewPromotionPresentation.offersGitHubTokenSettingsLink(
        for: legacyRecord,
        profileRepositoryBaseURL: "https://github.example.com/api/v3"
      )
    )

    var gitLabRecord = cloudRecord
    gitLabRecord.repositoryProvider = .gitlab
    XCTAssertFalse(PreviewPromotionPresentation.offersGitHubTokenSettingsLink(for: gitLabRecord))

    var unknownProviderRecord = cloudRecord
    unknownProviderRecord.repositoryProvider = nil
    XCTAssertFalse(
      PreviewPromotionPresentation.offersGitHubTokenSettingsLink(for: unknownProviderRecord))
  }

  func testWorkflowLoadingAndMergeSuccessRemainDeploymentPending() {
    XCTAssertTrue(PreviewPromotionWorkflowState.merging.isLoading)
    XCTAssertFalse(PreviewPromotionWorkflowState.completed.isLoading)

    let message = PreviewPromotionPresentation.completionMessage(
      for: record(kind: .remoteReviewRequest),
      mergedCommitSHA: "0123456789abcdef"
    )
    XCTAssertTrue(message.contains("已合并提交 01234567"))
    XCTAssertTrue(message.contains("部署待验证"))
    XCTAssertTrue(message.contains("尚未确认上线"))
  }

  func testBlockersAndContextChangesRequireFurtherHandling() {
    XCTAssertFalse(
      ReviewMergePlan(
        record: record(kind: .remoteReviewRequest),
        profile: profile(),
        sourceCommitSHA: "source",
        targetCommitSHA: "target",
        files: [
          PreviewPromotionFile(
            path: "content/article.md", status: "modified", blobSHA: "sha", additions: 1,
            deletions: 0, patch: nil)
        ],
        markdown: "# Article",
        blockers: ["等待必需检查"],
        mergedCommitSHA: nil,
        checkedAt: Date()
      ).canMerge)

    let source = record(kind: .remotePreviewBranch)
    let context = PreviewPromotionTaskContext(
      record: source,
      profileID: source.siteProfileID!,
      selectedDraftID: source.draftID
    )
    XCTAssertFalse(
      PreviewPromotionPresentation.acceptsCompletion(
        context,
        activeProfileID: UUID(),
        selectedDraftID: source.draftID,
        canUseProtectedWorkbench: true
      )
    )
    XCTAssertFalse(
      PreviewPromotionPresentation.acceptsCompletion(
        context,
        activeProfileID: source.siteProfileID!,
        selectedDraftID: UUID(),
        canUseProtectedWorkbench: true
      )
    )
    XCTAssertFalse(
      PreviewPromotionPresentation.acceptsCompletion(
        context,
        activeProfileID: source.siteProfileID!,
        selectedDraftID: source.draftID,
        canUseProtectedWorkbench: false
      )
    )
  }

  private func profile() -> SiteProfile {
    SiteProfile(name: "测试站点")
  }

  private func record(kind: ReleaseRecordKind) -> ReleaseRecord {
    let profile = profile()
    return ReleaseRecord(
      kind: kind,
      title: "发布：文章",
      summary: "预览记录",
      siteProfileID: profile.id,
      siteName: profile.name,
      draftID: UUID(),
      draftTitle: "文章",
      markdownPath: "content/article.md",
      repositoryProvider: .github,
      repoOwner: "owner",
      repoName: "repo",
      branchName: "preview/article",
      targetBranch: "main",
      commitSHA: "0123456789abcdef"
    )
  }
}
