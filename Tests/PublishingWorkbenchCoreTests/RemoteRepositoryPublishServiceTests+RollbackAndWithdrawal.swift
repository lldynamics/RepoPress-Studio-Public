import CryptoKit
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RemoteRepositoryPublishServiceRollbackAndWithdrawalTests:
  RemoteRepositoryPublishServiceTestCase
{
  func testGitHubRollbackCreatesCommitFromParentTreeAndUpdatesBranch() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(
        json:
          #"{"sha":"published-sha","tree":{"sha":"published-tree"},"parents":[{"sha":"parent-sha"}]}"#
      ),
      response(
        json:
          #"{"sha":"parent-sha","tree":{"sha":"parent-tree"},"parents":[{"sha":"grandparent-sha"}]}"#
      ),
      response(json: #"{"object":{"sha":"published-sha"}}"#),
      response(
        json:
          #"{"sha":"rollback-sha","tree":{"sha":"parent-tree"},"parents":[{"sha":"published-sha"}]}"#
      ),
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
      response(
        json:
          #"{"sha":"published-sha","tree":{"sha":"published-tree"},"parents":[{"sha":"parent-sha"}]}"#
      ),
      response(
        json:
          #"{"sha":"parent-sha","tree":{"sha":"parent-tree"},"parents":[{"sha":"grandparent-sha"}]}"#
      ),
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
      response(json: #"{"id":"rollback-gitlab-sha"}"#)
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
      response(json: #"{"state":"closed","html_url":"https://github.com/owner/site/pull/12"}"#)
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

    let result = try await service.withdrawReview(
      draft: draft, profile: profile, token: "github-token")

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
      response(
        json: #"{"state":"closed","web_url":"https://gitlab.com/group/site/-/merge_requests/5"}"#)
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

    let result = try await service.withdrawReview(
      draft: draft, profile: profile, token: "gitlab-token")

    XCTAssertEqual(result.provider, .gitlab)
    XCTAssertEqual(result.reviewNumber, 5)
    XCTAssertEqual(result.state, "closed")
    XCTAssertEqual(result.reviewURL, "https://gitlab.com/group/site/-/merge_requests/5")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["PUT"])
    XCTAssertEqual(
      percentEncodedPath(requests[0].url), "/api/v4/projects/group%2Fsite/merge_requests/5")
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

}
