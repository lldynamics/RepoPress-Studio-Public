import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class GitHubArticleDeploymentVerificationTests: XCTestCase {
  func testCheckDoesNotTreatCIAndOldArticlePageAsCurrentGitHubPagesDeployment() async {
    let articleURL = "https://example.com/posts/article/"
    let site = profile()
    let transport = GitHubDeploymentTransport(responses: [
      .json(#"{"status":"built"}"#),
      .json(
        #"{"workflow_runs":[{"status":"completed","conclusion":"success","head_branch":"main","head_sha":"abcdef123456"}]}"#
      ),
      .json("[]"),
      .html("<html><body>site is reachable</body></html>"),
      .html(
        """
        <html><head><link rel="canonical" href="\(articleURL)">
        <meta property="og:title" content="Article title">
        </head><body>Article title</body></html>
        """
      ),
    ])
    var release = record()
    release.siteProfileID = site.id
    release.markdownPath = "content/posts/article.md"
    release.draftTitle = "Article title"
    release.publicURLText = articleURL

    let snapshot = await DeploymentStatusService(transport: transport).check(
      profile: site, releaseRecord: release, token: "token")

    XCTAssertEqual(snapshot.platformLevel, .unknown)
    XCTAssertEqual(snapshot.articleResults?.first?.level, .unknown)
    XCTAssertEqual(snapshot.level, .unknown)
    XCTAssertFalse(snapshot.verifiesArticle(release.articleVerificationTargets[0], in: release))
    XCTAssertEqual(
      snapshot.signals.first(where: { $0.title == "GitHub Pages Deployment" })?.level,
      .unknown
    )
  }

  func testCurrentGitHubPagesDeploymentSuccessRequiresBothEndpoints() async {
    let transport = GitHubDeploymentTransport(responses: [
      .json(
        #"[{"id":42,"sha":"ABCDEF123456","ref":"main","environment":"github-pages","transient_environment":false}]"#
      ),
      .json(#"[{"state":"success"}]"#),
    ])
    let service = DeploymentStatusService(transport: transport)
    let signal = await service.githubArticleDeploymentSignal(
      profile: profile(), releaseRecord: record(), token: "token")

    XCTAssertEqual(signal.level, .success)
    XCTAssertEqual(signal.attributionVerified, true)
    let requests = await transport.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0].url?.path, "/repos/owner/site/deployments")
    XCTAssertEqual(requests[0].url?.queryValue(named: "sha"), "abcdef123456")
    XCTAssertEqual(requests[0].url?.queryValue(named: "environment"), "github-pages")
    XCTAssertEqual(requests[1].url?.path, "/repos/owner/site/deployments/42/statuses")
    XCTAssertEqual(requests[1].url?.queryValue(named: "per_page"), "1")
  }

  func testMissingOrOrdinaryDeploymentCannotProveArticleIsLive() async {
    let missingTransport = GitHubDeploymentTransport(responses: [.json("[]")])
    let missing = await DeploymentStatusService(transport: missingTransport)
      .githubArticleDeploymentSignal(
        profile: profile(), releaseRecord: record(), token: "token")
    XCTAssertEqual(missing.level, .unknown)
    XCTAssertEqual(missing.attributionVerified, false)
    let missingRequests = await missingTransport.requests()
    let missingRequestCount = missingRequests.count
    XCTAssertEqual(missingRequestCount, 1)

    let ordinaryCITransport = GitHubDeploymentTransport(responses: [
      .json(
        #"[{"id":43,"sha":"abcdef123456","ref":"main","environment":"production","transient_environment":false}]"#
      )
    ])
    let ordinaryCI = await DeploymentStatusService(transport: ordinaryCITransport)
      .githubArticleDeploymentSignal(profile: profile(), releaseRecord: record(), token: "token")
    XCTAssertEqual(ordinaryCI.level, .unknown)
    XCTAssertEqual(ordinaryCI.attributionVerified, false)
    let ordinaryCIRequests = await ordinaryCITransport.requests()
    let ordinaryCIRequestCount = ordinaryCIRequests.count
    XCTAssertEqual(ordinaryCIRequestCount, 1)
  }

  func testInactiveOrPendingCurrentDeploymentCannotReuseOlderSuccess() async {
    for state in ["inactive", "pending", "failure"] {
      let transport = GitHubDeploymentTransport(responses: [
        .json(
          #"[{"id":44,"sha":"abcdef123456","ref":"main","environment":"github-pages","transient_environment":false}]"#
        ),
        .json(#"[{"state":"\#(state)"},{"state":"success"}]"#),
      ])
      let signal = await DeploymentStatusService(transport: transport)
        .githubArticleDeploymentSignal(
          profile: profile(), releaseRecord: record(), token: "token")
      switch state {
      case "inactive":
        XCTAssertEqual(signal.level, .unknown)
      case "pending":
        XCTAssertEqual(signal.level, .running)
      case "failure":
        XCTAssertEqual(signal.level, .failed)
      default:
        XCTFail("Unexpected deployment state")
      }
      let requests = await transport.requests()
      let requestCount = requests.count
      XCTAssertEqual(requestCount, 2)
    }
  }

  func testWrongSHAEnvironmentOrRefFailsClosed() async {
    let deployments = [
      #"[{"id":45,"sha":"wrong","ref":"main","environment":"github-pages","transient_environment":false}]"#,
      #"[{"id":45,"sha":"abcdef123456","ref":"main","environment":"staging","transient_environment":false}]"#,
      #"[{"id":45,"sha":"abcdef123456","ref":"other","environment":"github-pages","transient_environment":false}]"#,
      #"[{"id":45,"sha":"abcdef123456","ref":"main","environment":"github-pages","transient_environment":true}]"#,
    ]
    for deployment in deployments {
      let transport = GitHubDeploymentTransport(responses: [.json(deployment)])
      let signal = await DeploymentStatusService(transport: transport)
        .githubArticleDeploymentSignal(
          profile: profile(), releaseRecord: record(), token: "token")
      XCTAssertEqual(signal.level, .unknown)
      XCTAssertEqual(signal.attributionVerified, false)
      let requests = await transport.requests()
      let requestCount = requests.count
      XCTAssertEqual(requestCount, 1)
    }
  }

  func testHTTPFailureFailsClosed() async {
    let transport = GitHubDeploymentTransport(responses: [.http(statusCode: 500, body: "{}")])
    let signal = await DeploymentStatusService(transport: transport).githubArticleDeploymentSignal(
      profile: profile(), releaseRecord: record(), token: "token")
    XCTAssertEqual(signal.level, .unknown)
    XCTAssertEqual(signal.attributionVerified, false)
  }

  private func profile() -> SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryBaseURL = "https://api.github.com"
    return profile
  }

  private func record() -> ReleaseRecord {
    ReleaseRecord(title: "发布", summary: "test", branchName: "main", commitSHA: "abcdef123456")
  }
}

private actor GitHubDeploymentTransport: RemoteRepositoryHTTPTransport {
  enum Response {
    case json(String)
    case html(String)
    case http(statusCode: Int, body: String)
  }

  private var responses: [Response]
  private var receivedRequests: [URLRequest] = []

  init(responses: [Response]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    receivedRequests.append(request)
    guard !responses.isEmpty else { throw URLError(.badServerResponse) }
    let response = responses.removeFirst()
    let statusCode: Int
    let body: String
    switch response {
    case .json(let value):
      statusCode = 200
      body = value
    case .html(let value):
      statusCode = 200
      body = value
    case .http(let value, let responseBody):
      statusCode = value
      body = responseBody
    }
    guard let url = request.url,
      let httpResponse = HTTPURLResponse(
        url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
    else { throw URLError(.badServerResponse) }
    return (Data(body.utf8), httpResponse)
  }

  func requests() -> [URLRequest] {
    receivedRequests
  }
}

extension URL {
  fileprivate func queryValue(named name: String) -> String? {
    URLComponents(url: self, resolvingAgainstBaseURL: false)?
      .queryItems?.first(where: { $0.name == name })?.value
  }
}
