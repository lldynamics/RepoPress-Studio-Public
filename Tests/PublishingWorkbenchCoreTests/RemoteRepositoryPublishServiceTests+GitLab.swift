import CryptoKit
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RemoteRepositoryPublishServiceGitLabTests: RemoteRepositoryPublishServiceTestCase {
  func testGitLabDirectPublishMigratesPathInSingleCommit() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(statusCode: 404, json: #"{"message":"not found"}"#),
      response(
        json: #"{"file_path":"content/posts/old-path.md","last_commit_id":"old-commit-sha"}"#),
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
      response(statusCode: 404, json: #"{"message":"not found"}"#)
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

  func testGitLabDirectDeleteAdoptsMatchingLocalContentEvidenceWithoutRemoteCommitID() async throws
  {
    let content = Data("published markdown".utf8)
    let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(
        json:
          #"{"file_path":"content/posts/legacy-gitlab.md","last_commit_id":"remote-commit","content":"published markdown","encoding":"text"}"#
      ),
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

  func testGitLabReviewDeleteUsesReviewBranchSnapshotWithoutRequiringLocalBaseline() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(statusCode: 404, json: #"{"message":"not found"}"#),
      response(
        json:
          #"{"file_path":"content/posts/review-conflict.md","last_commit_id":"new-target-commit","content":"new content","encoding":"text"}"#
      ),
      response(json: #"{"id":"delete-commit"}"#),
      response(json: #"[]"#),
      response(json: #"{"web_url":"https://gitlab.com/group/site/-/merge_requests/9"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = gitLabProfileForDeletion()
    let path = "content/posts/review-conflict.md"
    let package = deletionPackage(path: path)

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .reviewRequest,
      token: "gitlab-token"
    )

    let requests = await transport.capturedRequests()
    XCTAssertEqual(result.changedPaths, [path])
    XCTAssertEqual(result.reviewPendingPaths, [path])
    XCTAssertEqual(result.reviewURL, "https://gitlab.com/group/site/-/merge_requests/9")
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST", "GET", "POST"])
    let commitBody = try jsonBody(requests[2])
    XCTAssertEqual(commitBody["start_branch"] as? String, "main")
    let actions = try XCTUnwrap(commitBody["actions"] as? [[String: Any]])
    XCTAssertEqual(actions.first?["action"] as? String, "delete")
    XCTAssertEqual(actions.first?["last_commit_id"] as? String, "new-target-commit")
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
      response(
        json: #"{"file_path":"static/images/2026/gitlab.png","last_commit_id":"image-base-commit"}"#
      ),
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
    XCTAssertEqual(
      percentEncodedPath(requests[0].url),
      "/api/v4/projects/group%2Fsite/repository/branches/publish%2Fgitlab-review-20260829")
    XCTAssertEqual(
      percentEncodedPath(requests[1].url),
      "/api/v4/projects/group%2Fsite/repository/files/content%2Fposts%2Fgitlab-review.md")
    XCTAssertEqual(
      percentEncodedPath(requests[2].url),
      "/api/v4/projects/group%2Fsite/repository/files/static%2Fimages%2F2026%2Fgitlab.png")
    XCTAssertEqual(
      percentEncodedPath(requests[3].url), "/api/v4/projects/group%2Fsite/repository/commits")
    XCTAssertEqual(
      percentEncodedPath(requests[4].url), "/api/v4/projects/group%2Fsite/merge_requests")
    XCTAssertEqual(
      percentEncodedPath(requests[5].url), "/api/v4/projects/group%2Fsite/merge_requests")
    XCTAssertEqual(requests[3].value(forHTTPHeaderField: "PRIVATE-TOKEN"), "gitlab-token")
    XCTAssertTrue(
      requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/json" })

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
    XCTAssertTrue(
      (requests[4].url?.query ?? "").contains("source_branch=publish/gitlab-review-20260829"))
    XCTAssertTrue((requests[4].url?.query ?? "").contains("target_branch=main"))

    let mergeRequestBody = try jsonBody(requests[5])
    XCTAssertEqual(mergeRequestBody["source_branch"] as? String, "publish/gitlab-review-20260829")
    XCTAssertEqual(mergeRequestBody["target_branch"] as? String, "main")
  }

  func testGitLabDirectPublishUpdatesExistingContentOnTargetBranch() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(
        json:
          #"{"file_path":"content/posts/gitlab-direct.md","last_commit_id":"existing-gitlab-commit"}"#
      ),
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
    XCTAssertEqual(
      percentEncodedPath(requests[0].url),
      "/api/v4/projects/group%2Fsite/repository/files/content%2Fposts%2Fgitlab-direct.md")
    XCTAssertEqual(requests[0].url?.query, "ref=main")
    XCTAssertEqual(
      percentEncodedPath(requests[1].url), "/api/v4/projects/group%2Fsite/repository/commits")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "PRIVATE-TOKEN"), "gitlab-token")
    XCTAssertTrue(
      requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/json" })

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
        json:
          #"{"file_path":"content/posts/unchanged.md","last_commit_id":"existing-gitlab-commit","content":"c2FtZSBjb250ZW50","encoding":"base64"}"#
      )
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
      response(
        json:
          #"{"file_path":"content/posts/gitlab-conflict.md","last_commit_id":"new-gitlab-commit"}"#)
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
      bodyMarkdown:
        "This body is intentionally long enough for GitLab direct remote conflict coverage.",
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
    XCTAssertEqual(
      percentEncodedPath(requests[0].url),
      "/api/v4/projects/group%2Fsite/repository/files/content%2Fposts%2Fgitlab-conflict.md")
  }

  func testGitLabDirectPublishStopsWhenRemoteFileExistsWithoutLocalCommitID() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(
        json:
          #"{"file_path":"content/posts/gitlab-unknown-remote.md","last_commit_id":"remote-only-gitlab-commit"}"#
      )
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
      bodyMarkdown:
        "This body is intentionally long enough for GitLab unknown remote file conflict coverage."
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
    XCTAssertEqual(
      percentEncodedPath(requests[0].url),
      "/api/v4/projects/group%2Fsite/repository/files/content%2Fposts%2Fgitlab-unknown-remote.md")
  }

  func testGitLabDirectPublishAutoAdoptsExistingIdenticalContentWithoutLocalCommitID() async throws
  {
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
      bodyMarkdown:
        "This body is intentionally long enough for GitLab identical content adoption coverage."
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

  func testGitLabDirectPreflightCollectsAllConflictsAndAdoptsIdenticalFilesWithoutWrites()
    async throws
  {
    let adoptedPath = "./content/posts/gitlab-preflight-adopt.md"
    let untrackedPath = "content/posts/gitlab-preflight-untracked.md"
    let versionConflictPath = "content/posts/gitlab-preflight-version.md"
    let missingDeletePath = "content/posts/gitlab-preflight-missing.md"
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(
        json:
          #"{"file_path":"content/posts/gitlab-preflight-adopt.md","last_commit_id":"adopt-commit","content":"adopted content","encoding":"text"}"#
      ),
      response(
        json:
          #"{"file_path":"content/posts/gitlab-preflight-untracked.md","last_commit_id":"remote-untracked","content":"remote untracked","encoding":"text"}"#
      ),
      response(
        json:
          #"{"file_path":"content/posts/gitlab-preflight-version.md","last_commit_id":"remote-version","content":"remote version","encoding":"text"}"#
      ),
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

  func testGitLabConflictResolutionSessionReadsTargetAndExpectedCommitAsGETOnly() async throws {
    let path = "content/posts/gitlab-conflict.md"
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(
        json: #"{"last_commit_id":"actual-commit","content":"remote body","encoding":"text"}"#
      ),
      response(
        json: #"{"last_commit_id":"expected-commit","content":"base body","encoding":"text"}"#
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
      title: "GitLab conflict",
      markdownPath: path,
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: path,
          content: "local body",
          expectedRemoteSHA: "expected-commit"
        )
      ],
      commitMessage: "Resolve",
      reviewBranchName: "publish/gitlab-conflict",
      reviewTitle: "Resolve conflict",
      reviewChecklist: []
    )

    let session = try await service.conflictResolutionSession(
      package: package,
      profile: profile,
      token: "gitlab-token"
    )

    let item = try XCTUnwrap(session.conflicts.first)
    XCTAssertEqual(item.local.text, "local body")
    XCTAssertEqual(item.remote.text, "remote body")
    XCTAssertEqual(item.base.text, "base body")
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
    XCTAssertTrue(requests.allSatisfy { $0.httpBody == nil })
    XCTAssertEqual(
      requests.compactMap { request in
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
          .queryItems?.first(where: { $0.name == "ref" })?.value
      },
      ["main", "expected-commit"]
    )
  }

  func testGitLabReviewPublishUpdatesExistingReviewBranchOnRetry() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"name":"publish/gitlab-review-20260829"}"#),
      response(
        json:
          #"{"file_path":"content/posts/gitlab-review.md","last_commit_id":"markdown-base-commit"}"#
      ),
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
      bodyMarkdown:
        "This body is intentionally long enough for GitLab review publishing retry behavior."
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
    XCTAssertEqual(
      percentEncodedPath(requests[0].url),
      "/api/v4/projects/group%2Fsite/repository/branches/publish%2Fgitlab-review-20260829")
    XCTAssertEqual(
      percentEncodedPath(requests[1].url),
      "/api/v4/projects/group%2Fsite/repository/files/content%2Fposts%2Fgitlab-review.md")
    XCTAssertEqual(requests[1].url?.query, "ref=publish/gitlab-review-20260829")

    let commitBody = try jsonBody(requests[2])
    XCTAssertEqual(commitBody["branch"] as? String, "publish/gitlab-review-20260829")
    XCTAssertNil(commitBody["start_branch"])
    let actions = try XCTUnwrap(commitBody["actions"] as? [[String: Any]])
    XCTAssertEqual(actions.count, 1)
    XCTAssertEqual(actions[0]["action"] as? String, "update")
    XCTAssertEqual(actions[0]["file_path"] as? String, "content/posts/gitlab-review.md")
    XCTAssertEqual(actions[0]["last_commit_id"] as? String, "markdown-base-commit")

    XCTAssertEqual(
      percentEncodedPath(requests[3].url), "/api/v4/projects/group%2Fsite/merge_requests")
    XCTAssertTrue((requests[3].url?.query ?? "").contains("state=opened"))
    XCTAssertTrue(
      (requests[3].url?.query ?? "").contains("source_branch=publish/gitlab-review-20260829"))
    XCTAssertTrue((requests[3].url?.query ?? "").contains("target_branch=main"))
  }

  func testGitLabNoOpExistingMergeRequestPersistsCurrentBranchHead() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"name":"publish/no-op"}"#),
      response(
        json:
          #"{"file_path":"content/posts/no-op.md","last_commit_id":"old","content":"c2FtZQ==","encoding":"base64"}"#
      ),
      response(json: #"[{"iid":8,"web_url":"https://gitlab.com/group/site/-/merge_requests/8"}]"#),
      response(json: #"{"name":"publish/no-op","commit":{"id":"current-review-head"}}"#),
    ])
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    let package = PublishPackage(
      draftID: UUID(), title: "No-op", markdownPath: "content/posts/no-op.md",
      files: [
        PublishPackageFile(
          kind: .markdown, repositoryPath: "content/posts/no-op.md", content: "same")
      ],
      commitMessage: "No-op", reviewBranchName: "publish/no-op", reviewTitle: "No-op",
      reviewChecklist: []
    )
    let result = try await RemoteRepositoryPublishService(transport: transport).publish(
      package: package, profile: profile, mode: .reviewRequest, token: "token"
    )
    XCTAssertEqual(result.reviewNumber, 8)
    XCTAssertEqual(result.commitSHA, "current-review-head")
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
      bodyMarkdown:
        "This body is intentionally long enough for GitLab review partial failure coverage."
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
      guard
        case .partialPublish(
          let provider, let mode, let branchName, let targetBranch, let changedPaths, let commitSHA,
          let underlyingMessage) = error
      else {
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
      XCTAssertTrue(
        error.localizedDescription.contains(String("gitlab-review-commit-sha".prefix(8))))
    }

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST", "GET", "POST"])
    XCTAssertEqual(
      percentEncodedPath(requests[2].url), "/api/v4/projects/group%2Fsite/repository/commits")
    XCTAssertEqual(
      percentEncodedPath(requests[4].url), "/api/v4/projects/group%2Fsite/merge_requests")
  }

}
