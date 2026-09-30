import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class DraftPreviewBranchPublishTests: XCTestCase {
  func testPreviewBranchNameIsStableAndSafe() {
    XCTAssertEqual(
      RemoteRepositoryPublishMode.previewBranch.displayName,
      CoreL10n.text("草稿预览分支")
    )
    XCTAssertTrue(RemoteRepositoryPublishMode.previewBranch.usesDedicatedBranch)
    XCTAssertFalse(RemoteRepositoryPublishMode.previewBranch.createsReview)
    XCTAssertEqual(
      DraftPreviewBranchPolicy.branchName(slug: "  Deep Article / @2026  "),
      "draft/deep-article-2026"
    )
    XCTAssertEqual(
      DraftPreviewBranchPolicy.branchName(slug: "../.lock"),
      "draft/lock"
    )
    XCTAssertFalse(DraftPreviewBranchPolicy.branchName(slug: "unsafe").contains(".."))
  }

  func testGitHubPreviewBranchWritesDedicatedBranchWithoutPullRequest() async throws {
    let transport = DraftPreviewRemoteTransport(responses: [
      response(json: #"{"object":{"sha":"main-sha"}}"#),
      response(json: #"{"ref":"refs/heads/draft/preview-article","object":{"sha":"main-sha"}}"#),
      response(statusCode: 404, json: #"{"message":"Not Found"}"#),
      response(json: #"{"content":{"sha":"content-sha"},"commit":{"sha":"preview-commit"}}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = githubProfile()
    let package = previewPackage(slug: "preview-article")

    let result = try await service.publish(
      package: package,
      profile: profile,
      mode: .previewBranch,
      token: "secret-token"
    )

    XCTAssertEqual(result.mode, .previewBranch)
    XCTAssertEqual(result.branchName, "draft/preview-article")
    XCTAssertEqual(result.targetBranch, "main")
    XCTAssertNil(result.reviewURL)
    XCTAssertNil(result.reviewTitle)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "PUT"])
    XCTAssertFalse(requests.contains { $0.url?.path.contains("/pulls") == true })
    XCTAssertTrue(
      requests.allSatisfy { $0.url?.path.contains("/main") != true || $0.httpMethod == "GET" })

    let createBody = try jsonBody(requests[1])
    XCTAssertEqual(createBody["ref"] as? String, "refs/heads/draft/preview-article")
    XCTAssertEqual(createBody["sha"] as? String, "main-sha")
    let putBody = try jsonBody(requests[3])
    XCTAssertEqual(putBody["branch"] as? String, "draft/preview-article")
    XCTAssertNotEqual(putBody["branch"] as? String, "main")
    XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
  }

  func testGitHubPreviewBranchReusesDedicatedBranchWithoutPullRequest() async throws {
    let transport = DraftPreviewRemoteTransport(responses: [
      response(json: #"{"object":{"sha":"main-sha"}}"#),
      response(statusCode: 422, json: #"{"message":"Reference already exists"}"#),
      response(statusCode: 404, json: #"{"message":"Not Found"}"#),
      response(json: #"{"content":{"sha":"content-sha"},"commit":{"sha":"preview-commit-2"}}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)

    _ = try await service.publish(
      package: previewPackage(slug: "preview-article"),
      profile: githubProfile(),
      mode: .previewBranch,
      token: "secret-token"
    )

    let requests = await transport.capturedRequests()
    XCTAssertFalse(requests.contains { $0.url?.path.contains("/pulls") == true })
    let putBody = try jsonBody(try XCTUnwrap(requests.last))
    XCTAssertEqual(putBody["branch"] as? String, "draft/preview-article")
  }

  func testGitLabPreviewBranchStartsFromTargetWithoutMergeRequest() async throws {
    let transport = DraftPreviewRemoteTransport(responses: [
      response(statusCode: 404, json: #"{"message":"404 Branch Not Found"}"#),
      response(json: #"{"commit":{"id":"main-sha"}}"#),
      response(statusCode: 404, json: #"{"message":"404 File Not Found"}"#),
      response(
        json:
          #"{"id":"preview-commit","web_url":"https://gitlab.com/group/site/-/commit/preview-commit"}"#
      ),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let result = try await service.publish(
      package: previewPackage(slug: "preview-article"),
      profile: gitLabProfile(),
      mode: .previewBranch,
      token: "secret-token"
    )

    XCTAssertEqual(result.mode, .previewBranch)
    XCTAssertEqual(result.branchName, "draft/preview-article")
    XCTAssertNil(result.reviewURL)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "POST"])
    XCTAssertFalse(requests.contains { $0.url?.path.contains("merge_requests") == true })
    let commitBody = try jsonBody(requests[3])
    XCTAssertEqual(commitBody["branch"] as? String, "draft/preview-article")
    XCTAssertEqual(commitBody["start_branch"] as? String, "main")
    XCTAssertNotEqual(commitBody["branch"] as? String, "main")
  }

  func testGitLabUnchangedPreviewCreatesBranchAtVerifiedMainHeadAndReadsItBack() async throws {
    let package = previewPackage(slug: "preview-article")
    let encoded = Data(try XCTUnwrap(package.markdownFile?.content).utf8).base64EncodedString()
    let transport = DraftPreviewRemoteTransport(responses: [
      response(statusCode: 404, json: #"{"message":"404 Branch Not Found"}"#),
      response(json: #"{"commit":{"id":"verified-main-sha"}}"#),
      response(
        json: """
          {"last_commit_id":"file-version","content":"\(encoded)","encoding":"base64"}
          """),
      response(json: #"{"name":"draft/preview-article","commit":{"id":"verified-main-sha"}}"#),
      response(json: #"{"commit":{"id":"verified-main-sha"}}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)

    let result = try await service.publish(
      package: package, profile: gitLabProfile(), mode: .previewBranch, token: "secret-token")

    XCTAssertEqual(result.commitSHA, "verified-main-sha")
    XCTAssertEqual(result.branchName, "draft/preview-article")
    XCTAssertTrue(result.changedPaths.isEmpty)
    XCTAssertEqual(result.remoteVersion(for: package.markdownPath), "file-version")
    XCTAssertNil(result.reviewURL)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "POST", "GET"])
    XCTAssertEqual(
      URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?
        .percentEncodedPath,
      "/api/v4/projects/group%2Fsite/repository/branches/main")
    let fileQuery = URLComponents(
      url: try XCTUnwrap(requests[2].url), resolvingAgainstBaseURL: false)
    XCTAssertEqual(fileQuery?.queryItems?.first { $0.name == "ref" }?.value, "verified-main-sha")
    let branchBody = try jsonBody(requests[3])
    XCTAssertEqual(branchBody["branch"] as? String, "draft/preview-article")
    XCTAssertEqual(branchBody["ref"] as? String, "verified-main-sha")
    XCTAssertTrue(requests[4].url?.absoluteString.contains("draft%2Fpreview-article") == true)
    XCTAssertFalse(requests.contains { $0.url?.path.contains("/repository/commits") == true })
    XCTAssertFalse(requests.contains { $0.url?.path.contains("merge_requests") == true })
  }

  func testGitLabUnchangedPreviewRejectsAHeadThatMovesAfterBranchCreation() async throws {
    let package = previewPackage(slug: "preview-article")
    let encoded = Data(try XCTUnwrap(package.markdownFile?.content).utf8).base64EncodedString()
    let transport = DraftPreviewRemoteTransport(responses: [
      response(statusCode: 404, json: #"{"message":"404 Branch Not Found"}"#),
      response(json: #"{"commit":{"id":"verified-main-sha"}}"#),
      response(
        json: """
          {"last_commit_id":"file-version","content":"\(encoded)","encoding":"base64"}
          """),
      response(json: #"{"name":"draft/preview-article","commit":{"id":"verified-main-sha"}}"#),
      response(json: #"{"commit":{"id":"moved-preview-sha"}}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)

    do {
      _ = try await service.publish(
        package: package, profile: gitLabProfile(), mode: .previewBranch, token: "secret-token")
      XCTFail("Unverified preview HEAD must not be reported as success")
    } catch {
      XCTAssertEqual(
        error as? RemoteRepositoryPublishError,
        .remoteVersionConflict(
          path: "refs/heads/draft/preview-article", expectedSHA: "verified-main-sha",
          actualSHA: "moved-preview-sha"))
    }
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "POST", "GET"])
  }

  func testGitLabPreviewRejectsEmptyTargetHeadBeforeAnyBranchWrite() async throws {
    let transport = DraftPreviewRemoteTransport(responses: [
      response(statusCode: 404, json: #"{"message":"404 Branch Not Found"}"#),
      response(json: #"{"commit":{"id":""}}"#),
    ])
    do {
      _ = try await RemoteRepositoryPublishService(transport: transport).publish(
        package: previewPackage(slug: "preview-article"), profile: gitLabProfile(),
        mode: .previewBranch, token: "secret-token")
      XCTFail("An empty target head cannot authorize preview branch creation")
    } catch {
      XCTAssertEqual(error as? RemoteRepositoryPublishError, .invalidResponse)
    }
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
  }

  func testGitHubPreviewRejectsEmptyWriteCommitInsteadOfAdoptingAnOlderHead() async throws {
    let transport = DraftPreviewRemoteTransport(responses: [
      response(json: #"{"object":{"sha":"main-sha"}}"#),
      response(json: #"{"ref":"refs/heads/draft/preview-article","object":{"sha":"main-sha"}}"#),
      response(statusCode: 404, json: #"{"message":"Not Found"}"#),
      response(json: #"{"content":{"sha":"blob-sha"},"commit":{"sha":""}}"#),
    ])
    do {
      _ = try await RemoteRepositoryPublishService(transport: transport).publish(
        package: previewPackage(slug: "preview-article"), profile: githubProfile(),
        mode: .previewBranch, token: "secret-token")
      XCTFail("A write without a commit SHA must not adopt an older branch head")
    } catch {
      XCTAssertEqual(error as? RemoteRepositoryPublishError, .invalidResponse)
    }
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "PUT"])
  }

  func testGitHubUnchangedPreviewResolvesItsDedicatedBranchHead() async throws {
    let package = previewPackage(slug: "preview-article")
    let content = Data(try XCTUnwrap(package.markdownFile?.content).utf8)
    let blobSHA = RemoteRepositoryPublishService().gitBlobSHA(for: content)
    let transport = DraftPreviewRemoteTransport(responses: [
      response(json: #"{"object":{"sha":"main-sha"}}"#),
      response(json: #"{"ref":"refs/heads/draft/preview-article","object":{"sha":"main-sha"}}"#),
      response(json: "{\"sha\":\"\(blobSHA)\"}"),
      response(json: #"{"object":{"sha":"preview-head-sha"}}"#),
    ])
    let result = try await RemoteRepositoryPublishService(transport: transport).publish(
      package: package, profile: githubProfile(), mode: .previewBranch, token: "secret-token")

    XCTAssertEqual(result.commitSHA, "preview-head-sha")
    XCTAssertTrue(result.changedPaths.isEmpty)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "GET"])
    XCTAssertEqual(
      requests.last?.url?.path, "/repos/owner/site/git/ref/heads/draft/preview-article")
  }

  func testPreviewSuccessContractRejectsMissingHeadOrTargetBranchAsPreview() {
    let valid = RemoteRepositoryPublishResult(
      provider: .gitlab, mode: .previewBranch, branchName: "draft/article", targetBranch: "main",
      changedPaths: [], commitSHA: "head-sha")
    XCTAssertNoThrow(try valid.validatedForSuccess())
    for sha in [nil, "", "   "] as [String?] {
      var invalid = valid
      invalid.commitSHA = sha
      XCTAssertThrowsError(try invalid.validatedForSuccess())
    }
    var wrongBranch = valid
    wrongBranch.branchName = "main"
    XCTAssertThrowsError(try wrongBranch.validatedForSuccess())
    wrongBranch.branchName = " "
    XCTAssertThrowsError(try wrongBranch.validatedForSuccess())
  }

  func testPreviewReleaseRecordsKeepTheDedicatedBranch() {
    let profile = githubProfile()
    let package = previewPackage(slug: "preview-article")
    let result = RemoteRepositoryPublishResult(
      provider: .github,
      mode: .previewBranch,
      branchName: "draft/preview-article",
      targetBranch: "main",
      changedPaths: [package.markdownPath],
      commitSHA: "preview-commit"
    )

    let success = ReleaseRecord.remotePublish(
      package: package,
      profile: profile,
      result: result
    )
    let failure = ReleaseRecord.remotePublishFailure(
      package: package,
      profile: profile,
      mode: .previewBranch,
      errorMessage: "failed"
    )

    XCTAssertEqual(success.kind, .remotePreviewBranch)
    XCTAssertEqual(success.branchName, "draft/preview-article")
    XCTAssertEqual(success.targetBranch, "main")
    XCTAssertTrue(success.title.contains(ReleaseRecordKind.remotePreviewBranch.displayName))
    XCTAssertEqual(
      ReleaseLedgerService().ledger(
        releaseRecords: [success],
        deploymentStatusSnapshots: [:]
      ).entries.first?.status,
      .previewOnly
    )
    XCTAssertEqual(failure.branchName, "draft/preview-article")
    XCTAssertEqual(failure.targetBranch, "main")
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

  private func previewPackage(slug: String) -> PublishPackage {
    let path = "content/posts/\(slug).md"
    return PublishPackage(
      draftID: UUID(),
      title: "Preview Article",
      markdownPath: path,
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: path,
          content: "---\ntitle = \"Preview Article\"\n---\n\nPreview body."
        )
      ],
      commitMessage: "Publish preview article",
      reviewBranchName: "publish/\(slug)-20260826",
      reviewTitle: "Preview Article",
      reviewChecklist: []
    )
  }

  private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    let body = try XCTUnwrap(request.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
  }
}

private actor DraftPreviewRemoteTransport: RemoteRepositoryHTTPTransport {
  private var responses: [DraftPreviewTransportResponse]
  private var requests: [URLRequest] = []

  init(responses: [DraftPreviewTransportResponse]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    guard !responses.isEmpty else {
      XCTFail("Unexpected remote repository request: \(request.url?.absoluteString ?? "")")
      return (
        Data(),
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
      )
    }
    let response = responses.removeFirst()
    return (
      response.data,
      HTTPURLResponse(
        url: request.url!,
        statusCode: response.statusCode,
        httpVersion: nil,
        headerFields: response.headers
      )!
    )
  }

  func capturedRequests() -> [URLRequest] {
    requests
  }
}

private struct DraftPreviewTransportResponse {
  let statusCode: Int
  let data: Data
  let headers: [String: String]
}

private func response(
  statusCode: Int = 200,
  json: String,
  headers: [String: String] = [:]
) -> DraftPreviewTransportResponse {
  DraftPreviewTransportResponse(statusCode: statusCode, data: Data(json.utf8), headers: headers)
}
