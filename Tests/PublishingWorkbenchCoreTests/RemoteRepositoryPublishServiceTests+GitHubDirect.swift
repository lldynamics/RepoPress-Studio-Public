import CryptoKit
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RemoteRepositoryPublishServiceGitHubDirectTests: RemoteRepositoryPublishServiceTestCase
{
  func testGitHubDirectPublishUpdatesExistingContentOnTargetBranch() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"sha":"existing-file-sha"}"#),
      response(
        json:
          #"{"content":{"path":"content/posts/github-direct.md"},"commit":{"sha":"direct-commit-sha"}}"#
      ),
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
    XCTAssertEqual(
      requests[0].url?.path, "/repos/owner/site/contents/content/posts/github-direct.md")
    XCTAssertEqual(requests[0].url?.query, "ref=main")
    XCTAssertEqual(
      requests[1].url?.path, "/repos/owner/site/contents/content/posts/github-direct.md")
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
      response(
        json:
          #"{"sha":"base-commit-sha","tree":{"sha":"base-tree-sha"},"parents":[{"sha":"parent-sha"}]}"#
      ),
      response(statusCode: 404, json: #"{"message":"not found"}"#),
      response(json: #"{"sha":"new-content-sha"}"#),
      response(json: #"{"sha":"old-content-sha"}"#),
      response(json: #"{"sha":"new-tree-sha"}"#),
      response(
        json:
          #"{"sha":"migration-commit-sha","tree":{"sha":"new-tree-sha"},"parents":[{"sha":"base-commit-sha"}]}"#
      ),
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
    XCTAssertEqual(
      requests.map(\.httpMethod), ["GET", "GET", "GET", "POST", "GET", "POST", "POST", "PATCH"])
    XCTAssertEqual(requests[5].url?.path, "/repos/owner/site/git/trees")
    XCTAssertEqual(requests[6].url?.path, "/repos/owner/site/git/commits")
    XCTAssertEqual(requests[7].url?.path, "/repos/owner/site/git/refs/heads/main")
    let treeBody = try jsonBody(requests[5])
    XCTAssertEqual(treeBody["base_tree"] as? String, "base-tree-sha")
    let entries = try XCTUnwrap(treeBody["tree"] as? [[String: Any]])
    XCTAssertEqual(
      entries.map { $0["path"] as? String },
      ["content/posts/new-path.md", "content/posts/old-path.md"])
    XCTAssertTrue(entries[1]["sha"] is NSNull)
  }

  func testGitHubDirectDeleteTreatsMissingRemoteFileAsIdempotentSuccess() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(statusCode: 404, json: #"{"message":"not found"}"#)
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
      response(json: #"{"sha":"remote-different-sha"}"#)
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

  func testGitHubReviewDeleteUsesReviewBranchSnapshotWithoutRequiringLocalBaseline() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"base-sha"}}"#),
      response(json: #"{"ref":"refs/heads/cleanup/article","object":{"sha":"base-sha"}}"#),
      response(json: #"{"sha":"new-target-sha"}"#),
      response(json: #"{"content":null,"commit":{"sha":"delete-commit"}}"#),
      response(json: #"{"html_url":"https://github.com/owner/site/pull/9"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = githubProfileForDeletion()
    let path = "content/posts/review-conflict.md"
    let package = deletionPackage(path: path)

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .reviewRequest,
      token: "secret-token"
    )

    let requests = await transport.capturedRequests()
    XCTAssertEqual(result.changedPaths, [path])
    XCTAssertEqual(result.reviewPendingPaths, [path])
    XCTAssertEqual(result.reviewURL, "https://github.com/owner/site/pull/9")
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "DELETE", "POST"])
  }

  func testGitHubAtomicReviewDeletesUntrackedRemoteFilesOnReviewBranch() async throws {
    let firstPath = "content/posts/first-retired.md"
    let secondPath = "content/posts/second-retired.md"
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"base-sha"}}"#),
      response(json: #"{"ref":"refs/heads/cleanup/articles","object":{"sha":"base-sha"}}"#),
      response(
        json:
          #"{"sha":"base-sha","tree":{"sha":"base-tree-sha"},"parents":[{"sha":"parent-sha"}]}"#
      ),
      response(json: #"{"sha":"first-remote-sha"}"#),
      response(json: #"{"sha":"second-remote-sha"}"#),
      response(json: #"{"sha":"review-tree-sha"}"#),
      response(
        json:
          #"{"sha":"review-commit-sha","tree":{"sha":"review-tree-sha"},"parents":[{"sha":"base-sha"}]}"#
      ),
      response(
        json:
          #"{"ref":"refs/heads/cleanup/articles","object":{"sha":"review-commit-sha"}}"#
      ),
      response(json: #"{"html_url":"https://github.com/owner/site/pull/10"}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = githubProfileForDeletion()
    let package = PublishPackage(
      draftID: UUID(),
      title: "Delete articles",
      markdownPath: firstPath,
      files: [
        PublishPackageFile(kind: .markdown, operation: .delete, repositoryPath: firstPath),
        PublishPackageFile(kind: .markdown, operation: .delete, repositoryPath: secondPath),
      ],
      commitMessage: "Delete articles",
      reviewBranchName: "cleanup/articles",
      reviewTitle: "Delete articles",
      reviewChecklist: []
    )

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .reviewRequest,
      token: "secret-token"
    )

    XCTAssertEqual(result.changedPaths, [firstPath, secondPath])
    XCTAssertEqual(result.reviewPendingPaths, [firstPath, secondPath])
    XCTAssertEqual(result.reviewURL, "https://github.com/owner/site/pull/10")
    let requests = await transport.capturedRequests()
    XCTAssertEqual(
      requests.map(\.httpMethod),
      ["GET", "POST", "GET", "GET", "GET", "POST", "POST", "PATCH", "POST"]
    )
  }

  func testGitHubReviewDeleteReportsPathAwaitingMerge() async throws {
    let path = "content/posts/review-delete.md"
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"base-sha"}}"#),
      response(json: #"{"ref":"refs/heads/cleanup/article","object":{"sha":"base-sha"}}"#),
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
      response(
        json:
          #"{"sha":"base-commit-sha","tree":{"sha":"base-tree-sha"},"parents":[{"sha":"parent-sha"}]}"#
      ),
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
    XCTAssertFalse(
      requests.contains { $0.httpMethod == "POST" && $0.url?.path.contains("/git/trees") == true })
    XCTAssertFalse(
      requests.contains { $0.httpMethod == "POST" && $0.url?.path.contains("/git/commits") == true }
    )
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
      response(
        json:
          #"{"sha":"base-commit-sha","tree":{"sha":"base-tree-sha"},"parents":[{"sha":"parent-sha"}]}"#
      ),
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
    XCTAssertFalse(
      requests.contains { $0.httpMethod == "POST" && $0.url?.path.contains("/git/commits") == true }
    )
    XCTAssertFalse(requests.contains { $0.httpMethod == "PATCH" })
  }

  func testGitHubDirectPreflightCollectsAllConflictsAndAdoptsIdenticalFilesWithoutWrites()
    async throws
  {
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

  func testGitHubConflictResolutionSessionUsesCurrentContentsAndExactBaselineBlob() async throws {
    let path = "content/posts/conflicted.md"
    let local = "---\ntitle: Local\n---\n\nLocal body\n"
    let remote = "---\ntitle: Remote\n---\n\nRemote body\n"
    let base = "---\ntitle: Base\n---\n\nBase body\n"
    let remoteContent = Data(remote.utf8).base64EncodedString()
    let baseContent = Data(base.utf8).base64EncodedString()
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(
        json: #"{"sha":"actual-blob","content":"\#(remoteContent)","encoding":"base64"}"#
      ),
      response(
        json: #"{"sha":"expected-blob","content":"\#(baseContent)","encoding":"base64"}"#
      ),
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
      title: "Conflict",
      markdownPath: path,
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: path,
          content: local,
          expectedRemoteSHA: "expected-blob"
        )
      ],
      commitMessage: "Resolve",
      reviewBranchName: "publish/conflict",
      reviewTitle: "Resolve conflict",
      reviewChecklist: []
    )

    let session = try await service.conflictResolutionSession(
      package: package,
      profile: profile,
      token: "github-token"
    )

    let item = try XCTUnwrap(session.conflicts.first)
    XCTAssertEqual(item.repositoryPath, path)
    XCTAssertEqual(item.local.text, local)
    XCTAssertEqual(item.remote.text, remote)
    XCTAssertEqual(item.base.text, base)
    XCTAssertTrue(item.canMergeText)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
    XCTAssertEqual(
      requests.compactMap { percentEncodedPath($0.url) },
      [
        "/repos/owner/site/contents/content/posts/conflicted.md",
        "/repos/owner/site/git/blobs/expected-blob",
      ]
    )
    XCTAssertEqual(
      URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "ref" })?.value,
      "main"
    )
    XCTAssertTrue(requests.allSatisfy { $0.httpBody == nil })
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
      response(
        json:
          #"{"sha":"base-commit-sha","tree":{"sha":"base-tree-sha"},"parents":[{"sha":"parent-sha"}]}"#
      ),
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
      bodyMarkdown:
        "This body is intentionally long enough for GitHub partial publish failure coverage.",
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
    XCTAssertEqual(
      requests.map(\.httpMethod), ["GET", "GET", "GET", "POST", "GET", "POST", "POST"])
    XCTAssertFalse(requests.contains { $0.httpMethod == "PATCH" })
    XCTAssertEqual(requests.last?.url?.path, "/repos/owner/site/git/trees")
  }

  func testGitHubDirectPublishStopsWhenExpectedRemoteSHAChanged() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"sha":"new-remote-sha"}"#)
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
      bodyMarkdown:
        "This body is intentionally long enough for GitHub direct remote conflict coverage.",
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
    XCTAssertEqual(
      requests[0].url?.path, "/repos/owner/site/contents/content/posts/github-conflict.md")
  }

  func testGitHubDirectPublishStopsWhenRemoteFileExistsWithoutLocalSHA() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"sha":"remote-only-sha"}"#)
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
      bodyMarkdown:
        "This body is intentionally long enough for GitHub unknown remote file conflict coverage."
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
        .untrackedRemoteFile(
          path: "content/posts/github-unknown-remote.md", actualSHA: "remote-only-sha")
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
    XCTAssertEqual(
      requests[0].url?.path, "/repos/owner/site/contents/content/posts/github-unknown-remote.md")
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
      bodyMarkdown:
        "This body is intentionally long enough for GitHub identical content adoption coverage."
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
      bodyMarkdown:
        "This body is intentionally long enough for GitHub known baseline no-op coverage."
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

}
