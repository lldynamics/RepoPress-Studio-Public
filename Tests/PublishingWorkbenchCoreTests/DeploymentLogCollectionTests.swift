import Foundation
import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class DeploymentLogCollectionTests: XCTestCase {
  func testLegacySignalJSONDecodesWithoutLogExcerpt() throws {
    let id = UUID()
    let data = try JSONSerialization.data(withJSONObject: [
      "id": id.uuidString,
      "level": "failed",
      "title": "GitHub Actions",
      "message": "Build failed",
    ])

    let signal = try JSONDecoder().decode(DeploymentStatusSignal.self, from: data)

    XCTAssertEqual(signal.id, id)
    XCTAssertEqual(signal.level, .failed)
    XCTAssertTrue(signal.logExcerpt.isEmpty)
  }

  func testLogExcerptIsBoundedAndRedactedAtTheModelBoundary() {
    let entries = (0..<40).map { index in
      DeploymentLogEntry(
        level: .error,
        source: "provider",
        message: "Authorization: Bearer secret-\(index)"
      )
    }

    let signal = DeploymentStatusSignal(
      level: .failed,
      title: "Build",
      message: "Build failed",
      logExcerpt: entries
    )

    XCTAssertEqual(signal.logExcerpt.count, 32)
    XCTAssertTrue(signal.logExcerpt.allSatisfy { !$0.message.contains("secret-") })
    XCTAssertTrue(signal.logExcerpt.allSatisfy { !$0.message.localizedCaseInsensitiveContains("authorization") })
  }

  func testFailedGitHubRunCollectsFailedStepAndCheckAnnotation() async throws {
    let transport = DeploymentLogTestTransport(responses: [
      deploymentLogResponse(json: #"{"status":"built","html_url":"https://owner.github.io/site/"}"#),
      deploymentLogResponse(json: #"{"workflow_runs":[{"id":123,"name":"Deploy Pages","status":"completed","conclusion":"failure","html_url":"https://github.com/owner/site/actions/runs/123"}]}"#),
      deploymentLogResponse(json: #"{"jobs":[{"id":456,"name":"Build site","status":"completed","conclusion":"failure","check_run_url":"https://api.github.com/repos/owner/site/check-runs/789","steps":[{"number":1,"name":"Build SSG","status":"completed","conclusion":"failure"}]}]}"#),
      deploymentLogResponse(json: #"[{"path":"content/posts/article.md","start_line":42,"start_column":3,"annotation_level":"failure","message":"SSG compile error: missing front matter"}]"#),
      deploymentLogResponse(json: #"{"ok":true}"#),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.deploymentProvider = .githubPages
    profile.deploymentSiteURL = "https://owner.github.io/site/"

    let snapshot = await service.check(profile: profile, token: "github-token")

    let signal = try XCTUnwrap(snapshot.signals.first(where: { $0.title == "Deploy Pages" }))
    XCTAssertEqual(signal.level, .failed)
    XCTAssertEqual(signal.logExcerpt.count, 2)
    XCTAssertTrue(signal.logExcerpt.contains(where: {
      $0.level == .error && $0.stepName == "Build SSG" && $0.message.contains("步骤 Build SSG")
    }))
    let annotation = try XCTUnwrap(signal.logExcerpt.first(where: { $0.filePath != nil }))
    XCTAssertEqual(annotation.filePath, "content/posts/article.md")
    XCTAssertEqual(annotation.line, 42)
    XCTAssertEqual(annotation.column, 3)
    XCTAssertTrue(annotation.message.contains("SSG compile error"))

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map { $0.url?.path }, [
      "/repos/owner/site/pages",
      "/repos/owner/site/actions/runs",
      "/repos/owner/site/actions/runs/123/jobs",
      "/repos/owner/site/check-runs/789/annotations",
      "/site",
    ])
    XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
    XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
  }

  func testFailedVercelDeploymentParsesEventsAndRedactsCredentials() async throws {
    let transport = DeploymentLogTestTransport(responses: [
      deploymentLogResponse(json: #"{"deployments":[{"uid":"dpl_123","name":"personal-site","readyState":"ERROR","target":"preview","inspectorUrl":"https://vercel.com/team/personal-site/dpl_123","errorMessage":"Build failed","meta":{"githubCommitRef":"draft/preview-article","githubCommitSha":"abc123"}}]}"#),
      deploymentLogResponse(json: #"[{"type":"stdout","payload":{"text":"starting build"}},{"type":"stderr","payload":{"text":"SSG failed at content/index.md:12:4"}},{"type":"fatal","message":"Authorization: Bearer very-secret-token"},{"type":"exit","payload":{"code":1}}]"#),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .vercel
    profile.deploymentProjectID = "prj_123"
    profile.deploymentAccountID = "team_456"
    profile.branch = "main"

    let releaseRecord = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "Preview",
      summary: "Preview branch",
      branchName: "draft/preview-article",
      targetBranch: "main"
    )
    let snapshot = await service.check(
      profile: profile,
      releaseRecord: releaseRecord,
      token: "vercel-token"
    )

    let signal = try XCTUnwrap(snapshot.signals.first)
    XCTAssertEqual(snapshot.level, .failed)
    XCTAssertEqual(signal.level, .failed)
    XCTAssertEqual(signal.logExcerpt.count, 4)
    XCTAssertTrue(signal.logExcerpt.contains(where: { $0.message == "starting build" }))
    let compilerEntry = try XCTUnwrap(signal.logExcerpt.first(where: { $0.message.contains("SSG failed") }))
    XCTAssertEqual(compilerEntry.filePath, "content/index.md")
    XCTAssertEqual(compilerEntry.line, 12)
    XCTAssertEqual(compilerEntry.column, 4)
    let redactedEntry = try XCTUnwrap(signal.logExcerpt.first(where: { $0.source.contains("fatal") }))
    XCTAssertFalse(redactedEntry.message.contains("very-secret-token"))
    XCTAssertFalse(redactedEntry.message.localizedCaseInsensitiveContains("authorization"))
    XCTAssertTrue(snapshot.clipboardSummary.contains("SSG failed"))
    XCTAssertFalse(snapshot.clipboardSummary.contains("very-secret-token"))

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[1].url?.path, "/v3/deployments/dpl_123/events")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer vercel-token")
    let queryItems = URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "direction", value: "backward")))
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "follow", value: "0")))
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "limit", value: "100")))
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "teamId", value: "team_456")))
    let deploymentQueryItems = URLComponents(
      url: try XCTUnwrap(requests[0].url),
      resolvingAgainstBaseURL: false
    )?.queryItems ?? []
    XCTAssertTrue(deploymentQueryItems.contains(URLQueryItem(name: "target", value: "preview")))
  }

  func testLogRequestFailurePreservesDeploymentStatus() async throws {
    let transport = DeploymentLogTestTransport(responses: [
      deploymentLogResponse(json: #"{"deployments":[{"uid":"dpl_failed","name":"personal-site","readyState":"ERROR","target":"production","errorMessage":"SSG failed"}]}"#),
      deploymentLogResponse(statusCode: 503, json: #"{"error":"logs unavailable"}"#),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .vercel
    profile.deploymentProjectID = "prj_123"

    let snapshot = await service.check(profile: profile, token: "vercel-token")

    XCTAssertEqual(snapshot.level, .failed)
    XCTAssertEqual(snapshot.signals.first?.level, .failed)
    XCTAssertTrue(snapshot.signals.first?.logExcerpt.isEmpty == true)
    XCTAssertTrue(snapshot.signals.first?.message.contains("SSG failed") == true)
  }
}

private actor DeploymentLogTestTransport: RemoteRepositoryHTTPTransport {
  private var responses: [DeploymentLogTestResponse]
  private var requests: [URLRequest] = []

  init(responses: [DeploymentLogTestResponse]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    guard !responses.isEmpty else {
      throw DeploymentLogTestError.unexpectedRequest(request.url?.absoluteString ?? "")
    }
    let response = responses.removeFirst()
    guard let url = request.url,
          let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: nil
          ) else {
      throw DeploymentLogTestError.invalidResponse
    }
    return (response.data, httpResponse)
  }

  func capturedRequests() -> [URLRequest] {
    requests
  }
}

private enum DeploymentLogTestError: Error {
  case unexpectedRequest(String)
  case invalidResponse
}

private struct DeploymentLogTestResponse {
  var statusCode: Int
  var data: Data
}

private func deploymentLogResponse(statusCode: Int = 200, json: String) -> DeploymentLogTestResponse {
  DeploymentLogTestResponse(statusCode: statusCode, data: Data(json.utf8))
}
