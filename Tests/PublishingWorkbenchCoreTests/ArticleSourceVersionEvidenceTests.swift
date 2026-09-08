import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class ArticleSourceVersionEvidenceTests: XCTestCase {
  private let digest = String(repeating: "a", count: 64)

  func testSameTitleOldBodyCannotCompleteCurrentRelease() async throws {
    let (profile, record) = fixture()
    let transport = VersionEvidenceTransport(digest: String(repeating: "b", count: 64))
    let snapshot = await DeploymentStatusService(transport: transport).check(
      profile: profile, releaseRecord: record)
    XCTAssertEqual(snapshot.platformLevel, .success)
    XCTAssertEqual(snapshot.level, .failed)
    XCTAssertFalse(snapshot.verifiesArticle(record.articleVerificationTargets[0], in: record))
    XCTAssertFalse(snapshot.verifiesAllArticles(in: record))
  }

  func testMissingMarkerIsUnconfirmedAndCurrentMarkerCompletesRelease() async {
    let (profile, record) = fixture()
    let transport = VersionEvidenceTransport(digest: nil)
    let service = DeploymentStatusService(transport: transport)
    let missing = await service.check(profile: profile, releaseRecord: record)
    XCTAssertEqual(missing.level, .unknown)
    XCTAssertFalse(missing.verifiesAllArticles(in: record))
    await transport.setDigest(digest)
    let current = await service.check(profile: profile, releaseRecord: record)
    XCTAssertEqual(current.level, .success)
    XCTAssertTrue(current.verifiesAllArticles(in: record))
    XCTAssertTrue(current.verifiesArticle(record.articleVerificationTargets[0], in: record))
  }

  func testBuildingWaitsWithoutFetching404ButSuccessfulBuildChecksPageFailure() async {
    let (profile, record) = fixture()
    let transport = VersionEvidenceTransport(digest: digest, status: "building", pageStatus: 404)
    let service = DeploymentStatusService(transport: transport)
    let building = await service.check(profile: profile, releaseRecord: record)
    XCTAssertEqual(building.platformLevel, .running)
    XCTAssertEqual(building.level, .running)
    XCTAssertEqual(building.articleResults?.first?.level, .running)
    let initialRequests = await transport.pageRequests
    XCTAssertEqual(initialRequests, 0)
    await transport.setStatus("success")
    let built = await service.check(profile: profile, releaseRecord: record)
    XCTAssertEqual(built.platformLevel, .success)
    XCTAssertEqual(built.level, .failed)
    await transport.setStatus("failed")
    let failed = await service.check(profile: profile, releaseRecord: record)
    XCTAssertEqual(failed.platformLevel, .failed)
    XCTAssertEqual(failed.level, .failed)
  }

  func testOnlyUniqueValidHeadMarkerCounts() {
    let marker = "<meta name='repopress:source-digest' content='\(digest)'>"
    let cases = [
      "<head><!-- \(marker) --></head>",
      "<head><script>\(marker)</script></head>",
      "<head><template>\(marker)</template></head>",
      "<head><title>\(marker)</title></head>",
      "<head></head><body>\(marker)</body>",
    ]
    for html in cases {
      XCTAssertEqual(
        ArticleSourceVersionEvidence.check(html: html, expectedDigest: digest), .missingMarker)
    }
    XCTAssertEqual(
      ArticleSourceVersionEvidence.check(
        html: "<head>\(marker)\(marker)</head>", expectedDigest: digest),
      .invalidMarker)
    XCTAssertEqual(
      ArticleSourceVersionEvidence.check(
        html: "<head><meta name=repopress:source-digest content=bad></head>", expectedDigest: digest
      ),
      .invalidMarker)
    XCTAssertEqual(
      ArticleSourceVersionEvidence.check(
        html: "<HEAD>\(marker)</HEAD>", expectedDigest: digest.uppercased()),
      .verified(digest))
    XCTAssertEqual(
      ArticleSourceVersionEvidence.check(html: "<head>\(marker)</head>", expectedDigest: nil),
      .missingExpectedDigest)
  }

  func testScriptComparisonsDoNotHideRealVersionEvidence() async {
    let (profile, record) = fixture()
    let transport = VersionEvidenceTransport(
      digest: digest,
      headPrefix: "<script>if(a<b){console.log(a)}</SCRIPT >")
    let snapshot = await DeploymentStatusService(transport: transport).check(
      profile: profile, releaseRecord: record)
    XCTAssertEqual(snapshot.level, .success)
    XCTAssertTrue(snapshot.verifiesAllArticles(in: record))
  }

  func testNestedTemplateMarkerCannotCompleteRelease() async {
    let (profile, record) = fixture()
    let marker = "<meta name=repopress:source-digest content=\(digest)>"
    let template = "<template><template></template>\(marker)</template>"
    let transport = VersionEvidenceTransport(digest: nil, headPrefix: template)
    let snapshot = await DeploymentStatusService(transport: transport).check(
      profile: profile, releaseRecord: record)
    XCTAssertEqual(snapshot.level, .unknown)
    XCTAssertFalse(snapshot.verifiesAllArticles(in: record))
    await transport.setDigest(digest)
    let withRealMarker = await DeploymentStatusService(transport: transport).check(
      profile: profile, releaseRecord: record)
    XCTAssertEqual(withRealMarker.level, .success)
    XCTAssertTrue(withRealMarker.verifiesAllArticles(in: record))
  }

  func testRawClosingTagsRequireExactNamesAndTemplateDepthIgnoresScriptText() {
    let marker = "<meta name=repopress:source-digest content=\(digest)>"
    let html = """
      <head><template><template><script>const s = '</template>'; if(a<b){}</script>
      </template>\(marker)</template>
      <script></script-not-real>\(marker)</script>
      </head>
      """
    XCTAssertEqual(
      ArticleSourceVersionEvidence.check(html: html, expectedDigest: digest), .missingMarker)
    XCTAssertEqual(
      ArticleSourceVersionEvidence.check(
        html: "<head><meta! name=repopress:source-digest content=\(digest)></head>",
        expectedDigest: digest), .missingMarker)
  }

  func testLegacySuccessSignalCannotProveSourceVersionAfterDecode() throws {
    let (_, record) = fixture()
    let signal = DeploymentStatusSignal(level: .success, title: "Page", message: "Title matched")
    let loaded = try JSONDecoder().decode(
      DeploymentStatusSignal.self, from: JSONEncoder().encode(signal))
    XCTAssertNil(loaded.verifiedSourceDocumentDigest)
    let result = DeploymentArticleVerificationResult(
      target: record.articleVerificationTargets[0], signals: [loaded])
    XCTAssertFalse(result.verifiesSourceVersion)
  }

  private func fixture() -> (SiteProfile, ReleaseRecord) {
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://example.com/"
    profile.deploymentStatusEndpointURL = "https://example.com/status"
    let record = ReleaseRecord(
      kind: .remoteDirectCommit, title: "Article", summary: "", siteProfileID: profile.id,
      draftID: UUID(), draftTitle: "Article", publicPath: "/article/",
      publicURLText: "https://example.com/article/", sourceDocumentDigest: digest,
      markdownPath: "content/article.md", branchName: "main", targetBranch: "main",
      commitSHA: "release-sha")
    return (profile, record)
  }
}

private actor VersionEvidenceTransport: RemoteRepositoryHTTPTransport {
  var pageRequests = 0
  var digest: String?
  var status: String
  let pageStatus: Int
  let headPrefix: String
  init(digest: String?, status: String = "success", pageStatus: Int = 200, headPrefix: String = "") {
    self.digest = digest
    self.status = status
    self.pageStatus = pageStatus
    self.headPrefix = headPrefix
  }
  func setDigest(_ value: String?) { digest = value }
  func setStatus(_ value: String) { status = value }
  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try XCTUnwrap(request.url)
    let body: String
    let code: Int
    if url.path == "/status" {
      body = "{\"status\":\"\(status)\",\"branch\":\"main\",\"commit_sha\":\"release-sha\"}"
      code = 200
    } else {
      pageRequests += 1
      let marker = digest.map { "<meta name=repopress:source-digest content=\($0)>" } ?? ""
      body =
        "<html><head>\(headPrefix)\(marker)<link rel=canonical href=\(url.absoluteString)></head><body><h1>Article</h1>Body</body></html>"
      code = pageStatus
    }
    return (
      Data(body.utf8),
      try XCTUnwrap(
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil))
    )
  }
}
