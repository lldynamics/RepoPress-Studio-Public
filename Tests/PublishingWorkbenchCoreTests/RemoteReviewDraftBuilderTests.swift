import XCTest
@testable import PublishingWorkbenchCore

final class RemoteReviewDraftBuilderTests: XCTestCase {
  func testBuildsGitHubPullRequestURLAndCommands() throws {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.localRepositoryRootPath = "/tmp/site"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Publish Me",
      date: Date(timeIntervalSince1970: 1_788_000_000),
      slug: "publish-me",
      draft: false,
      bodyMarkdown: "Body"
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let builder = RemoteReviewDraftBuilder()
    let review = builder.build(package: package, profile: profile)

    XCTAssertEqual(review.branchName, "publish/publish-me-20260829")
    XCTAssertEqual(review.targetBranch, "main")
    XCTAssertEqual(review.webURL?.host, "github.com")
    XCTAssertTrue(review.webURL?.absoluteString.contains("/owner/site/compare/main...publish/publish-me-20260829") == true)
    XCTAssertTrue(review.body.contains("文章路径：`content/posts/2026/publish-me.md`"))
  }

  func testBuildsGitLabMergeRequestURL() {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitLab Draft",
      date: Date(timeIntervalSince1970: 1_788_000_000),
      slug: "gitlab-draft",
      draft: false,
      bodyMarkdown: "Body"
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let review = RemoteReviewDraftBuilder().build(package: package, profile: profile)

    XCTAssertEqual(review.webURL?.host, "gitlab.com")
    XCTAssertEqual(review.webURL?.path, "/group/site/-/merge_requests/new")
    let queryItems = URLComponents(url: review.webURL!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertTrue(queryItems.contains {
      $0.name == "merge_request[source_branch]" && $0.value == "publish/gitlab-draft-20260829"
    })
  }

  private func writableBatchItem(package: PublishPackage) -> BatchPublishPlanItem {
    let preview = LocalPublishPreview(
      package: package,
      fileDiffs: [
        PublishFileDiff(path: package.markdownPath, kind: .markdown, status: .added)
      ],
      issues: []
    )

    return BatchPublishPlanItem(
      draftID: package.draftID,
      draftTitle: package.title,
      markdownPath: package.markdownPath,
      readiness: .ready,
      package: package,
      preview: preview,
      preflightIssues: []
    )
  }
}
