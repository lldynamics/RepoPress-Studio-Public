import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RemoteRepositoryReviewStatusTests: XCTestCase {
  private let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)

  func testGitHubOpenMergedAndClosedUnmergedStates() async throws {
    let cases: [(String, String, RemoteRepositoryReviewLifecycleState, String?)] = [
      ("open", "false", .open, nil),
      ("closed", "true", .merged, "merge-sha"),
      ("closed", "false", .closedWithoutMerge, nil),
    ]

    for (state, merged, expectedState, expectedMergeSHA) in cases {
      let mergeJSON = expectedMergeSHA.map { "\"\($0)\"" } ?? "null"
      let transport = SequencedRemoteRepositoryTransport(responses: [
        response(
          json: """
            {
              "number": 12,
              "state": "\(state)",
              "merged": \(merged),
              "html_url": "https://github.com/owner/site/pull/12",
              "merge_commit_sha": \(mergeJSON),
              "head": {"ref": "review/article", "sha": "head-sha", "repo": {"full_name": "owner/site"}},
              "base": {"ref": "main", "sha": "base-sha", "repo": {"full_name": "owner/site"}}
            }
            """)
      ])
      let service = RemoteRepositoryPublishService(transport: transport)
      let profile = githubProfile()
      let record = reviewRecord(
        profile: profile,
        number: 12,
        url: "https://github.com/owner/site/pull/12",
        sourceBranch: "review/article"
      )

      let snapshot = try await service.reviewStatus(
        for: record, profile: profile, token: "gh-token", checkedAt: checkedAt
      )

      XCTAssertEqual(snapshot.state, expectedState)
      XCTAssertEqual(snapshot.reviewNumber, 12)
      XCTAssertEqual(snapshot.mergeCommitSHA, expectedMergeSHA)
      XCTAssertEqual(snapshot.checkedAt, checkedAt)
      let requests = await transport.capturedRequests()
      let request = try XCTUnwrap(requests.first)
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.url?.path, "/repos/owner/site/pulls/12")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gh-token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }
  }

  func testGitLabOpenedLockedMergedAndClosedStates() async throws {
    let cases: [(String, String?, RemoteRepositoryReviewLifecycleState)] = [
      ("opened", nil, .open),
      ("locked", nil, .locked),
      ("merged", "gitlab-merge-sha", .merged),
      ("closed", nil, .closedWithoutMerge),
    ]

    for (state, mergeSHA, expectedState) in cases {
      let mergeJSON = mergeSHA.map { "\"\($0)\"" } ?? "null"
      let transport = SequencedRemoteRepositoryTransport(responses: [
        response(
          json: """
            {
              "iid": 7,
              "state": "\(state)",
              "web_url": "https://gitlab.com/group/site/-/merge_requests/7",
              "source_branch": "review/article",
              "target_branch": "main",
              "sha": "head-sha",
              "merge_commit_sha": \(mergeJSON),
              "squash_commit_sha": null
            }
            """)
      ])
      let service = RemoteRepositoryPublishService(transport: transport)
      let profile = gitLabProfile()
      let record = reviewRecord(
        profile: profile,
        number: 7,
        url: "https://gitlab.com/group/site/-/merge_requests/7",
        sourceBranch: "review/article"
      )

      let snapshot = try await service.reviewStatus(
        for: record, profile: profile, token: "gl-token", checkedAt: checkedAt
      )

      XCTAssertEqual(snapshot.state, expectedState)
      XCTAssertEqual(snapshot.mergeCommitSHA, mergeSHA)
      let requests = await transport.capturedRequests()
      let request = try XCTUnwrap(requests.first)
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://gitlab.com/api/v4/projects/group%2Fsite/merge_requests/7"
      )
      XCTAssertEqual(request.value(forHTTPHeaderField: "PRIVATE-TOKEN"), "gl-token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }
  }

  func testInvalidReviewURLFailsBeforeNetworkRequest() async throws {
    let profile = githubProfile()
    for invalidURL in [
      "https://github.com/other/site/pull/12",
      "https://github.com/owner/site/pull/0",
    ] {
      let transport = SequencedRemoteRepositoryTransport(responses: [])
      let service = RemoteRepositoryPublishService(transport: transport)
      let record = reviewRecord(
        profile: profile,
        number: 12,
        url: invalidURL,
        sourceBranch: "review/article"
      )

      await assertThrowsErrorAsync {
        _ = try await service.reviewStatus(for: record, profile: profile, token: "gh-token")
      }
      let requests = await transport.capturedRequests()
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testResponseIdentityMismatchIsRejected() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(
        json: """
          {
            "number": 99,
            "state": "open",
            "merged": false,
            "html_url": "https://github.com/owner/site/pull/99",
            "merge_commit_sha": null,
            "head": {"ref": "review/article", "sha": "head-sha", "repo": {"full_name": "owner/site"}},
            "base": {"ref": "main", "sha": "base-sha", "repo": {"full_name": "owner/site"}}
          }
          """)
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = githubProfile()
    let record = reviewRecord(
      profile: profile,
      number: 12,
      url: "https://github.com/owner/site/pull/12",
      sourceBranch: "review/article"
    )

    await assertThrowsErrorAsync {
      _ = try await service.reviewStatus(for: record, profile: profile, token: "gh-token")
    }
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 1)
  }

  func testGitHubHeadDriftIsReportedForExplicitUserConfirmation() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(
        json: """
          {
            "number": 12,
            "state": "open",
            "merged": false,
            "html_url": "https://github.com/owner/site/pull/12",
            "merge_commit_sha": null,
            "head": {"ref": "review/article", "sha": "unexpected-head", "repo": {"full_name": "owner/site"}},
            "base": {"ref": "main", "sha": "base-sha", "repo": {"full_name": "owner/site"}}
          }
          """)
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = githubProfile()
    let record = reviewRecord(
      profile: profile,
      number: 12,
      url: "https://github.com/owner/site/pull/12",
      sourceBranch: "review/article"
    )

    let snapshot = try await service.reviewStatus(for: record, profile: profile, token: "gh-token")
    XCTAssertEqual(snapshot.state, .open)
    XCTAssertEqual(snapshot.headCommitSHA, "unexpected-head")
  }

  func testClosedReviewCanReopenThenMergeWithoutChangingOriginalAuditHead() async throws {
    let responses = [
      #"{"number":12,"state":"closed","merged":false,"html_url":"https://github.com/owner/site/pull/12","merge_commit_sha":null,"head":{"ref":"review/article","sha":"head-sha","repo":{"full_name":"owner/site"}},"base":{"ref":"main","sha":"base-sha","repo":{"full_name":"owner/site"}}}"#,
      #"{"number":12,"state":"open","merged":false,"html_url":"https://github.com/owner/site/pull/12","merge_commit_sha":null,"head":{"ref":"review/article","sha":"head-sha","repo":{"full_name":"owner/site"}},"base":{"ref":"main","sha":"base-sha","repo":{"full_name":"owner/site"}}}"#,
      #"{"number":12,"state":"closed","merged":true,"html_url":"https://github.com/owner/site/pull/12","merge_commit_sha":"merge-sha","head":{"ref":"review/article","sha":"head-sha","repo":{"full_name":"owner/site"}},"base":{"ref":"main","sha":"base-sha","repo":{"full_name":"owner/site"}}}"#,
    ]
    let transport = SequencedRemoteRepositoryTransport(
      responses: responses.map { response(json: $0) })
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = githubProfile()
    let record = reviewRecord(
      profile: profile, number: 12, url: "https://github.com/owner/site/pull/12",
      sourceBranch: "review/article")
    let closed = try await service.reviewStatus(for: record, profile: profile, token: "gh-token")
    let reopened = try await service.reviewStatus(for: record, profile: profile, token: "gh-token")
    let merged = try await service.reviewStatus(for: record, profile: profile, token: "gh-token")
    XCTAssertEqual(
      [closed.state, reopened.state, merged.state], [.closedWithoutMerge, .open, .merged])
    XCTAssertEqual(record.commitSHA, "head-sha")
  }

  private func githubProfile() -> SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    return profile
  }

  private func gitLabProfile() -> SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    return profile
  }

  private func reviewRecord(
    profile: SiteProfile,
    number: Int,
    url: String,
    sourceBranch: String
  ) -> ReleaseRecord {
    ReleaseRecord(
      kind: .remoteReviewRequest,
      title: "Review",
      summary: "Review",
      siteProfileID: profile.id,
      siteName: profile.name,
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: sourceBranch,
      targetBranch: profile.branch,
      commitSHA: "head-sha",
      reviewNumber: number,
      reviewURL: url
    )
  }
}

extension XCTestCase {
  fileprivate func assertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      try await expression()
      XCTFail("Expected an error", file: file, line: line)
    } catch {
      // Expected.
    }
  }
}
