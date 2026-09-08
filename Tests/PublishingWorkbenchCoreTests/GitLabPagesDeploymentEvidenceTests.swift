import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class GitLabPagesDeploymentEvidenceTests: XCTestCase {
  func testOrdinaryPipelineAndOldPageCannotProveArticleDeployment() async {
    let (profile, record) = fixture(endpoint: nil)
    let snapshot = await DeploymentStatusService(transport: GitLabPagesEvidenceTransport()).check(
      profile: profile, releaseRecord: record, token: "test-token")
    XCTAssertEqual(snapshot.articleResults?.first?.level, .success)
    XCTAssertEqual(snapshot.platformLevel, .unknown)
    XCTAssertFalse(snapshot.verifiesArticle(record.articleVerificationTargets[0], in: record))
  }

  func testExplicitEndpointMustProveTheSameCommit() async {
    let (profile, record) = fixture(endpoint: "https://status.example.com/deployment")
    let service = DeploymentStatusService(transport: GitLabPagesEvidenceTransport())
    let snapshot = await service.check(profile: profile, releaseRecord: record, token: "test-token")
    XCTAssertEqual(snapshot.platformLevel, .success)
    XCTAssertTrue(snapshot.verifiesArticle(record.articleVerificationTargets[0], in: record))
  }

  func testExplicitEndpointForAnotherCommitCannotProveDeployment() async {
    let (profile, record) = fixture(endpoint: "https://status.example.com/deployment")
    let service = DeploymentStatusService(
      transport: GitLabPagesEvidenceTransport(endpointCommit: "other-sha"))
    let snapshot = await service.check(profile: profile, releaseRecord: record, token: "test-token")
    XCTAssertNotEqual(snapshot.platformLevel, .success)
    XCTAssertFalse(snapshot.verifiesArticle(record.articleVerificationTargets[0], in: record))
  }

  private func fixture(endpoint: String?) -> (SiteProfile, ReleaseRecord) {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.deploymentProvider = .gitlabPages
    profile.deploymentSiteURL = "https://example.com/"
    profile.deploymentStatusEndpointURL = endpoint
    let record = ReleaseRecord(
      kind: .remoteDirectCommit, title: "Article", summary: "", siteProfileID: profile.id,
      draftID: UUID(), draftTitle: "Article",
      publicPath: "/article/", publicURLText: "https://example.com/article/",
      sourceDocumentDigest: ArticleDraft.repositoryDocumentDigest("Article"),
      markdownPath: "content/posts/article.md",
      branchName: "main", targetBranch: "main",
      commitSHA: "release-sha")
    return (profile, record)
  }
}

private struct GitLabPagesEvidenceTransport: RemoteRepositoryHTTPTransport {
  var endpointCommit = "release-sha"

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try XCTUnwrap(request.url)
    let body: String
    if url.path.hasSuffix("/pipelines") {
      body = #"[{"status":"success","ref":"main","sha":"release-sha"}]"#
    } else if url.host == "status.example.com" {
      body = "{\"status\":\"success\",\"branch\":\"main\",\"commit_sha\":\"\(endpointCommit)\"}"
    } else {
      body =
        "<html><head><meta name=repopress:source-digest content=\(ArticleDraft.repositoryDocumentDigest("Article"))><link rel=canonical href=\(url.absoluteString)></head><h1>Article</h1></html>"
    }
    return (
      Data(body.utf8),
      try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    )
  }
}
