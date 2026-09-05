import CryptoKit
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RemoteRepositoryPublishServiceGitHubReviewTests: RemoteRepositoryPublishServiceTestCase
{
  func testGitHubReviewPublishCreatesBranchWritesContentsAndPullRequest() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"base-sha"}}"#),
      response(
        json: #"{"ref":"refs/heads/publish/github-review-20260829","object":{"sha":"base-sha"}}"#),
      response(statusCode: 404, json: #"{"message":"not found"}"#),
      response(
        json:
          #"{"content":{"path":"content/posts/github-review.md"},"commit":{"sha":"commit-sha-1"}}"#),
      response(json: #"{"html_url":"https://github.com/owner/site/pull/12"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitHub Review",
      date: fixedDate(),
      slug: "github-review",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitHub review publishing."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .reviewRequest,
      token: "secret-token"
    )

    XCTAssertEqual(result.provider, .github)
    XCTAssertEqual(result.repositoryName, "owner/site")
    XCTAssertEqual(result.apiBaseURL, "https://api.github.com")
    XCTAssertEqual(result.mode, .reviewRequest)
    XCTAssertEqual(result.branchName, "publish/github-review-20260829")
    XCTAssertEqual(result.targetBranch, "main")
    XCTAssertEqual(result.commitSHA, "commit-sha-1")
    XCTAssertEqual(result.reviewURL, "https://github.com/owner/site/pull/12")
    XCTAssertTrue(
      result.remoteVerificationMarkdown.contains(
        "https://api.github.com/repos/owner/site/commits/commit-sha-1"))
    XCTAssertTrue(
      result.remoteVerificationMarkdown.contains("https://api.github.com/repos/owner/site/pulls/12")
    )
    XCTAssertTrue(
      result.remoteVerificationMarkdown.contains(
        "contents/content/posts/github-review.md?ref=publish%2Fgithub-review-20260829"))

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "PUT", "POST"])
    XCTAssertEqual(requests[0].url?.path, "/repos/owner/site/git/ref/heads/main")
    XCTAssertEqual(requests[1].url?.path, "/repos/owner/site/git/refs")
    XCTAssertEqual(
      requests[2].url?.path, "/repos/owner/site/contents/content/posts/github-review.md")
    XCTAssertEqual(
      requests[3].url?.path, "/repos/owner/site/contents/content/posts/github-review.md")
    XCTAssertEqual(requests[4].url?.path, "/repos/owner/site/pulls")
    XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")

    let putBody = try jsonBody(requests[3])
    XCTAssertEqual(putBody["branch"] as? String, "publish/github-review-20260829")
    XCTAssertEqual(putBody["message"] as? String, "Publish: GitHub Review")
    XCTAssertNotNil(putBody["content"] as? String)

    let pullBody = try jsonBody(requests[4])
    XCTAssertEqual(pullBody["head"] as? String, "publish/github-review-20260829")
    XCTAssertEqual(pullBody["base"] as? String, "main")
  }

  func testGitHubReviewPublishReusesExistingReviewBranchOnRetry() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"base-sha"}}"#),
      response(statusCode: 422, json: #"{"message":"Reference already exists"}"#),
      response(json: #"{"sha":"existing-file-sha"}"#),
      response(
        json:
          #"{"content":{"path":"content/posts/github-review.md"},"commit":{"sha":"retry-commit-sha"}}"#
      ),
      response(json: #"[]"#),
      response(json: #"{"html_url":"https://github.com/owner/site/pull/13"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitHub Review",
      date: fixedDate(),
      slug: "github-review",
      draft: false,
      bodyMarkdown:
        "This body is intentionally long enough for GitHub review publishing retry behavior."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .reviewRequest,
      token: "secret-token"
    )

    XCTAssertEqual(result.provider, .github)
    XCTAssertEqual(result.mode, .reviewRequest)
    XCTAssertEqual(result.branchName, "publish/github-review-20260829")
    XCTAssertEqual(result.commitSHA, "retry-commit-sha")
    XCTAssertEqual(result.reviewURL, "https://github.com/owner/site/pull/13")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "PUT", "GET", "POST"])
    XCTAssertEqual(requests[1].url?.path, "/repos/owner/site/git/refs")
    XCTAssertEqual(
      requests[2].url?.path, "/repos/owner/site/contents/content/posts/github-review.md")
    XCTAssertEqual(requests[2].url?.query, "ref=publish/github-review-20260829")
    XCTAssertEqual(requests[4].url?.path, "/repos/owner/site/pulls")
    XCTAssertTrue((requests[4].url?.query ?? "").contains("state=open"))
    XCTAssertTrue(
      (requests[4].url?.query ?? "").contains("head=owner:publish/github-review-20260829"))
    XCTAssertTrue((requests[4].url?.query ?? "").contains("base=main"))
    XCTAssertEqual(requests[5].url?.path, "/repos/owner/site/pulls")

    let putBody = try jsonBody(requests[3])
    XCTAssertEqual(putBody["branch"] as? String, "publish/github-review-20260829")
    XCTAssertEqual(putBody["sha"] as? String, "existing-file-sha")
  }

  func testGitHubReviewPublishReusesExistingPullRequestOnRetry() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"base-sha"}}"#),
      response(statusCode: 422, json: #"{"message":"Reference already exists"}"#),
      response(json: #"{"sha":"existing-file-sha"}"#),
      response(
        json:
          #"{"content":{"path":"content/posts/github-review.md"},"commit":{"sha":"retry-commit-sha"}}"#
      ),
      response(json: #"[{"html_url":"https://github.com/owner/site/pull/13"}]"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitHub Review",
      date: fixedDate(),
      slug: "github-review",
      draft: false,
      bodyMarkdown:
        "This body is intentionally long enough for GitHub existing pull request reuse behavior."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .reviewRequest,
      token: "secret-token"
    )

    XCTAssertEqual(result.provider, .github)
    XCTAssertEqual(result.mode, .reviewRequest)
    XCTAssertEqual(result.branchName, "publish/github-review-20260829")
    XCTAssertEqual(result.commitSHA, "retry-commit-sha")
    XCTAssertEqual(result.reviewURL, "https://github.com/owner/site/pull/13")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "PUT", "GET"])
    XCTAssertEqual(requests[4].url?.path, "/repos/owner/site/pulls")
    XCTAssertTrue((requests[4].url?.query ?? "").contains("state=open"))
    XCTAssertTrue(
      (requests[4].url?.query ?? "").contains("head=owner:publish/github-review-20260829"))
    XCTAssertTrue((requests[4].url?.query ?? "").contains("base=main"))
    XCTAssertFalse(
      requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/repos/owner/site/pulls" })
  }

  func testGitHubSingleFileNoOpExistingPullPersistsCurrentBranchHead() async throws {
    let body = "same remote review body"
    let sha = RemoteRepositoryPublishService().gitBlobSHA(for: Data(body.utf8))
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"target-sha"}}"#),
      response(statusCode: 422, json: #"{"message":"Reference already exists"}"#),
      response(json: "{\"sha\":\"\(sha)\"}"),
      response(json: #"[{"number":12,"html_url":"https://github.com/owner/site/pull/12"}]"#),
      response(json: #"{"object":{"sha":"existing-review-head"}}"#),
    ])
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    let package = PublishPackage(
      draftID: UUID(), title: "No-op", markdownPath: "content/posts/no-op.md",
      files: [
        PublishPackageFile(kind: .markdown, repositoryPath: "content/posts/no-op.md", content: body)
      ],
      commitMessage: "No-op", reviewBranchName: "publish/no-op", reviewTitle: "No-op",
      reviewChecklist: []
    )
    let result = try await RemoteRepositoryPublishService(transport: transport).publish(
      package: package, profile: profile, mode: .reviewRequest, token: "token"
    )
    XCTAssertEqual(result.reviewNumber, 12)
    XCTAssertEqual(result.commitSHA, "existing-review-head")
    XCTAssertEqual(result.changedPaths, [])
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "GET", "GET"])
    XCTAssertEqual(requests[3].url?.path, "/repos/owner/site/pulls")
    XCTAssertEqual(requests[4].url?.path, "/repos/owner/site/git/ref/heads/publish/no-op")
    XCTAssertFalse(requests.contains { $0.httpMethod == "PUT" })
  }

  func testGitHubReviewRetryCreatesPullRequestAfterPriorCommitWhenBranchAlreadyMatches()
    async throws
  {
    let body = "same remote review body after a partial publish"
    let blobSHA = RemoteRepositoryPublishService().gitBlobSHA(for: Data(body.utf8))
    let transport = SequencedRemoteRepositoryTransport(responses: [
      // First attempt: the branch commit succeeds, but PR creation fails.
      response(json: #"{"object":{"sha":"target-sha"}}"#),
      response(json: #"{"ref":"refs/heads/publish/retry-after-pr-failure","object":{"sha":"target-sha"}}"#),
      response(statusCode: 404, json: #"{"message":"not found"}"#),
      response(json: #"{"content":{"sha":"written-file-sha"},"commit":{"sha":"written-commit"}}"#),
      response(statusCode: 500, json: #"{"message":"pull request failed"}"#),
      // Retry: the branch now has the exact payload but no open PR yet.
      response(json: #"{"object":{"sha":"target-sha"}}"#),
      response(statusCode: 422, json: #"{"message":"Reference already exists"}"#),
      response(json: "{\"sha\":\"\(blobSHA)\"}"),
      response(json: #"[]"#),
      response(json: #"{"html_url":"https://github.com/owner/site/pull/44"}"#),
      response(json: #"{"object":{"sha":"written-commit"}}"#),
    ])
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    let package = PublishPackage(
      draftID: UUID(), title: "Retry", markdownPath: "content/posts/retry.md",
      files: [
        PublishPackageFile(kind: .markdown, repositoryPath: "content/posts/retry.md", content: body)
      ],
      commitMessage: "Retry", reviewBranchName: "publish/retry-after-pr-failure",
      reviewTitle: "Retry", reviewChecklist: []
    )
    let service = RemoteRepositoryPublishService(transport: transport)

    do {
      _ = try await service.publish(
        package: package, profile: profile, mode: .reviewRequest, token: "token"
      )
      XCTFail("Expected the first PR creation to be reported as a partial publish")
    } catch let error as RemoteRepositoryPublishError {
      guard case .partialPublish(_, _, _, _, let changedPaths, let commitSHA, _) = error else {
        XCTFail("Expected partialPublish, got \(error)")
        return
      }
      XCTAssertEqual(changedPaths, ["content/posts/retry.md"])
      XCTAssertEqual(commitSHA, "written-commit")
    }

    let result = try await service.publish(
      package: package, profile: profile, mode: .reviewRequest, token: "token"
    )

    XCTAssertEqual(result.changedPaths, [])
    XCTAssertEqual(result.commitSHA, "written-commit")
    XCTAssertEqual(result.reviewURL, "https://github.com/owner/site/pull/44")
    let requests = await transport.capturedRequests()
    XCTAssertEqual(
      requests.map(\.httpMethod),
      ["GET", "POST", "GET", "PUT", "POST", "GET", "POST", "GET", "GET", "POST", "GET"]
    )
    XCTAssertEqual(requests[8].url?.path, "/repos/owner/site/pulls")
    XCTAssertEqual(requests[9].url?.path, "/repos/owner/site/pulls")
    XCTAssertFalse(requests[5...].contains { $0.httpMethod == "PUT" })
  }

  func testReviewRecoveryDraftReusesRecordedBranchCommitAndBatchMetadata() throws {
    let profileID = UUID()
    let record = ReleaseRecord(
      kind: .remotePublishFailure,
      title: "批量线上 PR/MR 失败",
      summary: "PR 创建失败",
      siteProfileID: profileID,
      siteName: "Personal Site",
      changedPaths: ["content/posts/one.md", "content/posts/two.md"],
      repositoryProvider: .github,
      repoOwner: "owner",
      repoName: "site",
      branchName: "publish/batch-recovery",
      targetBranch: "main",
      commitSHA: "recorded-sha",
      batchItems: [
        ReleaseRecordBatchItem(
          draftID: UUID(),
          draftTitle: "One",
          markdownPath: "content/posts/one.md",
          changedPaths: ["content/posts/one.md"]
        ),
        ReleaseRecordBatchItem(
          draftID: UUID(),
          draftTitle: "Two",
          markdownPath: "content/posts/two.md",
          changedPaths: ["content/posts/two.md"]
        ),
      ]
    )

    let draft = try RemoteRepositoryReviewRecoveryDraft.make(record: record)

    XCTAssertEqual(draft.recordID, record.id)
    XCTAssertEqual(draft.branchName, "publish/batch-recovery")
    XCTAssertEqual(draft.targetBranch, "main")
    XCTAssertEqual(draft.recordedCommitSHA, "recorded-sha")
    XCTAssertEqual(draft.title, "Publish 2 articles")
    XCTAssertTrue(draft.body.contains("content/posts/one.md"))
    XCTAssertTrue(draft.body.contains("不重新上传文件"))
  }

  func testGitHubReviewRecoveryCreatesPullRequestWithoutUploadingFiles() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"remote-branch-sha"}}"#),
      response(json: #"[]"#),
      response(json: #"{"html_url":"https://github.com/owner/site/pull/21"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    let draft = RemoteRepositoryReviewRecoveryDraft(
      recordID: UUID(),
      branchName: "publish/batch-recovery",
      targetBranch: "main",
      title: "Publish 2 articles",
      body: "Recovered review body",
      changedPaths: ["content/posts/one.md", "content/posts/two.md"],
      recordedCommitSHA: "recorded-sha"
    )

    let result = try await service.resumeReview(
      draft: draft,
      profile: profile,
      token: "secret-token"
    )

    XCTAssertEqual(result.mode, .reviewRequest)
    XCTAssertEqual(result.branchName, "publish/batch-recovery")
    XCTAssertEqual(result.commitSHA, "remote-branch-sha")
    XCTAssertEqual(result.reviewURL, "https://github.com/owner/site/pull/21")
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST"])
    XCTAssertEqual(requests[0].url?.path, "/repos/owner/site/git/ref/heads/publish/batch-recovery")
    XCTAssertEqual(requests[1].url?.path, "/repos/owner/site/pulls")
    XCTAssertEqual(requests[2].url?.path, "/repos/owner/site/pulls")
    XCTAssertFalse(requests.contains { $0.url?.path.contains("/contents/") == true })
    XCTAssertFalse(requests.contains { $0.url?.path.contains("/git/blobs") == true })
    let pullBody = try jsonBody(requests[2])
    XCTAssertEqual(pullBody["head"] as? String, "publish/batch-recovery")
    XCTAssertEqual(pullBody["base"] as? String, "main")
  }

  func testGitHubReviewRecoveryExplainsMissingPullRequestWritePermission() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"remote-branch-sha"}}"#),
      response(json: #"[]"#),
      response(
        statusCode: 403,
        json: #"{"message":"Resource not accessible by personal access token"}"#
      ),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repoOwner = "owner"
    profile.repoName = "site"
    let draft = RemoteRepositoryReviewRecoveryDraft(
      recordID: UUID(),
      branchName: "publish/batch-recovery",
      targetBranch: "main",
      title: "Publish",
      body: "Body",
      changedPaths: ["content/posts/one.md"],
      recordedCommitSHA: "recorded-sha"
    )

    do {
      _ = try await service.resumeReview(draft: draft, profile: profile, token: "secret-token")
      XCTFail("Expected PR permission failure")
    } catch let error as RemoteRepositoryPublishError {
      guard case .reviewCreationPermissionDenied(provider: .github, _) = error else {
        XCTFail("Expected reviewCreationPermissionDenied, got \(error)")
        return
      }
      XCTAssertTrue(error.localizedDescription.contains("Pull requests: Read and write"))
      XCTAssertTrue(error.localizedDescription.contains("Resource not accessible"))
      XCTAssertFalse(error.localizedDescription.contains("请确认 Contents: Read and write"))
    }
  }

}
