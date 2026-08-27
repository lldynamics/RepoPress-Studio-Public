import CryptoKit
import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class RemoteRepositoryPublishServiceTests: XCTestCase {
  func testRemoteRepositoryAccessCheckBuildsGitHubEvidencePackageWithoutTokenLeak() {
    let check = RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/site",
      apiBaseURL: "https://api.github.com",
      defaultBranch: "main",
      canRead: true,
      canWrite: true,
      permissionSummary: "permissions.push=true",
      tokenScopeSummary: "repo, workflow",
      minimumWritePermission: "GitHub permissions.push=true 或 admin=true",
      message: "GitHub Token 可读取并写入 owner/site。"
    )

    let markdown = check.accessEvidenceMarkdown

    XCTAssertEqual(
      check.accessVerificationCommands,
      [
        "curl -fsS -H \"Authorization: Bearer $GITHUB_TOKEN\" 'https://api.github.com/repos/owner/site'"
      ]
    )
    XCTAssertTrue(markdown.contains(CoreL10n.format("# %@ Token 权限证据包", "GitHub")))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- 仓库：%@", "owner/site")))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- 可写入：%@", CoreL10n.text("是"))))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- Token scope：%@", "repo, workflow")))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- [%@] Token 满足内容写入所需权限", "x")))
    XCTAssertTrue(markdown.contains(CoreL10n.text("- [ ] PR 创建权限需在实际创建时验证")))
    XCTAssertTrue(markdown.contains("curl -fsS -H \"Authorization: Bearer $GITHUB_TOKEN\""))
    XCTAssertFalse(markdown.contains("secret-token"))
  }

  func testRemoteRepositoryAccessCheckBuildsGitLabEvidencePackageAndEncodesProjectPath() {
    let check = RemoteRepositoryAccessCheck(
      provider: .gitlab,
      repositoryName: "group/sub/site",
      apiBaseURL: "https://gitlab.example.com/api/v4",
      defaultBranch: "main",
      canRead: true,
      canWrite: false,
      permissionSummary: "access_level=20",
      tokenScopeSummary: "read_api",
      minimumWritePermission: "GitLab Developer 及以上或 api scope",
      message: "GitLab Token 可读但未确认写入。"
    )

    let markdown = check.accessEvidenceMarkdown

    XCTAssertEqual(
      check.accessVerificationCommands,
      [
        "curl -fsS --header \"PRIVATE-TOKEN: $GITLAB_TOKEN\" 'https://gitlab.example.com/api/v4/projects/group%2Fsub%2Fsite'"
      ]
    )
    XCTAssertTrue(markdown.contains(CoreL10n.format("# %@ Token 权限证据包", "GitLab")))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- 可写入：%@", CoreL10n.text("否"))))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- [%@] Token 满足内容写入所需权限", " ")))
    XCTAssertTrue(markdown.contains("GitLab Token 可读但未确认写入。"))
    XCTAssertFalse(markdown.contains("PRIVATE-TOKEN: secret"))
  }

  func testRemotePublishResultPresentationBuildsStableClipboardSummary() {
    let result = RemoteRepositoryPublishResult(
      provider: .gitlab,
      repositoryName: "group/site",
      apiBaseURL: "https://gitlab.example.com/api/v4",
      mode: .reviewRequest,
      branchName: "publish/post",
      targetBranch: "main",
      changedPaths: ["content/posts/post.md", "static/images/post.png"],
      commitSHA: "1234567890abcdef",
      reviewURL: "https://gitlab.com/group/site/-/merge_requests/5",
      reviewTitle: "Publish: Post"
    )

    XCTAssertEqual(result.shortCommitSHA, "12345678")
    XCTAssertEqual(result.displayTitle, "GitLab \(CoreL10n.text("线上 PR/MR"))")
    XCTAssertEqual(result.branchSummary, "publish/post -> main")
    XCTAssertTrue(result.clipboardSummary.contains(CoreL10n.format("仓库：%@", "group/site")))
    XCTAssertTrue(result.clipboardSummary.contains(CoreL10n.format("Commit：%@", "1234567890abcdef")))
    XCTAssertTrue(result.clipboardSummary.contains(CoreL10n.format("PR/MR：%@", "https://gitlab.com/group/site/-/merge_requests/5")))
    XCTAssertTrue(result.clipboardSummary.contains("- content/posts/post.md"))
    XCTAssertTrue(result.clipboardSummary.contains("- static/images/post.png"))

    let verification = result.remoteVerificationMarkdown
    XCTAssertTrue(verification.contains(CoreL10n.format("# %@ 线上发布实测包", "GitLab")))
    XCTAssertTrue(verification.contains("curl -fsS --header \"PRIVATE-TOKEN: $GITLAB_TOKEN\" 'https://gitlab.example.com/api/v4/projects/group%2Fsite/repository/commits/1234567890abcdef'"))
    XCTAssertTrue(verification.contains("curl -fsS --header \"PRIVATE-TOKEN: $GITLAB_TOKEN\" 'https://gitlab.example.com/api/v4/projects/group%2Fsite/merge_requests/5'"))
    XCTAssertTrue(verification.contains("repository/files/content%2Fposts%2Fpost.md?ref=publish%2Fpost"))
    XCTAssertTrue(verification.contains(CoreL10n.text("- [ ] 部署状态面板已刷新到最新记录。")))
  }

  func testRemotePublishResultDecodesLegacyPayloadWithoutRepositoryContext() throws {
    let data = """
    {
      "provider": "github",
      "mode": "directCommit",
      "branchName": "main",
      "targetBranch": "main",
      "changedPaths": ["content/posts/post.md"],
      "commitSHA": "abc123"
    }
    """.data(using: .utf8)!

    let result = try JSONDecoder().decode(RemoteRepositoryPublishResult.self, from: data)

    XCTAssertNil(result.repositoryName)
    XCTAssertNil(result.apiBaseURL)
    XCTAssertTrue(result.remoteVerificationCommands.isEmpty)
    XCTAssertTrue(
      result.remoteVerificationMarkdown.contains(
        CoreL10n.text("当前结果缺少仓库名或 commit，或 API 端点不符合 HTTPS 安全要求；未生成含 Token 的命令。")
      )
    )
  }

  func testAccessEvidenceRefusesCredentialCommandForInsecureDecodedBaseURL() {
    let check = RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/site",
      apiBaseURL: "http://api.example.com",
      defaultBranch: nil,
      canRead: true,
      canWrite: true,
      permissionSummary: "write=true",
      minimumWritePermission: "write",
      message: "checked"
    )

    XCTAssertTrue(check.accessVerificationCommands.isEmpty)
    XCTAssertTrue(
      check.accessEvidenceMarkdown.contains(
        CoreL10n.text("当前权限检查缺少仓库名，或 API 端点不符合 HTTPS 安全要求；未生成含 Token 的命令。")
      )
    )
  }

  func testRemoteVerificationRefusesCredentialCommandForInsecureDecodedBaseURL() {
    let result = RemoteRepositoryPublishResult(
      provider: .gitlab,
      repositoryName: "group/site",
      apiBaseURL: "http://gitlab.example/api/v4",
      mode: .directCommit,
      branchName: "main",
      targetBranch: "main",
      changedPaths: ["content/post.md"],
      commitSHA: "abc123"
    )

    XCTAssertTrue(result.remoteVerificationCommands.isEmpty)
    XCTAssertTrue(
      result.remoteVerificationMarkdown.contains(
        CoreL10n.text("当前结果缺少仓库名或 commit，或 API 端点不符合 HTTPS 安全要求；未生成含 Token 的命令。")
      )
    )
  }

  func testAccessEvidenceShellQuotesUserControlledURLComponents() throws {
    let check = RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/$(touch injected)'repo`id`",
      apiBaseURL: "https://api.example.com",
      defaultBranch: nil,
      canRead: true,
      canWrite: true,
      permissionSummary: "write=true",
      minimumWritePermission: "write",
      message: "checked"
    )

    let command = try XCTUnwrap(check.accessVerificationCommands.first)
    XCTAssertTrue(command.contains("'https://api.example.com/repos/"))
    XCTAssertTrue(command.contains("'\"'\"'"))
    XCTAssertFalse(command.contains("\"https://api.example.com"))
  }

  func testGitHubReviewPublishCreatesBranchWritesContentsAndPullRequest() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"base-sha"}}"#),
      response(json: #"{"ref":"refs/heads/publish/github-review-20260829","object":{"sha":"base-sha"}}"#),
      response(statusCode: 404, json: #"{"message":"not found"}"#),
      response(json: #"{"content":{"path":"content/posts/github-review.md"},"commit":{"sha":"commit-sha-1"}}"#),
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
    XCTAssertTrue(result.remoteVerificationMarkdown.contains("https://api.github.com/repos/owner/site/commits/commit-sha-1"))
    XCTAssertTrue(result.remoteVerificationMarkdown.contains("https://api.github.com/repos/owner/site/pulls/12"))
    XCTAssertTrue(result.remoteVerificationMarkdown.contains("contents/content/posts/github-review.md?ref=publish%2Fgithub-review-20260829"))

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "PUT", "POST"])
    XCTAssertEqual(requests[0].url?.path, "/repos/owner/site/git/ref/heads/main")
    XCTAssertEqual(requests[1].url?.path, "/repos/owner/site/git/refs")
    XCTAssertEqual(requests[2].url?.path, "/repos/owner/site/contents/content/posts/github-review.md")
    XCTAssertEqual(requests[3].url?.path, "/repos/owner/site/contents/content/posts/github-review.md")
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
      response(json: #"{"content":{"path":"content/posts/github-review.md"},"commit":{"sha":"retry-commit-sha"}}"#),
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
      bodyMarkdown: "This body is intentionally long enough for GitHub review publishing retry behavior."
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
    XCTAssertEqual(requests[2].url?.path, "/repos/owner/site/contents/content/posts/github-review.md")
    XCTAssertEqual(requests[2].url?.query, "ref=publish/github-review-20260829")
    XCTAssertEqual(requests[4].url?.path, "/repos/owner/site/pulls")
    XCTAssertTrue((requests[4].url?.query ?? "").contains("state=open"))
    XCTAssertTrue((requests[4].url?.query ?? "").contains("head=owner:publish/github-review-20260829"))
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
      response(json: #"{"content":{"path":"content/posts/github-review.md"},"commit":{"sha":"retry-commit-sha"}}"#),
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
      bodyMarkdown: "This body is intentionally long enough for GitHub existing pull request reuse behavior."
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
    XCTAssertTrue((requests[4].url?.query ?? "").contains("head=owner:publish/github-review-20260829"))
    XCTAssertTrue((requests[4].url?.query ?? "").contains("base=main"))
    XCTAssertFalse(requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/repos/owner/site/pulls" })
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

  func testGitHubDirectPublishUpdatesExistingContentOnTargetBranch() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"sha":"existing-file-sha"}"#),
      response(json: #"{"content":{"path":"content/posts/github-direct.md"},"commit":{"sha":"direct-commit-sha"}}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitHub Direct",
      date: fixedDate(),
      slug: "github-direct",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitHub direct publishing.",
      repositoryPath: "content/posts/github-direct.md"
    )
    draft.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: "content/posts/github-direct.md",
      remoteRevision: "existing-file-sha",
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .directCommit,
      token: "secret-token"
    )

    XCTAssertEqual(result.provider, .github)
    XCTAssertEqual(result.mode, .directCommit)
    XCTAssertEqual(result.branchName, "main")
    XCTAssertEqual(result.targetBranch, "main")
    XCTAssertEqual(result.changedPaths, ["content/posts/github-direct.md"])
    XCTAssertEqual(result.commitSHA, "direct-commit-sha")
    XCTAssertNil(result.reviewURL)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT"])
    XCTAssertEqual(requests[0].url?.path, "/repos/owner/site/contents/content/posts/github-direct.md")
    XCTAssertEqual(requests[0].url?.query, "ref=main")
    XCTAssertEqual(requests[1].url?.path, "/repos/owner/site/contents/content/posts/github-direct.md")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")

    let putBody = try jsonBody(requests[1])
    XCTAssertEqual(putBody["branch"] as? String, "main")
    XCTAssertEqual(putBody["message"] as? String, "Publish: GitHub Direct")
    XCTAssertEqual(putBody["sha"] as? String, "existing-file-sha")
    XCTAssertNotNil(putBody["content"] as? String)
  }

  func testGitHubDirectPublishMigratesPathWithVersionProtectedDelete() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"base-commit-sha"}}"#),
      response(json: #"{"sha":"base-commit-sha","tree":{"sha":"base-tree-sha"},"parents":[{"sha":"parent-sha"}]}"#),
      response(statusCode: 404, json: #"{"message":"not found"}"#),
      response(json: #"{"sha":"new-content-sha"}"#),
      response(json: #"{"sha":"old-content-sha"}"#),
      response(json: #"{"sha":"new-tree-sha"}"#),
      response(json: #"{"sha":"migration-commit-sha","tree":{"sha":"new-tree-sha"},"parents":[{"sha":"base-commit-sha"}]}"#),
      response(json: #"{"object":{"sha":"migration-commit-sha"}}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "New Path",
      date: fixedDate(),
      slug: "old-path",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitHub path migration coverage.",
      repositoryPath: "content/posts/old-path.md"
    )
    draft.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: "content/posts/old-path.md",
      remoteRevision: "old-content-sha",
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )
    draft.slug = "new-path"
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .directCommit,
      token: "secret-token"
    )

    XCTAssertEqual(result.changedPaths, ["content/posts/new-path.md", "content/posts/old-path.md"])
    XCTAssertEqual(result.commitSHA, "migration-commit-sha")
    XCTAssertEqual(result.remoteVersion(for: "content/posts/new-path.md"), "new-content-sha")
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "POST", "GET", "POST", "POST", "PATCH"])
    XCTAssertEqual(requests[5].url?.path, "/repos/owner/site/git/trees")
    XCTAssertEqual(requests[6].url?.path, "/repos/owner/site/git/commits")
    XCTAssertEqual(requests[7].url?.path, "/repos/owner/site/git/refs/heads/main")
    let treeBody = try jsonBody(requests[5])
    XCTAssertEqual(treeBody["base_tree"] as? String, "base-tree-sha")
    let entries = try XCTUnwrap(treeBody["tree"] as? [[String: Any]])
    XCTAssertEqual(entries.map { $0["path"] as? String }, ["content/posts/new-path.md", "content/posts/old-path.md"])
    XCTAssertTrue(entries[1]["sha"] is NSNull)
  }

  func testGitHubDirectDeleteTreatsMissingRemoteFileAsIdempotentSuccess() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(statusCode: 404, json: #"{"message":"not found"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = githubProfileForDeletion()
    let package = deletionPackage(
      path: "content/posts/already-gone.md",
      expectedRemoteSHA: "previous-sha"
    )

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .directCommit,
      token: "secret-token"
    )

    XCTAssertTrue(result.changedPaths.isEmpty)
    XCTAssertNil(result.commitSHA)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
  }

  func testGitHubDirectDeleteAdoptsMatchingLocalContentEvidenceWithoutRemoteSHA() async throws {
    let content = Data("published markdown".utf8)
    let hashingService = RemoteRepositoryPublishService()
    let remoteSHA = hashingService.gitBlobSHA(for: content)
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: "{\"sha\":\"\(remoteSHA)\"}"),
      response(json: #"{"content":null,"commit":{"sha":"delete-commit"}}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = githubProfileForDeletion()
    let package = deletionPackage(
      path: "content/posts/legacy-delete.md",
      expectedGitBlobSHA: remoteSHA
    )

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .directCommit,
      token: "secret-token"
    )

    XCTAssertEqual(result.changedPaths, ["content/posts/legacy-delete.md"])
    XCTAssertEqual(result.commitSHA, "delete-commit")
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "DELETE"])
  }

  func testGitHubDirectDeleteRejectsMismatchedLocalContentEvidenceWithoutRemoteSHA() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"sha":"remote-different-sha"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = githubProfileForDeletion()
    let package = deletionPackage(
      path: "content/posts/legacy-conflict.md",
      expectedGitBlobSHA: "local-blob-sha"
    )

    do {
      _ = try await service.publish(
        package: package,
        profile: profile,
        mode: .directCommit,
        token: "secret-token"
      )
      XCTFail("Expected untracked remote conflict")
    } catch let error as RemoteRepositoryPublishError {
      guard case .untrackedRemoteFile(let path, let actualSHA) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(path, "content/posts/legacy-conflict.md")
      XCTAssertEqual(actualSHA, "remote-different-sha")
    }
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
  }

  func testGitHubReviewDeleteRejectsTargetVersionDriftAndRemovesNewBranch() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"base-sha"}}"#),
      response(json: #"{"ref":"refs/heads/cleanup/article","object":{"sha":"base-sha"}}"#),
      response(json: #"{"sha":"expected-sha"}"#),
      response(json: #"{"sha":"new-target-sha"}"#),
      response(statusCode: 204, json: ""),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = githubProfileForDeletion()
    let package = deletionPackage(
      path: "content/posts/review-conflict.md",
      expectedRemoteSHA: "expected-sha"
    )

    do {
      _ = try await service.publish(
        package: package,
        profile: profile,
        mode: .reviewRequest,
        token: "secret-token"
      )
      XCTFail("Expected review delete to reject target drift")
    } catch let error as RemoteRepositoryPublishError {
      XCTAssertEqual(
        error,
        .remoteVersionConflict(
          path: "content/posts/review-conflict.md",
          expectedSHA: "expected-sha",
          actualSHA: "new-target-sha"
        )
      )
    }

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "GET", "DELETE"])
    XCTAssertEqual(
      requests.last?.url?.path,
      "/repos/owner/site/git/refs/heads/cleanup/article"
    )
  }

  func testGitHubReviewDeleteReportsPathAwaitingMerge() async throws {
    let path = "content/posts/review-delete.md"
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"base-sha"}}"#),
      response(json: #"{"ref":"refs/heads/cleanup/article","object":{"sha":"base-sha"}}"#),
      response(json: #"{"sha":"expected-sha"}"#),
      response(json: #"{"sha":"expected-sha"}"#),
      response(json: #"{"content":null,"commit":{"sha":"delete-commit"}}"#),
      response(json: #"{"html_url":"https://github.com/owner/site/pull/9"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = githubProfileForDeletion()
    let package = deletionPackage(path: path, expectedRemoteSHA: "expected-sha")

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .reviewRequest,
      token: "secret-token"
    )

    XCTAssertEqual(result.changedPaths, [path])
    XCTAssertEqual(result.reviewPendingPaths, [path])
    XCTAssertEqual(result.reviewURL, "https://github.com/owner/site/pull/9")
  }

  func testGitHubAtomicPublishReturnsNoOpWhenEveryBlobIsUnchanged() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"base-commit-sha"}}"#),
      response(json: #"{"sha":"base-commit-sha","tree":{"sha":"base-tree-sha"},"parents":[{"sha":"parent-sha"}]}"#),
      response(json: #"{"sha":"first-blob-sha"}"#),
      response(json: #"{"sha":"first-blob-sha"}"#),
      response(json: #"{"sha":"second-blob-sha"}"#),
      response(json: #"{"sha":"second-blob-sha"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    let package = PublishPackage(
      draftID: UUID(),
      title: "Unchanged Atomic Publish",
      markdownPath: "content/posts/first.md",
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: "content/posts/first.md",
          content: "first",
          expectedRemoteSHA: "first-blob-sha"
        ),
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: "content/posts/second.md",
          content: "second",
          expectedRemoteSHA: "second-blob-sha"
        ),
      ],
      commitMessage: "Publish unchanged files",
      reviewBranchName: "publish/unchanged",
      reviewTitle: "Unchanged",
      reviewChecklist: []
    )

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .directCommit,
      token: "secret-token"
    )

    XCTAssertTrue(result.changedPaths.isEmpty)
    XCTAssertNil(result.commitSHA)
    XCTAssertEqual(
      result.remoteVersionsByPath,
      [
        "content/posts/first.md": "first-blob-sha",
        "content/posts/second.md": "second-blob-sha",
      ]
    )
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "POST", "GET", "POST"])
    XCTAssertFalse(requests.contains { $0.httpMethod == "POST" && $0.url?.path.contains("/git/trees") == true })
    XCTAssertFalse(requests.contains { $0.httpMethod == "POST" && $0.url?.path.contains("/git/commits") == true })
    XCTAssertFalse(requests.contains { $0.httpMethod == "PATCH" })
  }

  func testGitHubAtomicPublishAutoAdoptsExistingIdenticalContentWithoutLocalSHA() async throws {
    let hashingService = RemoteRepositoryPublishService()
    let firstContent = Data("first identical body".utf8)
    let secondContent = Data("second identical body".utf8)
    let firstPath = "content/posts/first-identical.md"
    let secondPath = "content/posts/second-identical.md"
    let firstSHA = hashingService.gitBlobSHA(for: firstContent)
    let secondSHA = hashingService.gitBlobSHA(for: secondContent)
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"base-commit-sha"}}"#),
      response(json: #"{"sha":"base-commit-sha","tree":{"sha":"base-tree-sha"},"parents":[{"sha":"parent-sha"}]}"#),
      response(json: "{\"sha\":\"\(firstSHA)\"}"),
      response(json: "{\"sha\":\"\(secondSHA)\"}"),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    let package = PublishPackage(
      draftID: UUID(),
      title: "Already Published Atomic Publish",
      markdownPath: firstPath,
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: firstPath,
          content: String(decoding: firstContent, as: UTF8.self)
        ),
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: secondPath,
          content: String(decoding: secondContent, as: UTF8.self)
        ),
      ],
      commitMessage: "Publish already published files",
      reviewBranchName: "publish/already-published",
      reviewTitle: "Already published",
      reviewChecklist: []
    )

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .directCommit,
      token: "secret-token"
    )

    XCTAssertTrue(result.changedPaths.isEmpty)
    XCTAssertNil(result.commitSHA)
    XCTAssertEqual(result.automaticallyAdoptedPaths, [firstPath, secondPath])
    XCTAssertEqual(
      result.remoteVersionsByPath,
      [
        firstPath: firstSHA,
        secondPath: secondSHA,
      ]
    )
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "GET"])
    XCTAssertFalse(requests.contains { $0.url?.path.contains("/git/trees") == true })
    XCTAssertFalse(requests.contains { $0.httpMethod == "POST" && $0.url?.path.contains("/git/commits") == true })
    XCTAssertFalse(requests.contains { $0.httpMethod == "PATCH" })
  }

  func testGitHubDirectPreflightCollectsAllConflictsAndAdoptsIdenticalFilesWithoutWrites() async throws {
    let serviceForHashing = RemoteRepositoryPublishService()
    let adoptedContent = Data("adopted content".utf8)
    let adoptedSHA = serviceForHashing.gitBlobSHA(for: adoptedContent)
    let adoptedPath = "./content/posts/preflight-adopt.md"
    let untrackedPath = "content/posts/preflight-untracked.md"
    let versionConflictPath = "content/posts/preflight-version.md"
    let missingDeletePath = "content/posts/preflight-missing.md"
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: "{\"sha\":\"\(adoptedSHA)\"}"),
      response(json: #"{"sha":"remote-untracked"}"#),
      response(json: #"{"sha":"remote-version"}"#),
      response(statusCode: 404, json: #"{"message":"not found"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    let package = PublishPackage(
      draftID: UUID(),
      title: "GitHub Preflight",
      markdownPath: adoptedPath,
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: adoptedPath,
          content: String(decoding: adoptedContent, as: UTF8.self),
          expectedRemoteSHA: "stale-adoption-baseline"
        ),
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: untrackedPath,
          content: "local untracked content"
        ),
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: versionConflictPath,
          content: "local version content",
          expectedRemoteSHA: "expected-version"
        ),
        PublishPackageFile(
          kind: .markdown,
          operation: .delete,
          repositoryPath: missingDeletePath
        ),
      ],
      commitMessage: "Preflight",
      reviewBranchName: "publish/preflight",
      reviewTitle: "Preflight",
      reviewChecklist: []
    )

    let result = try await service.preflight(
      package: package,
      profile: profile,
      token: "github-token"
    )

    XCTAssertEqual(
      result.remoteVersionsByPath,
      ["content/posts/preflight-adopt.md": adoptedSHA]
    )
    XCTAssertEqual(result.automaticallyAdoptedPaths, ["content/posts/preflight-adopt.md"])
    XCTAssertFalse(result.isSafe)
    XCTAssertEqual(
      result.conflicts.map(\.path),
      [untrackedPath, versionConflictPath]
    )
    XCTAssertEqual(result.conflicts[0].kind, .untrackedRemoteFile)
    XCTAssertNil(result.conflicts[0].expectedSHA)
    XCTAssertEqual(result.conflicts[0].actualSHA, "remote-untracked")
    XCTAssertEqual(result.conflicts[1].kind, .remoteVersionConflict)
    XCTAssertEqual(result.conflicts[1].expectedSHA, "expected-version")
    XCTAssertEqual(result.conflicts[1].actualSHA, "remote-version")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "GET"])
    XCTAssertTrue(requests.allSatisfy { $0.httpBody == nil })
    XCTAssertEqual(
      requests.compactMap { percentEncodedPath($0.url) },
      [
        "/repos/owner/site/contents/content/posts/preflight-adopt.md",
        "/repos/owner/site/contents/content/posts/preflight-untracked.md",
        "/repos/owner/site/contents/content/posts/preflight-version.md",
        "/repos/owner/site/contents/content/posts/preflight-missing.md",
      ]
    )
  }

  func testPreflightRejectsNormalizedDuplicatePathsBeforeRemoteRead() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(statusCode: 500, json: #"{"message":"must not be requested"}"#)
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let package = duplicateNormalizedPathPackage()

    do {
      _ = try await service.preflight(
        package: package,
        profile: githubProfileForDeletion(),
        token: "secret-token"
      )
      XCTFail("Expected duplicate normalized path rejection")
    } catch let error as RemoteRepositoryPublishError {
      guard case .invalidRepositoryPath(let path, _) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(path, "content/posts/duplicate.md")
    }

    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testPublishRejectsNormalizedDuplicatePathsBeforeRemoteMutation() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(statusCode: 500, json: #"{"message":"must not be requested"}"#)
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let package = duplicateNormalizedPathPackage()

    do {
      _ = try await service.publish(
        package: package,
        profile: githubProfileForDeletion(),
        mode: .directCommit,
        token: "secret-token"
      )
      XCTFail("Expected duplicate normalized path rejection")
    } catch let error as RemoteRepositoryPublishError {
      guard case .invalidRepositoryPath(let path, _) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(path, "content/posts/duplicate.md")
    }

    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testGitHubAtomicPublishLeavesBranchUntouchedWhenTreeCreationFails() async throws {
    let imageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("github-partial-\(UUID().uuidString).png")
    try Data([1, 2, 3, 4]).write(to: imageURL)
    defer {
      try? FileManager.default.removeItem(at: imageURL)
    }

    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"base-commit-sha"}}"#),
      response(json: #"{"sha":"base-commit-sha","tree":{"sha":"base-tree-sha"},"parents":[{"sha":"parent-sha"}]}"#),
      response(statusCode: 404, json: #"{"message":"not found"}"#),
      response(json: #"{"sha":"markdown-blob-sha"}"#),
      response(statusCode: 404, json: #"{"message":"not found"}"#),
      response(json: #"{"sha":"image-blob-sha"}"#),
      response(statusCode: 500, json: #"{"message":"tree creation failed"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let attachment = DraftAttachment(
      originalFilename: "partial.png",
      relativePublishPath: "/images/partial.png",
      repositoryPath: "static/images/partial.png",
      sourceFilePath: imageURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitHub Partial",
      date: fixedDate(),
      slug: "github-partial",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitHub partial publish failure coverage.",
      attachments: [attachment]
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    do {
      _ = try await service.publish(
        package: package,
        profile: profile,
        mode: .directCommit,
        token: "secret-token"
      )
      XCTFail("Expected atomic publish failure")
    } catch let error as RemoteRepositoryPublishError {
      guard case .httpStatus(500, let body) = error else {
        XCTFail("Expected HTTP failure before ref update, got \(error)")
        return
      }
      XCTAssertTrue(body.contains("tree creation failed"))
    }

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "POST", "GET", "POST", "POST"])
    XCTAssertFalse(requests.contains { $0.httpMethod == "PATCH" })
    XCTAssertEqual(requests.last?.url?.path, "/repos/owner/site/git/trees")
  }

  func testGitHubDirectPublishStopsWhenExpectedRemoteSHAChanged() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"sha":"new-remote-sha"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitHub Conflict",
      date: fixedDate(),
      slug: "github-conflict",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitHub direct remote conflict coverage.",
      repositoryPath: "content/posts/github-conflict.md"
    )
    draft.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: "content/posts/github-conflict.md",
      remoteRevision: "old-remote-sha",
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    do {
      _ = try await service.publish(
        package: package,
        profile: profile,
        mode: .directCommit,
        token: "secret-token"
      )
      XCTFail("Expected remote version conflict")
    } catch let error as RemoteRepositoryPublishError {
      XCTAssertEqual(
        error,
        .remoteVersionConflict(
          path: "content/posts/github-conflict.md",
          expectedSHA: "old-remote-sha",
          actualSHA: "new-remote-sha"
        )
      )
      XCTAssertEqual(
        error.localizedDescription,
        CoreL10n.format(
          "远端版本冲突：%@ 的当前版本是 %@，本地草稿基于 %@。请先同步远端变更或改用 PR/MR。",
          "content/posts/github-conflict.md",
          "new-remote-sha",
          "old-remote-sha"
        )
      )
    }

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    XCTAssertEqual(requests[0].url?.path, "/repos/owner/site/contents/content/posts/github-conflict.md")
  }

  func testGitHubDirectPublishStopsWhenRemoteFileExistsWithoutLocalSHA() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"sha":"remote-only-sha"}"#),
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
      title: "GitHub Unknown Remote",
      date: fixedDate(),
      slug: "github-unknown-remote",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitHub unknown remote file conflict coverage."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    do {
      _ = try await service.publish(
        package: package,
        profile: profile,
        mode: .directCommit,
        token: "secret-token"
      )
      XCTFail("Expected untracked remote file conflict")
    } catch let error as RemoteRepositoryPublishError {
      XCTAssertEqual(
        error,
        .untrackedRemoteFile(path: "content/posts/github-unknown-remote.md", actualSHA: "remote-only-sha")
      )
      XCTAssertEqual(
        error.localizedDescription,
        CoreL10n.format(
          "远端同路径文件已存在：%@ 的当前版本是 %@，但本地草稿没有记录远端版本。请先同步远端变更或改用 PR/MR。",
          "content/posts/github-unknown-remote.md",
          "remote-only-sha"
        )
      )
    }

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    XCTAssertEqual(requests[0].url?.path, "/repos/owner/site/contents/content/posts/github-unknown-remote.md")
  }

  func testGitHubDirectPublishAutoAdoptsExistingIdenticalContentWithoutLocalSHA() async throws {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitHub Already Published",
      date: fixedDate(),
      slug: "github-already-published",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitHub identical content adoption coverage."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let hashingService = RemoteRepositoryPublishService()
    let content = try XCTUnwrap(package.markdownFile?.content)
    let remoteSHA = hashingService.gitBlobSHA(for: Data(content.utf8))
    let transport = SequencedRemoteRepositoryTransport(
      responses: [response(json: "{\"sha\":\"\(remoteSHA)\"}")]
    )
    let service = RemoteRepositoryPublishService(transport: transport)

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .directCommit,
      token: "secret-token"
    )

    XCTAssertTrue(result.changedPaths.isEmpty)
    XCTAssertNil(result.commitSHA)
    XCTAssertEqual(result.remoteVersion(for: package.markdownPath), remoteSHA)
    XCTAssertEqual(result.automaticallyAdoptedPaths, [package.markdownPath])
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
  }

  func testGitHubDirectPublishReturnsRemoteVersionWhenKnownSHAContentIsUnchanged() async throws {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitHub Known Baseline",
      date: fixedDate(),
      slug: "github-known-baseline",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitHub known baseline no-op coverage."
    )
    var package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let content = try XCTUnwrap(package.markdownFile?.content)
    let hashingService = RemoteRepositoryPublishService()
    let remoteSHA = hashingService.gitBlobSHA(for: Data(content.utf8))
    package.files[0].expectedRemoteSHA = remoteSHA
    let transport = SequencedRemoteRepositoryTransport(
      responses: [response(json: "{\"sha\":\"\(remoteSHA)\"}")]
    )
    let service = RemoteRepositoryPublishService(transport: transport)

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .directCommit,
      token: "secret-token"
    )

    XCTAssertTrue(result.changedPaths.isEmpty)
    XCTAssertNil(result.commitSHA)
    XCTAssertEqual(result.remoteVersion(for: package.markdownPath), remoteSHA)
    XCTAssertEqual(
      result.remoteVersionsByPath,
      [package.markdownPath: remoteSHA]
    )
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
  }

  func testGitLabDirectPublishMigratesPathInSingleCommit() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(statusCode: 404, json: #"{"message":"not found"}"#),
      response(json: #"{"file_path":"content/posts/old-path.md","last_commit_id":"old-commit-sha"}"#),
      response(json: #"{"id":"migration-commit-sha"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "New Path",
      date: fixedDate(),
      slug: "old-path",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitLab path migration coverage.",
      repositoryPath: "content/posts/old-path.md"
    )
    draft.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: "content/posts/old-path.md",
      remoteRevision: "old-commit-sha",
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )
    draft.slug = "new-path"
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .directCommit,
      token: "gitlab-token"
    )

    XCTAssertEqual(result.changedPaths, ["content/posts/new-path.md", "content/posts/old-path.md"])
    XCTAssertEqual(result.remoteVersion(for: "content/posts/new-path.md"), "migration-commit-sha")
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST"])
    let commitBody = try jsonBody(requests[2])
    let actions = try XCTUnwrap(commitBody["actions"] as? [[String: Any]])
    XCTAssertEqual(actions.map { $0["action"] as? String }, ["create", "delete"])
    XCTAssertEqual(actions[0]["file_path"] as? String, "content/posts/new-path.md")
    XCTAssertEqual(actions[1]["file_path"] as? String, "content/posts/old-path.md")
    XCTAssertEqual(actions[1]["last_commit_id"] as? String, "old-commit-sha")
    XCTAssertNil(actions[1]["content"])
  }

  func testGitLabDirectDeleteTreatsMissingRemoteFileAsIdempotentSuccess() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(statusCode: 404, json: #"{"message":"not found"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = gitLabProfileForDeletion()
    let package = deletionPackage(
      path: "content/posts/already-gone-gitlab.md",
      expectedRemoteSHA: "previous-commit"
    )

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .directCommit,
      token: "gitlab-token"
    )

    XCTAssertTrue(result.changedPaths.isEmpty)
    XCTAssertNil(result.commitSHA)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
  }

  func testGitLabDirectDeleteAdoptsMatchingLocalContentEvidenceWithoutRemoteCommitID() async throws {
    let content = Data("published markdown".utf8)
    let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"file_path":"content/posts/legacy-gitlab.md","last_commit_id":"remote-commit","content":"published markdown","encoding":"text"}"#),
      response(json: #"{"id":"delete-commit"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = gitLabProfileForDeletion()
    let package = deletionPackage(
      path: "content/posts/legacy-gitlab.md",
      expectedContentSHA256: digest
    )

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .directCommit,
      token: "gitlab-token"
    )

    XCTAssertEqual(result.changedPaths, ["content/posts/legacy-gitlab.md"])
    XCTAssertEqual(result.commitSHA, "delete-commit")
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
  }

  func testGitLabReviewDeleteRejectsTargetVersionDriftBeforeCreatingCommit() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(statusCode: 404, json: #"{"message":"not found"}"#),
      response(json: #"{"file_path":"content/posts/review-conflict.md","last_commit_id":"new-target-commit","content":"new content","encoding":"text"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = gitLabProfileForDeletion()
    let package = deletionPackage(
      path: "content/posts/review-conflict.md",
      expectedRemoteSHA: "expected-commit"
    )

    do {
      _ = try await service.publish(
        package: package,
        profile: profile,
        mode: .reviewRequest,
        token: "gitlab-token"
      )
      XCTFail("Expected review delete to reject target drift")
    } catch let error as RemoteRepositoryPublishError {
      XCTAssertEqual(
        error,
        .remoteVersionConflict(
          path: "content/posts/review-conflict.md",
          expectedSHA: "expected-commit",
          actualSHA: "new-target-commit"
        )
      )
    }

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
  }

  func testGitLabReviewPublishCreatesCommitActionsAndMergeRequest() async throws {
    let imageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("gitlab-image-\(UUID().uuidString).png")
    try Data([1, 2, 3, 4]).write(to: imageURL)
    defer {
      try? FileManager.default.removeItem(at: imageURL)
    }

    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(statusCode: 404, json: #"{"message":"not found"}"#),
      response(statusCode: 404, json: #"{"message":"not found"}"#),
      response(json: #"{"file_path":"static/images/2026/gitlab.png","last_commit_id":"image-base-commit"}"#),
      response(json: #"{"id":"gitlab-commit-sha"}"#),
      response(json: #"[]"#),
      response(json: #"{"web_url":"https://gitlab.com/group/site/-/merge_requests/5"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let attachment = DraftAttachment(
      originalFilename: "gitlab.png",
      relativePublishPath: "/images/2026/gitlab.png",
      repositoryPath: "static/images/2026/gitlab.png",
      sourceFilePath: imageURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitLab Review",
      date: fixedDate(),
      slug: "gitlab-review",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitLab review publishing.",
      attachments: [attachment]
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .reviewRequest,
      token: "gitlab-token"
    )

    XCTAssertEqual(result.provider, .gitlab)
    XCTAssertEqual(result.mode, .reviewRequest)
    XCTAssertEqual(result.branchName, "publish/gitlab-review-20260829")
    XCTAssertEqual(result.commitSHA, "gitlab-commit-sha")
    XCTAssertEqual(result.reviewURL, "https://gitlab.com/group/site/-/merge_requests/5")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "POST", "GET", "POST"])
    XCTAssertEqual(percentEncodedPath(requests[0].url), "/api/v4/projects/group%2Fsite/repository/branches/publish%2Fgitlab-review-20260829")
    XCTAssertEqual(percentEncodedPath(requests[1].url), "/api/v4/projects/group%2Fsite/repository/files/content%2Fposts%2Fgitlab-review.md")
    XCTAssertEqual(percentEncodedPath(requests[2].url), "/api/v4/projects/group%2Fsite/repository/files/static%2Fimages%2F2026%2Fgitlab.png")
    XCTAssertEqual(percentEncodedPath(requests[3].url), "/api/v4/projects/group%2Fsite/repository/commits")
    XCTAssertEqual(percentEncodedPath(requests[4].url), "/api/v4/projects/group%2Fsite/merge_requests")
    XCTAssertEqual(percentEncodedPath(requests[5].url), "/api/v4/projects/group%2Fsite/merge_requests")
    XCTAssertEqual(requests[3].value(forHTTPHeaderField: "PRIVATE-TOKEN"), "gitlab-token")
    XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/json" })

    let commitBody = try jsonBody(requests[3])
    XCTAssertEqual(commitBody["branch"] as? String, "publish/gitlab-review-20260829")
    XCTAssertEqual(commitBody["start_branch"] as? String, "main")
    let actions = try XCTUnwrap(commitBody["actions"] as? [[String: Any]])
    XCTAssertEqual(actions.count, 2)
    XCTAssertEqual(actions[0]["action"] as? String, "create")
    XCTAssertEqual(actions[0]["file_path"] as? String, "content/posts/gitlab-review.md")
    XCTAssertNil(actions[0]["encoding"])
    XCTAssertNil(actions[0]["last_commit_id"])
    XCTAssertEqual(actions[1]["action"] as? String, "update")
    XCTAssertEqual(actions[1]["file_path"] as? String, "static/images/2026/gitlab.png")
    XCTAssertEqual(actions[1]["encoding"] as? String, "base64")
    XCTAssertEqual(actions[1]["last_commit_id"] as? String, "image-base-commit")

    XCTAssertTrue((requests[4].url?.query ?? "").contains("state=opened"))
    XCTAssertTrue((requests[4].url?.query ?? "").contains("source_branch=publish/gitlab-review-20260829"))
    XCTAssertTrue((requests[4].url?.query ?? "").contains("target_branch=main"))

    let mergeRequestBody = try jsonBody(requests[5])
    XCTAssertEqual(mergeRequestBody["source_branch"] as? String, "publish/gitlab-review-20260829")
    XCTAssertEqual(mergeRequestBody["target_branch"] as? String, "main")
  }

  func testGitLabDirectPublishUpdatesExistingContentOnTargetBranch() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"file_path":"content/posts/gitlab-direct.md","last_commit_id":"existing-gitlab-commit"}"#),
      response(json: #"{"id":"direct-gitlab-commit"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitLab Direct",
      date: fixedDate(),
      slug: "gitlab-direct",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitLab direct publishing.",
      repositoryPath: "content/posts/gitlab-direct.md"
    )
    draft.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: "content/posts/gitlab-direct.md",
      remoteRevision: "existing-gitlab-commit",
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .directCommit,
      token: "gitlab-token"
    )

    XCTAssertEqual(result.provider, .gitlab)
    XCTAssertEqual(result.mode, .directCommit)
    XCTAssertEqual(result.branchName, "main")
    XCTAssertEqual(result.targetBranch, "main")
    XCTAssertEqual(result.changedPaths, ["content/posts/gitlab-direct.md"])
    XCTAssertEqual(result.commitSHA, "direct-gitlab-commit")
    XCTAssertNil(result.reviewURL)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    XCTAssertEqual(percentEncodedPath(requests[0].url), "/api/v4/projects/group%2Fsite/repository/files/content%2Fposts%2Fgitlab-direct.md")
    XCTAssertEqual(requests[0].url?.query, "ref=main")
    XCTAssertEqual(percentEncodedPath(requests[1].url), "/api/v4/projects/group%2Fsite/repository/commits")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "PRIVATE-TOKEN"), "gitlab-token")
    XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/json" })

    let commitBody = try jsonBody(requests[1])
    XCTAssertEqual(commitBody["branch"] as? String, "main")
    XCTAssertNil(commitBody["start_branch"])
    let actions = try XCTUnwrap(commitBody["actions"] as? [[String: Any]])
    XCTAssertEqual(actions.count, 1)
    XCTAssertEqual(actions[0]["action"] as? String, "update")
    XCTAssertEqual(actions[0]["file_path"] as? String, "content/posts/gitlab-direct.md")
    XCTAssertEqual(actions[0]["last_commit_id"] as? String, "existing-gitlab-commit")
  }

  func testGitLabDirectPublishReturnsNoOpWhenRemoteContentIsUnchanged() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(
        json: #"{"file_path":"content/posts/unchanged.md","last_commit_id":"existing-gitlab-commit","content":"c2FtZSBjb250ZW50","encoding":"base64"}"#
      ),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    let package = PublishPackage(
      draftID: UUID(),
      title: "GitLab No-op",
      markdownPath: "content/posts/unchanged.md",
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: "content/posts/unchanged.md",
          content: "same content",
          expectedRemoteSHA: "existing-gitlab-commit"
        )
      ],
      commitMessage: "No-op",
      reviewBranchName: "publish/no-op",
      reviewTitle: "No-op",
      reviewChecklist: []
    )

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .directCommit,
      token: "gitlab-token"
    )

    XCTAssertTrue(result.changedPaths.isEmpty)
    XCTAssertNil(result.commitSHA)
    XCTAssertEqual(
      result.remoteVersionsByPath,
      ["content/posts/unchanged.md": "existing-gitlab-commit"]
    )
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
  }

  func testGitLabDirectPublishStopsWhenLastCommitIDChanged() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"file_path":"content/posts/gitlab-conflict.md","last_commit_id":"new-gitlab-commit"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitLab Conflict",
      date: fixedDate(),
      slug: "gitlab-conflict",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitLab direct remote conflict coverage.",
      repositoryPath: "content/posts/gitlab-conflict.md"
    )
    draft.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: "content/posts/gitlab-conflict.md",
      remoteRevision: "old-gitlab-commit",
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    do {
      _ = try await service.publish(
        package: package,
        profile: profile,
        mode: .directCommit,
        token: "gitlab-token"
      )
      XCTFail("Expected remote version conflict")
    } catch let error as RemoteRepositoryPublishError {
      XCTAssertEqual(
        error,
        .remoteVersionConflict(
          path: "content/posts/gitlab-conflict.md",
          expectedSHA: "old-gitlab-commit",
          actualSHA: "new-gitlab-commit"
        )
      )
      XCTAssertEqual(
        error.localizedDescription,
        CoreL10n.format(
          "远端版本冲突：%@ 的当前版本是 %@，本地草稿基于 %@。请先同步远端变更或改用 PR/MR。",
          "content/posts/gitlab-conflict.md",
          "new-gitlab-commit",
          "old-gitlab-commit"
        )
      )
    }

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    XCTAssertEqual(percentEncodedPath(requests[0].url), "/api/v4/projects/group%2Fsite/repository/files/content%2Fposts%2Fgitlab-conflict.md")
  }

  func testGitLabDirectPublishStopsWhenRemoteFileExistsWithoutLocalCommitID() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"file_path":"content/posts/gitlab-unknown-remote.md","last_commit_id":"remote-only-gitlab-commit"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitLab Unknown Remote",
      date: fixedDate(),
      slug: "gitlab-unknown-remote",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitLab unknown remote file conflict coverage."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    do {
      _ = try await service.publish(
        package: package,
        profile: profile,
        mode: .directCommit,
        token: "gitlab-token"
      )
      XCTFail("Expected untracked remote file conflict")
    } catch let error as RemoteRepositoryPublishError {
      XCTAssertEqual(
        error,
        .untrackedRemoteFile(
          path: "content/posts/gitlab-unknown-remote.md",
          actualSHA: "remote-only-gitlab-commit"
        )
      )
      XCTAssertEqual(
        error.localizedDescription,
        CoreL10n.format(
          "远端同路径文件已存在：%@ 的当前版本是 %@，但本地草稿没有记录远端版本。请先同步远端变更或改用 PR/MR。",
          "content/posts/gitlab-unknown-remote.md",
          "remote-only-gitlab-commit"
        )
      )
    }

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    XCTAssertEqual(percentEncodedPath(requests[0].url), "/api/v4/projects/group%2Fsite/repository/files/content%2Fposts%2Fgitlab-unknown-remote.md")
  }

  func testGitLabDirectPublishAutoAdoptsExistingIdenticalContentWithoutLocalCommitID() async throws {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitLab Already Published",
      date: fixedDate(),
      slug: "gitlab-already-published",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitLab identical content adoption coverage."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let content = try XCTUnwrap(package.markdownFile?.content)
    let jsonData = try JSONSerialization.data(
      withJSONObject: [
        "file_path": package.markdownPath,
        "last_commit_id": "existing-gitlab-commit",
        "content": content,
        "encoding": "text",
      ]
    )
    let transport = SequencedRemoteRepositoryTransport(
      responses: [response(json: String(decoding: jsonData, as: UTF8.self))]
    )
    let service = RemoteRepositoryPublishService(transport: transport)

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .directCommit,
      token: "gitlab-token"
    )

    XCTAssertTrue(result.changedPaths.isEmpty)
    XCTAssertNil(result.commitSHA)
    XCTAssertEqual(result.remoteVersion(for: package.markdownPath), "existing-gitlab-commit")
    XCTAssertEqual(result.automaticallyAdoptedPaths, [package.markdownPath])
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
  }

  func testGitLabDirectPreflightCollectsAllConflictsAndAdoptsIdenticalFilesWithoutWrites() async throws {
    let adoptedPath = "./content/posts/gitlab-preflight-adopt.md"
    let untrackedPath = "content/posts/gitlab-preflight-untracked.md"
    let versionConflictPath = "content/posts/gitlab-preflight-version.md"
    let missingDeletePath = "content/posts/gitlab-preflight-missing.md"
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"file_path":"content/posts/gitlab-preflight-adopt.md","last_commit_id":"adopt-commit","content":"adopted content","encoding":"text"}"#),
      response(json: #"{"file_path":"content/posts/gitlab-preflight-untracked.md","last_commit_id":"remote-untracked","content":"remote untracked","encoding":"text"}"#),
      response(json: #"{"file_path":"content/posts/gitlab-preflight-version.md","last_commit_id":"remote-version","content":"remote version","encoding":"text"}"#),
      response(statusCode: 404, json: #"{"message":"not found"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    let package = PublishPackage(
      draftID: UUID(),
      title: "GitLab Preflight",
      markdownPath: adoptedPath,
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: adoptedPath,
          content: "adopted content",
          expectedRemoteSHA: "stale-adoption-baseline"
        ),
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: untrackedPath,
          content: "local untracked content"
        ),
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: versionConflictPath,
          content: "local version content",
          expectedRemoteSHA: "expected-version"
        ),
        PublishPackageFile(
          kind: .markdown,
          operation: .delete,
          repositoryPath: missingDeletePath
        ),
      ],
      commitMessage: "Preflight",
      reviewBranchName: "publish/preflight",
      reviewTitle: "Preflight",
      reviewChecklist: []
    )

    let result = try await service.preflight(
      package: package,
      profile: profile,
      token: "gitlab-token"
    )

    XCTAssertEqual(
      result.remoteVersionsByPath,
      ["content/posts/gitlab-preflight-adopt.md": "adopt-commit"]
    )
    XCTAssertEqual(result.automaticallyAdoptedPaths, ["content/posts/gitlab-preflight-adopt.md"])
    XCTAssertFalse(result.isSafe)
    XCTAssertEqual(
      result.conflicts.map(\.path),
      [untrackedPath, versionConflictPath]
    )
    XCTAssertEqual(result.conflicts[0].kind, .untrackedRemoteFile)
    XCTAssertNil(result.conflicts[0].expectedSHA)
    XCTAssertEqual(result.conflicts[0].actualSHA, "remote-untracked")
    XCTAssertEqual(result.conflicts[1].kind, .remoteVersionConflict)
    XCTAssertEqual(result.conflicts[1].expectedSHA, "expected-version")
    XCTAssertEqual(result.conflicts[1].actualSHA, "remote-version")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "GET"])
    XCTAssertTrue(requests.allSatisfy { $0.httpBody == nil })
    XCTAssertEqual(
      requests.compactMap { percentEncodedPath($0.url) },
      [
        "/api/v4/projects/group%2Fsite/repository/files/content%2Fposts%2Fgitlab-preflight-adopt.md",
        "/api/v4/projects/group%2Fsite/repository/files/content%2Fposts%2Fgitlab-preflight-untracked.md",
        "/api/v4/projects/group%2Fsite/repository/files/content%2Fposts%2Fgitlab-preflight-version.md",
        "/api/v4/projects/group%2Fsite/repository/files/content%2Fposts%2Fgitlab-preflight-missing.md",
      ]
    )
  }

  func testGitLabReviewPublishUpdatesExistingReviewBranchOnRetry() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"name":"publish/gitlab-review-20260829"}"#),
      response(json: #"{"file_path":"content/posts/gitlab-review.md","last_commit_id":"markdown-base-commit"}"#),
      response(json: #"{"id":"gitlab-retry-commit-sha"}"#),
      response(json: #"[{"web_url":"https://gitlab.com/group/site/-/merge_requests/6"}]"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitLab Review",
      date: fixedDate(),
      slug: "gitlab-review",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitLab review publishing retry behavior."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .reviewRequest,
      token: "gitlab-token"
    )

    XCTAssertEqual(result.provider, .gitlab)
    XCTAssertEqual(result.mode, .reviewRequest)
    XCTAssertEqual(result.branchName, "publish/gitlab-review-20260829")
    XCTAssertEqual(result.commitSHA, "gitlab-retry-commit-sha")
    XCTAssertEqual(result.reviewURL, "https://gitlab.com/group/site/-/merge_requests/6")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST", "GET"])
    XCTAssertEqual(percentEncodedPath(requests[0].url), "/api/v4/projects/group%2Fsite/repository/branches/publish%2Fgitlab-review-20260829")
    XCTAssertEqual(percentEncodedPath(requests[1].url), "/api/v4/projects/group%2Fsite/repository/files/content%2Fposts%2Fgitlab-review.md")
    XCTAssertEqual(requests[1].url?.query, "ref=publish/gitlab-review-20260829")

    let commitBody = try jsonBody(requests[2])
    XCTAssertEqual(commitBody["branch"] as? String, "publish/gitlab-review-20260829")
    XCTAssertNil(commitBody["start_branch"])
    let actions = try XCTUnwrap(commitBody["actions"] as? [[String: Any]])
    XCTAssertEqual(actions.count, 1)
    XCTAssertEqual(actions[0]["action"] as? String, "update")
    XCTAssertEqual(actions[0]["file_path"] as? String, "content/posts/gitlab-review.md")
    XCTAssertEqual(actions[0]["last_commit_id"] as? String, "markdown-base-commit")

    XCTAssertEqual(percentEncodedPath(requests[3].url), "/api/v4/projects/group%2Fsite/merge_requests")
    XCTAssertTrue((requests[3].url?.query ?? "").contains("state=opened"))
    XCTAssertTrue((requests[3].url?.query ?? "").contains("source_branch=publish/gitlab-review-20260829"))
    XCTAssertTrue((requests[3].url?.query ?? "").contains("target_branch=main"))
  }

  func testGitLabReviewPublishReportsPartialFailureWhenMergeRequestCreationFails() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(statusCode: 404, json: #"{"message":"not found"}"#),
      response(statusCode: 404, json: #"{"message":"not found"}"#),
      response(json: #"{"id":"gitlab-review-commit-sha"}"#),
      response(json: #"[]"#),
      response(statusCode: 500, json: #"{"message":"merge request failed"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "GitLab Review Failure",
      date: fixedDate(),
      slug: "gitlab-review-failure",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for GitLab review partial failure coverage."
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    do {
      _ = try await service.publish(
        package: package,
        profile: profile,
        mode: .reviewRequest,
        token: "gitlab-token"
      )
      XCTFail("Expected partial publish failure")
    } catch let error as RemoteRepositoryPublishError {
      guard case let .partialPublish(provider, mode, branchName, targetBranch, changedPaths, commitSHA, underlyingMessage) = error else {
        XCTFail("Expected partialPublish, got \(error)")
        return
      }
      XCTAssertEqual(provider, .gitlab)
      XCTAssertEqual(mode, .reviewRequest)
      XCTAssertEqual(branchName, "publish/gitlab-review-failure-20260829")
      XCTAssertEqual(targetBranch, "main")
      XCTAssertEqual(changedPaths, ["content/posts/gitlab-review-failure.md"])
      XCTAssertEqual(commitSHA, "gitlab-review-commit-sha")
      XCTAssertTrue(underlyingMessage.contains("HTTP 500"))
      XCTAssertTrue(error.localizedDescription.contains("publish/gitlab-review-failure-20260829"))
      XCTAssertTrue(error.localizedDescription.contains(String("gitlab-review-commit-sha".prefix(8))))
    }

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST", "GET", "POST"])
    XCTAssertEqual(percentEncodedPath(requests[2].url), "/api/v4/projects/group%2Fsite/repository/commits")
    XCTAssertEqual(percentEncodedPath(requests[4].url), "/api/v4/projects/group%2Fsite/merge_requests")
  }

  func testAccessCheckReportsWritableGitHubRepository() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(
        json: #"{"full_name":"owner/site","default_branch":"main","permissions":{"push":true,"maintain":false,"admin":false}}"#,
        headers: [
          "X-OAuth-Scopes": "repo, workflow",
          "X-Accepted-OAuth-Scopes": "repo",
        ]
      ),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repoOwner = "owner"
    profile.repoName = "site"

    let check = try await service.checkAccess(profile: profile, token: "token")

    XCTAssertEqual(check.provider, .github)
    XCTAssertEqual(check.repositoryName, "owner/site")
    XCTAssertEqual(check.apiBaseURL, "https://api.github.com")
    XCTAssertEqual(check.defaultBranch, "main")
    XCTAssertTrue(check.canRead)
    XCTAssertTrue(check.canWrite)
    XCTAssertEqual(
      check.permissionSummary,
      CoreL10n.format(
        "GitHub repository permissions: push=%@, maintain=%@, admin=%@; active=%@.",
        "true",
        "false",
        "false",
        "push"
      )
    )
    XCTAssertEqual(
      check.tokenScopeSummary,
      CoreL10n.format("GitHub OAuth scopes: %@; accepted: %@.", "repo, workflow", "repo")
    )
    XCTAssertTrue(check.minimumWritePermission.contains("Contents: Read and write"))
    XCTAssertTrue(check.minimumWritePermission.contains("Pull requests: Read and write"))
    XCTAssertTrue(check.message.contains("PR 创建权限需在实际创建时验证"))
  }

  func testAccessCheckReportsNormalizedGitLabAPIBaseURL() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"path_with_namespace":"group/site","default_branch":"main","permissions":{"project_access":{"access_level":30}}}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"

    let check = try await service.checkAccess(profile: profile, token: "token")

    XCTAssertEqual(check.provider, .gitlab)
    XCTAssertEqual(check.repositoryName, "group/site")
    XCTAssertEqual(check.apiBaseURL, "https://gitlab.com/api/v4")
    XCTAssertEqual(check.defaultBranch, "main")
    XCTAssertTrue(check.canRead)
    XCTAssertTrue(check.canWrite)
    XCTAssertEqual(
      check.permissionSummary,
      CoreL10n.format(
        "GitLab access level: project=%@ (%@), group=%@ (%@), effective=%@ (%@).",
        "30",
        "Developer",
        "0",
        "No access",
        "30",
        "Developer"
      )
    )
    XCTAssertNil(check.tokenScopeSummary)
    XCTAssertTrue(check.minimumWritePermission.contains("Developer(30)"))
  }

  func testAccessCheckRejectsHTTPBaseURLBeforeSendingGitHubToken() async {
    let transport = SequencedRemoteRepositoryTransport(responses: [])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "http://api.github.example"
    profile.repoOwner = "owner"
    profile.repoName = "site"

    do {
      _ = try await service.checkAccess(profile: profile, token: "secret-token")
      XCTFail("Expected an insecure base URL error")
    } catch {
      XCTAssertEqual(
        error as? RemoteRepositoryPublishError,
        .insecureBaseURL
      )
      XCTAssertTrue(error.localizedDescription.contains("HTTPS"))
    }

    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testAccessCheckRejectsHTTPBaseURLBeforeSendingGitLabToken() async {
    let transport = SequencedRemoteRepositoryTransport(responses: [])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "http://gitlab.example"
    profile.repoOwner = "group"
    profile.repoName = "site"

    do {
      _ = try await service.checkAccess(profile: profile, token: "secret-token")
      XCTFail("Expected an insecure base URL error")
    } catch {
      XCTAssertEqual(
        error as? RemoteRepositoryPublishError,
        .insecureBaseURL
      )
      XCTAssertTrue(error.localizedDescription.contains("发送 Token"))
    }

    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testAccessCheckRejectsCredentialedQueryAndFragmentBaseURLs() async {
    let transport = SequencedRemoteRepositoryTransport(responses: [])
    let service = RemoteRepositoryPublishService(transport: transport)
    let insecureURLs = [
      "https://user:password@api.example.com",
      "https://api.example.com?redirect=https://other.example",
      "https://api.example.com#fragment",
    ]

    for baseURL in insecureURLs {
      var profile = SiteProfile.defaultProfile
      profile.repositoryBaseURL = baseURL
      profile.repoOwner = "owner"
      profile.repoName = "site"
      do {
        _ = try await service.checkAccess(profile: profile, token: "secret-token")
        XCTFail("Expected insecure base URL rejection")
      } catch {
        XCTAssertEqual(error as? RemoteRepositoryPublishError, .insecureBaseURL)
        XCTAssertFalse(error.localizedDescription.contains("password"))
      }
    }

    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testAccessCheckDecodesLegacyPayloadWithoutPermissionDiagnostics() throws {
    let data = """
    {
      "provider": "github",
      "repositoryName": "owner/site",
      "apiBaseURL": "https://api.github.com",
      "defaultBranch": "main",
      "canRead": true,
      "canWrite": false,
      "message": "GitHub Token 可读取仓库，但未确认写入权限。"
    }
    """.data(using: .utf8)!

    let check = try JSONDecoder().decode(RemoteRepositoryAccessCheck.self, from: data)

    XCTAssertEqual(check.repositoryName, "owner/site")
    XCTAssertFalse(check.canWrite)
    XCTAssertEqual(check.permissionSummary, CoreL10n.text("未确认写入权限。"))
    XCTAssertEqual(check.minimumWritePermission, CoreL10n.text("需要仓库写入权限。"))
    XCTAssertNil(check.tokenScopeSummary)
    XCTAssertNil(check.checkedAt)
    XCTAssertFalse(check.isFresh())
  }

  func testRemoteAPIHTTPErrorDescriptionsIncludeActionableTokenAndPermissionGuidance() async throws {
    let githubTransport = SequencedRemoteRepositoryTransport(responses: [
      response(
        statusCode: 403,
        json: #"{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com/rest"}"#
      ),
    ])
    let githubService = RemoteRepositoryPublishService(transport: githubTransport)
    var githubProfile = SiteProfile.defaultProfile
    githubProfile.repositoryProvider = .github
    githubProfile.repoOwner = "owner"
    githubProfile.repoName = "site"

    do {
      _ = try await githubService.checkAccess(profile: githubProfile, token: "github-token")
      XCTFail("Expected GitHub permission failure")
    } catch {
      let message = error.localizedDescription
      XCTAssertTrue(message.contains("HTTP 403"))
      XCTAssertTrue(message.contains("Contents: Read and write"))
      XCTAssertTrue(message.contains("Resource not accessible by personal access token"))
      XCTAssertTrue(message.contains("https://docs.github.com/rest"))
    }

    let gitLabTransport = SequencedRemoteRepositoryTransport(responses: [
      response(statusCode: 401, json: #"{"message":"401 Unauthorized"}"#),
    ])
    let gitLabService = RemoteRepositoryPublishService(transport: gitLabTransport)
    var gitLabProfile = SiteProfile.defaultProfile
    gitLabProfile.repositoryProvider = .gitlab
    gitLabProfile.repositoryBaseURL = "https://gitlab.com"
    gitLabProfile.repoOwner = "group"
    gitLabProfile.repoName = "site"

    do {
      _ = try await gitLabService.checkAccess(profile: gitLabProfile, token: "gitlab-token")
      XCTFail("Expected GitLab token failure")
    } catch {
      let message = error.localizedDescription
      XCTAssertTrue(message.contains("HTTP 401"))
      XCTAssertTrue(message.contains("GitHub/GitLab"))
      XCTAssertTrue(message.contains("401 Unauthorized"))
    }
  }

  func testRemoteAPIHTTPErrorBodyIsBoundedAndRedactsRequestToken() async {
    let token = "github-super-secret-token-123456789"
    let body = #"{"message":"Bearer \#(token)","token":"\#(token)","detail":""#
      + String(repeating: "x", count: 4_000)
      + #""}"#
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(statusCode: 500, json: body),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repoOwner = "owner"
    profile.repoName = "site"

    do {
      _ = try await service.checkAccess(profile: profile, token: token)
      XCTFail("Expected sanitized remote API failure")
    } catch let error as RemoteRepositoryPublishError {
      guard case .httpStatus(500, let sanitizedBody) = error else {
        XCTFail("Expected HTTP failure, got \(error)")
        return
      }
      XCTAssertFalse(sanitizedBody.contains(token))
      XCTAssertTrue(sanitizedBody.contains("[REDACTED]"))
      XCTAssertTrue(sanitizedBody.contains("远端响应已截断"))
      XCTAssertLessThan(sanitizedBody.count, 2_100)
    } catch {
      XCTFail("Expected RemoteRepositoryPublishError, got \(error)")
    }
  }

  func testCreatesGitHubUserRepositoryWhenOwnerMatchesTokenUser() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"login":"owner"}"#),
      response(json: #"{"full_name":"owner/site","default_branch":"main","ssh_url":"git@github.com:owner/site.git","clone_url":"https://github.com/owner/site.git","html_url":"https://github.com/owner/site","private":false}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.name = "Personal Site"

    let result = try await service.createRepository(
      profile: profile,
      token: "github-token",
      privateRepository: false
    )

    XCTAssertEqual(result.provider, .github)
    XCTAssertEqual(result.repositoryName, "owner/site")
    XCTAssertEqual(result.defaultBranch, "main")
    XCTAssertEqual(result.sshURL, "git@github.com:owner/site.git")
    XCTAssertEqual(result.htmlURL, "https://github.com/owner/site")
    XCTAssertFalse(result.privateRepository)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    XCTAssertEqual(requests[0].url?.path, "/user")
    XCTAssertEqual(requests[1].url?.path, "/user/repos")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer github-token")

    let body = try jsonBody(requests[1])
    XCTAssertEqual(body["name"] as? String, "site")
    XCTAssertEqual(body["description"] as? String, "Personal Site")
    XCTAssertEqual(body["private"] as? Bool, false)
    XCTAssertEqual(body["auto_init"] as? Bool, false)
  }

  func testCreatesGitHubOrganizationRepositoryAsPrivateByDefault() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"login":"me"}"#),
      response(json: #"{"full_name":"org/site","ssh_url":"git@github.com:org/site.git","clone_url":"https://github.com/org/site.git","html_url":"https://github.com/org/site","private":true}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repoOwner = "org"
    profile.repoName = "site"

    let result = try await service.createRepository(
      profile: profile,
      token: "github-token"
    )

    XCTAssertEqual(result.repositoryName, "org/site")
    XCTAssertEqual(result.sshURL, "git@github.com:org/site.git")
    XCTAssertTrue(result.privateRepository)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    XCTAssertEqual(requests[0].url?.path, "/user")
    XCTAssertEqual(requests[1].url?.path, "/orgs/org/repos")
    let body = try jsonBody(requests[1])
    XCTAssertEqual(body["name"] as? String, "site")
    XCTAssertEqual(body["private"] as? Bool, true)
  }

  func testCreatesGitLabGroupProject() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"id":42,"full_path":"group/subgroup"}"#),
      response(json: #"{"path_with_namespace":"group/subgroup/site","default_branch":"main","ssh_url_to_repo":"git@gitlab.com:group/subgroup/site.git","http_url_to_repo":"https://gitlab.com/group/subgroup/site.git","web_url":"https://gitlab.com/group/subgroup/site","visibility":"private"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group/subgroup"
    profile.repoName = "site"
    profile.name = "Personal Site"

    let result = try await service.createRepository(
      profile: profile,
      token: "gitlab-token",
      privateRepository: true
    )

    XCTAssertEqual(result.provider, .gitlab)
    XCTAssertEqual(result.repositoryName, "group/subgroup/site")
    XCTAssertEqual(result.defaultBranch, "main")
    XCTAssertEqual(result.sshURL, "git@gitlab.com:group/subgroup/site.git")
    XCTAssertEqual(result.cloneURL, "https://gitlab.com/group/subgroup/site.git")
    XCTAssertEqual(result.htmlURL, "https://gitlab.com/group/subgroup/site")
    XCTAssertTrue(result.privateRepository)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    XCTAssertEqual(percentEncodedPath(requests[0].url), "/api/v4/groups/group%2Fsubgroup")
    XCTAssertEqual(percentEncodedPath(requests[1].url), "/api/v4/projects")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "PRIVATE-TOKEN"), "gitlab-token")

    let body = try jsonBody(requests[1])
    XCTAssertEqual(body["name"] as? String, "site")
    XCTAssertEqual(body["path"] as? String, "site")
    XCTAssertEqual(body["description"] as? String, "Personal Site")
    XCTAssertEqual(body["visibility"] as? String, "private")
    XCTAssertEqual(body["namespace_id"] as? Int, 42)
    XCTAssertEqual(body["initialize_with_readme"] as? Bool, false)
  }

  func testCreateRepositoryRequiresRepositoryName() async throws {
    let service = RemoteRepositoryPublishService(
      transport: SequencedRemoteRepositoryTransport(responses: [])
    )
    var profile = SiteProfile.defaultProfile
    profile.repoOwner = "owner"
    profile.repoName = " "

    do {
      _ = try await service.createRepository(profile: profile, token: "github-token")
      XCTFail("Expected missing repository name error")
    } catch let error as RemoteRepositoryPublishError {
      XCTAssertEqual(error, .missingRepositoryName)
    }
  }

  func testGitHubRollbackCreatesCommitFromParentTreeAndUpdatesBranch() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"sha":"published-sha","tree":{"sha":"published-tree"},"parents":[{"sha":"parent-sha"}]}"#),
      response(json: #"{"sha":"parent-sha","tree":{"sha":"parent-tree"},"parents":[{"sha":"grandparent-sha"}]}"#),
      response(json: #"{"object":{"sha":"published-sha"}}"#),
      response(json: #"{"sha":"rollback-sha","tree":{"sha":"parent-tree"},"parents":[{"sha":"published-sha"}]}"#),
      response(json: #"{"object":{"sha":"rollback-sha"}}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    let draft = RemoteRepositoryRollbackDraft(
      recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000321")!,
      title: "回滚：GitHub Direct",
      commitMessage: "Rollback: GitHub Direct",
      targetBranch: "main",
      commitSHA: "published-sha",
      changedPaths: ["content/posts/github-direct.md"]
    )

    let result = try await service.rollback(draft: draft, profile: profile, token: "github-token")

    XCTAssertEqual(result.provider, .github)
    XCTAssertEqual(result.rolledBackCommitSHA, "published-sha")
    XCTAssertEqual(result.rollbackCommitSHA, "rollback-sha")
    XCTAssertEqual(result.remoteURL, "https://github.com/owner/site/commit/rollback-sha")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "POST", "PATCH"])
    XCTAssertEqual(requests[0].url?.path, "/repos/owner/site/git/commits/published-sha")
    XCTAssertEqual(requests[1].url?.path, "/repos/owner/site/git/commits/parent-sha")
    XCTAssertEqual(requests[2].url?.path, "/repos/owner/site/git/ref/heads/main")
    XCTAssertEqual(requests[3].url?.path, "/repos/owner/site/git/commits")
    XCTAssertEqual(requests[4].url?.path, "/repos/owner/site/git/refs/heads/main")

    let commitBody = try jsonBody(requests[3])
    XCTAssertEqual(commitBody["message"] as? String, "Rollback: GitHub Direct")
    XCTAssertEqual(commitBody["tree"] as? String, "parent-tree")
    XCTAssertEqual(commitBody["parents"] as? [String], ["published-sha"])

    let refBody = try jsonBody(requests[4])
    XCTAssertEqual(refBody["sha"] as? String, "rollback-sha")
    XCTAssertEqual(refBody["force"] as? Bool, false)
  }

  func testGitHubRollbackStopsWhenTargetBranchMoved() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"sha":"published-sha","tree":{"sha":"published-tree"},"parents":[{"sha":"parent-sha"}]}"#),
      response(json: #"{"sha":"parent-sha","tree":{"sha":"parent-tree"},"parents":[{"sha":"grandparent-sha"}]}"#),
      response(json: #"{"object":{"sha":"new-head-sha"}}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    let draft = RemoteRepositoryRollbackDraft(
      recordID: UUID(),
      title: "回滚：Moved",
      commitMessage: "Rollback: Moved",
      targetBranch: "main",
      commitSHA: "published-sha",
      changedPaths: ["content/posts/moved.md"]
    )

    do {
      _ = try await service.rollback(draft: draft, profile: profile, token: "github-token")
      XCTFail("Expected remote version conflict")
    } catch let error as RemoteRepositoryPublishError {
      XCTAssertEqual(
        error,
        .remoteVersionConflict(
          path: "refs/heads/main",
          expectedSHA: "published-sha",
          actualSHA: "new-head-sha"
        )
      )
    }

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET"])
  }

  func testGitLabRollbackUsesCommitRevertAPI() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"id":"rollback-gitlab-sha"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    let draft = RemoteRepositoryRollbackDraft(
      recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000654")!,
      title: "回滚：GitLab Direct",
      commitMessage: "Rollback: GitLab Direct",
      targetBranch: "main",
      commitSHA: "published-gitlab-sha",
      changedPaths: ["content/posts/gitlab-direct.md"]
    )

    let result = try await service.rollback(draft: draft, profile: profile, token: "gitlab-token")

    XCTAssertEqual(result.provider, .gitlab)
    XCTAssertEqual(result.rolledBackCommitSHA, "published-gitlab-sha")
    XCTAssertEqual(result.rollbackCommitSHA, "rollback-gitlab-sha")
    XCTAssertEqual(result.remoteURL, "https://gitlab.com/group/site/-/commit/rollback-gitlab-sha")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["POST"])
    XCTAssertEqual(
      percentEncodedPath(requests[0].url),
      "/api/v4/projects/group%2Fsite/repository/commits/published-gitlab-sha/revert"
    )
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "PRIVATE-TOKEN"), "gitlab-token")
    let body = try jsonBody(requests[0])
    XCTAssertEqual(body["branch"] as? String, "main")
  }

  func testGitHubReviewWithdrawalClosesPullRequest() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"state":"closed","html_url":"https://github.com/owner/site/pull/12"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    let record = ReleaseRecord(
      kind: .remoteReviewRequest,
      title: "线上 PR/MR：Review",
      summary: "GitHub review",
      reviewURL: "https://github.com/owner/site/pull/12"
    )
    let draft = try RemoteRepositoryReviewWithdrawalDraft.make(record: record)

    let result = try await service.withdrawReview(draft: draft, profile: profile, token: "github-token")

    XCTAssertEqual(result.provider, .github)
    XCTAssertEqual(result.reviewNumber, 12)
    XCTAssertEqual(result.state, "closed")
    XCTAssertEqual(result.reviewURL, "https://github.com/owner/site/pull/12")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["PATCH"])
    XCTAssertEqual(requests[0].url?.path, "/repos/owner/site/pulls/12")
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
    let body = try jsonBody(requests[0])
    XCTAssertEqual(body["state"] as? String, "closed")
  }

  func testGitLabReviewWithdrawalClosesMergeRequest() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"state":"closed","web_url":"https://gitlab.com/group/site/-/merge_requests/5"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    let record = ReleaseRecord(
      kind: .remoteReviewRequest,
      title: "线上 PR/MR：Review",
      summary: "GitLab review",
      reviewURL: "https://gitlab.com/group/site/-/merge_requests/5"
    )
    let draft = try RemoteRepositoryReviewWithdrawalDraft.make(record: record)

    let result = try await service.withdrawReview(draft: draft, profile: profile, token: "gitlab-token")

    XCTAssertEqual(result.provider, .gitlab)
    XCTAssertEqual(result.reviewNumber, 5)
    XCTAssertEqual(result.state, "closed")
    XCTAssertEqual(result.reviewURL, "https://gitlab.com/group/site/-/merge_requests/5")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["PUT"])
    XCTAssertEqual(percentEncodedPath(requests[0].url), "/api/v4/projects/group%2Fsite/merge_requests/5")
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "PRIVATE-TOKEN"), "gitlab-token")
    let body = try jsonBody(requests[0])
    XCTAssertEqual(body["state_event"] as? String, "close")
  }

  func testJSONRequestPropagatesBodyEncodingFailure() {
    let service = RemoteRepositoryPublishService()

    XCTAssertThrowsError(
      try service.jsonRequest(
        baseURL: URL(string: "https://api.example.com")!,
        method: "POST",
        path: "/publish",
        queryItems: nil,
        body: ThrowingRemoteRequestBody()
      )
    ) { error in
      XCTAssertTrue(error is ThrowingRemoteRequestBody.EncodingFailure)
    }
  }

  private func githubProfileForDeletion() -> SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    return profile
  }

  private func gitLabProfileForDeletion() -> SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    return profile
  }

  private func deletionPackage(
    path: String,
    expectedRemoteSHA: String? = nil,
    expectedContentSHA256: String? = nil,
    expectedGitBlobSHA: String? = nil
  ) -> PublishPackage {
    PublishPackage(
      draftID: UUID(),
      title: "Delete article",
      markdownPath: path,
      files: [
        PublishPackageFile(
          kind: .markdown,
          operation: .delete,
          repositoryPath: path,
          expectedRemoteSHA: expectedRemoteSHA,
          expectedContentSHA256: expectedContentSHA256,
          expectedGitBlobSHA: expectedGitBlobSHA
        )
      ],
      commitMessage: "Delete article",
      reviewBranchName: "cleanup/article",
      reviewTitle: "Delete article",
      reviewChecklist: []
    )
  }

  private func duplicateNormalizedPathPackage() -> PublishPackage {
    let path = "content/posts/duplicate.md"
    return PublishPackage(
      draftID: UUID(),
      title: "Duplicate path",
      markdownPath: path,
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: path,
          content: "first"
        ),
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: "/./\(path)",
          content: "second"
        ),
      ],
      commitMessage: "Duplicate path",
      reviewBranchName: "publish/duplicate-path",
      reviewTitle: "Duplicate path",
      reviewChecklist: []
    )
  }

  private func fixedDate() -> Date {
    Date(timeIntervalSince1970: 1_787_961_600)
  }

  private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    let body = try XCTUnwrap(request.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
  }

  private func percentEncodedPath(_ url: URL?) -> String? {
    guard let url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
  }
}

private struct ThrowingRemoteRequestBody: Encodable {
  struct EncodingFailure: Error {}

  func encode(to encoder: Encoder) throws {
    throw EncodingFailure()
  }
}

private actor SequencedRemoteRepositoryTransport: RemoteRepositoryHTTPTransport {
  private var responses: [RemoteRepositoryTransportResponse]
  private var requests: [URLRequest] = []

  init(responses: [RemoteRepositoryTransportResponse]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    guard !responses.isEmpty else {
      XCTFail("Unexpected remote repository request: \(request.url?.absoluteString ?? "")")
      return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
    }

    let response = responses.removeFirst()
    return (
      response.data,
      HTTPURLResponse(url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: response.headers)!
    )
  }

  func capturedRequests() -> [URLRequest] {
    requests
  }
}

private struct RemoteRepositoryTransportResponse {
  var statusCode: Int
  var data: Data
  var headers: [String: String]
}

private func response(
  statusCode: Int = 200,
  json: String,
  headers: [String: String] = [:]
) -> RemoteRepositoryTransportResponse {
  RemoteRepositoryTransportResponse(statusCode: statusCode, data: Data(json.utf8), headers: headers)
}
