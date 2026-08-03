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
    XCTAssertEqual(
      builder.branchCommands(package: package, profile: profile),
      [
        "cd '/tmp/site'",
        "git switch -c 'publish/publish-me-20260829'",
        "git add 'content/posts/2026/publish-me.md'",
        "git commit -m 'Publish: Publish Me'",
        "git push -u origin 'publish/publish-me-20260829'",
      ]
    )
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

  func testBuildsBatchPullRequestDraftFromWritablePlan() throws {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.localRepositoryRootPath = "/tmp/site"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let firstDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "First",
      slug: "first",
      draft: false,
      bodyMarkdown: "Long enough body content for the first batch review draft article."
    )
    let secondDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Second",
      slug: "second",
      draft: false,
      bodyMarkdown: "Long enough body content for the second batch review draft article."
    )

    let firstPackage = PublishPackageBuilder().build(draft: firstDraft, profile: profile)
    let secondPackage = PublishPackageBuilder().build(draft: secondDraft, profile: profile)
    let generatedAt = Date(timeIntervalSince1970: 1_788_000_000)
    let plan = BatchPublishPlan(
      profileID: profile.id,
      siteName: profile.name,
      items: [
        writableBatchItem(package: firstPackage),
        writableBatchItem(package: secondPackage),
      ],
      generatedAt: generatedAt
    )

    let review = try XCTUnwrap(RemoteReviewDraftBuilder().buildBatch(plan: plan, profile: profile))

    XCTAssertEqual(review.branchName, "publish/batch-20260829-1040-2-articles")
    XCTAssertEqual(review.targetBranch, "main")
    XCTAssertEqual(review.title, CoreL10n.format("发布 %d 篇文章", 2))
    XCTAssertTrue(review.body.contains(CoreL10n.format("- 文章数：%d", 2)))
    XCTAssertTrue(
      review.body.contains(
        CoreL10n.format("- %@：`%@`（%d 个变化）", "First", "content/posts/first.md", 1)
      )
    )
    XCTAssertTrue(
      review.body.contains(
        CoreL10n.format("- %@：`%@`（%d 个变化）", "Second", "content/posts/second.md", 1)
      )
    )
    XCTAssertTrue(review.webURL?.absoluteString.contains("/owner/site/compare/main...publish/batch-20260829-1040-2-articles") == true)
  }

  func testBatchReviewDraftRequiresWritableItems() {
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = "/tmp/site"

    let plan = BatchPublishPlan(profileID: profile.id, siteName: profile.name, items: [])

    XCTAssertNil(RemoteReviewDraftBuilder().buildBatch(plan: plan, profile: profile))
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
