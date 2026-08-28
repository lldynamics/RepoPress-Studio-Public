import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class UnifiedPublishSummaryPresentationTests: XCTestCase {
  func testSummaryCountsBatchArticlesAndDeduplicatesImagePaths() {
    let newItem = makeItem(
      title: "New",
      markdownPath: "content/new.md",
      markdownStatus: .added,
      imagePath: "static/shared.webp",
      imageStatus: .added
    )
    let modifiedItem = makeItem(
      title: "Changed",
      markdownPath: "content/changed.md",
      markdownStatus: .modified,
      imagePath: "static/shared.webp",
      imageStatus: .modified
    )
    let plan = BatchPublishPlan(
      profileID: UUID(),
      siteName: "Site",
      items: [newItem, modifiedItem]
    )
    let profile = SiteProfile(
      name: "Site",
      repositoryProvider: .gitlab,
      branch: "main",
      repositoryPublishStrategy: .direct
    )
    let preview = RemoteRepositoryPublishPreview(
      provider: .gitlab,
      repositoryName: "group/site",
      mode: .directCommit,
      branchName: "main",
      targetBranch: "main",
      changedPaths: ["content/new.md", "content/changed.md", "static/shared.webp"],
      remoteRiskState: .clean,
      hasToken: true,
      blockingIssues: [],
      warningIssues: []
    )

    let summary = UnifiedPublishSummaryPresentation.make(
      plan: plan,
      preview: preview,
      profile: profile,
      pendingDeletionCount: 1
    )

    XCTAssertEqual(summary.articleCount, 2)
    XCTAssertEqual(summary.newArticleCount, 1)
    XCTAssertEqual(summary.modifiedArticleCount, 1)
    XCTAssertEqual(summary.imageChangeCount, 1)
    XCTAssertEqual(summary.newImageCount, 1)
    XCTAssertEqual(summary.deletionCount, 1)
    XCTAssertEqual(summary.targetTitle, "main · GitLab")
    XCTAssertEqual(summary.actionTitle, "一键发布上线")
    XCTAssertTrue(summary.preflightTitle.contains("已检查项"))
    XCTAssertTrue(summary.pipelineTitle.contains("部署检查"))
  }

  func testReviewStrategyUsesReviewRequestLanguage() {
    let profile = SiteProfile(
      name: "Site",
      repositoryProvider: .github,
      branch: "release",
      repositoryPublishStrategy: .reviewRequest
    )

    let summary = UnifiedPublishSummaryPresentation.make(
      plan: nil,
      preview: nil,
      profile: profile,
      pendingDeletionCount: 0
    )

    XCTAssertEqual(summary.actionTitle, "一键创建 PR/MR")
    XCTAssertEqual(summary.targetTitle, "release · GitHub")
    XCTAssertTrue(summary.pipelineTitle.contains("创建 PR/MR"))
  }

  func testSummaryKeepsContentHealthAsReadOnlyEvidence() {
    let profile = SiteProfile(name: "Site")
    let health = UnifiedPublishReadinessPresentation.ContentHealth(
      errorCount: 2,
      warningCount: 3,
      aiFixCount: 1,
      passingDraftCount: 4
    )

    let summary = UnifiedPublishReadinessPresentation.make(
      plan: nil,
      preview: nil,
      profile: profile,
      pendingDeletionCount: 0,
      contentHealth: health
    )

    XCTAssertEqual(summary.contentHealth, health)
    XCTAssertEqual(summary.preflightTitle, "正在汇总发布检查")
  }

  private func makeItem(
    title: String,
    markdownPath: String,
    markdownStatus: PublishFileDiffStatus,
    imagePath: String,
    imageStatus: PublishFileDiffStatus
  ) -> BatchPublishPlanItem {
    let package = PublishPackage(
      draftID: UUID(),
      title: title,
      markdownPath: markdownPath,
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: markdownPath,
          content: "body"
        ),
        PublishPackageFile(
          kind: .image,
          repositoryPath: imagePath,
          sourceFilePath: "/tmp/image.webp"
        ),
      ],
      commitMessage: "Publish \(title)",
      reviewBranchName: "publish/test",
      reviewTitle: "Publish \(title)",
      reviewChecklist: []
    )
    let preview = LocalPublishPreview(
      package: package,
      fileDiffs: [
        PublishFileDiff(path: markdownPath, kind: .markdown, status: markdownStatus),
        PublishFileDiff(path: imagePath, kind: .image, status: imageStatus),
      ],
      issues: []
    )
    return BatchPublishPlanItem(
      draftID: package.draftID,
      draftTitle: title,
      markdownPath: markdownPath,
      readiness: .ready,
      package: package,
      preview: preview,
      preflightIssues: []
    )
  }
}
