import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class DeploymentArticleVerificationTests: XCTestCase {
  func testBatchFailureRetainsPerArticleEvidenceAndRetriesOnlySelectedPage() async throws {
    let (profile, record) = fixture()
    let transport = ArticleVerificationTransport(failingPaths: ["/second/"])
    let service = DeploymentStatusService(transport: transport)
    let first = await service.check(profile: profile, releaseRecord: record)
    XCTAssertEqual(first.platformLevel, .success)
    XCTAssertEqual(first.level, .failed)
    XCTAssertEqual(first.articleResults?.map(\.level), [.success, .failed])
    XCTAssertTrue(first.verifiesArticle(record.batchItems[0], in: record))
    XCTAssertFalse(first.verifiesAllArticles(in: record))
    await transport.setFailingPaths([])
    let retried = await service.check(
      profile: profile, releaseRecord: record,
      articleDraftID: record.batchItems[1].draftID, previousSnapshot: first)
    let paths = await transport.paths()
    XCTAssertEqual(paths, ["/status", "/first/", "/second/", "/status", "/second/"])
    XCTAssertEqual(retried.level, .success)
    XCTAssertEqual(retried.articleResults?.first, first.articleResults?.first)
    XCTAssertTrue(retried.verifiesAllArticles(in: record))
  }

  func testChangedCommitCannotReuseOtherArticleResults() async {
    let (profile, record) = fixture()
    let transport = ArticleVerificationTransport()
    let service = DeploymentStatusService(transport: transport)
    let first = await service.check(profile: profile, releaseRecord: record)
    var changed = record
    changed.commitSHA = "different"
    await transport.setCommit("different")
    let next = await service.check(
      profile: profile, releaseRecord: changed,
      articleDraftID: record.batchItems[1].draftID, previousSnapshot: first)
    XCTAssertEqual(next.articleResults?.first?.level, .unknown)
    XCTAssertFalse(next.verifiesAllArticles(in: changed))
  }

  func testFreshPlatformMismatchCannotPublishReusedPages() async {
    let (profile, record) = fixture()
    let transport = ArticleVerificationTransport()
    let service = DeploymentStatusService(transport: transport)
    let first = await service.check(profile: profile, releaseRecord: record)
    await transport.setCommit("unrelated")
    let next = await service.check(
      profile: profile, releaseRecord: record,
      articleDraftID: record.batchItems[1].draftID, previousSnapshot: first)
    XCTAssertFalse(next.verifiesArticle(record.batchItems[0], in: record))
    XCTAssertFalse(next.attributionVerified == true)
  }

  func testMissingSiteURLDoesNotOmitBatchPages() async {
    var (profile, record) = fixture()
    profile.deploymentSiteURL = nil
    record.batchItems = record.batchItems.map {
      var item = $0
      item.publicURLText = nil
      return item
    }
    let result = await DeploymentStatusService(transport: ArticleVerificationTransport()).check(
      profile: profile, releaseRecord: record)
    XCTAssertEqual(result.articleResults?.count, 2)
    XCTAssertEqual(result.level, .unknown)
  }

  func testEndpointHTTPFailureCannotBeOverriddenBySuccessJSON() async {
    let (profile, record) = fixture()
    let transport = ArticleVerificationTransport(endpointStatusCode: 500)
    let snapshot = await DeploymentStatusService(transport: transport).check(
      profile: profile, releaseRecord: record)

    XCTAssertEqual(snapshot.platformLevel, .failed)
    XCTAssertEqual(snapshot.articleResults?.map(\.level), [.success, .success])
    XCTAssertFalse(snapshot.verifiesArticle(record.batchItems[0], in: record))
    XCTAssertFalse(snapshot.attributionVerified == true)
  }

  func testLegacyRecordWithoutDraftIDStillChecksPageAndOldSnapshotCannotCompleteIt() async throws {
    let (profile, batch) = fixture()
    let record = ReleaseRecord(
      kind: .remoteDirectCommit, title: "Legacy", summary: "",
      siteProfileID: profile.id, draftTitle: "first", markdownPath: "content/posts/first.md",
      branchName: "main", targetBranch: "main", commitSHA: "release-sha")
    let transport = ArticleVerificationTransport(failingPaths: ["/first/"])
    let result = await DeploymentStatusService(transport: transport).check(
      profile: profile, releaseRecord: record)
    XCTAssertEqual(result.articleResults?.count, 1)
    XCTAssertEqual(result.level, .failed)
    var legacy = result
    legacy.level = .success
    legacy.attributionVerified = true
    legacy.articleResults = nil
    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [record, batch], deploymentStatusSnapshots: [record.id: legacy])
    XCTAssertNil(ledger.entries.first?.deploymentStatus)
  }

  func testFrozenRouteSurvivesDraftAndProfileChangesAndCodableRoundTrip() throws {
    var profile = SiteProfile.defaultProfile
    profile.contentRoot = "articles"
    profile.markdownPathPattern = "articles/{slug}.md"
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://old.example/base/"
    var draft = ArticleDraft(
      siteProfileID: profile.id, title: "Example", slug: "example", bodyMarkdown: "Body")
    draft.permalink = "/custom/entry/"
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    XCTAssertEqual(package.publicPath, "/custom/entry/")
    XCTAssertEqual(package.publicURLText, "https://old.example/base/custom/entry/")
    XCTAssertEqual(
      package.sourceDocumentDigest, draft.renderedRepositoryContentDigest(profile: profile))
    let record = ReleaseRecord.localWrite(
      package: package, profile: profile, writtenPaths: [package.markdownPath])
    let loaded = try JSONDecoder().decode(ReleaseRecord.self, from: JSONEncoder().encode(record))
    profile.deploymentSiteURL = "https://new.example/"
    draft.permalink = "/changed/"
    XCTAssertEqual(loaded.publicURLText, "https://old.example/base/custom/entry/")
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    for key in ["publicPath", "publicURLText", "sourceDocumentDigest"] {
      object.removeValue(forKey: key)
    }
    let legacy = try JSONDecoder().decode(
      ReleaseRecord.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(legacy.publicPath)
  }

  func testOnlyVerifiedUnchangedArticleMovesToPublished() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let profile = store.activeProfile
    let first = ArticleDraft(
      siteProfileID: profile.id, title: "first", slug: "first", draft: false, bodyMarkdown: "first",
      status: .ready)
    let second = ArticleDraft(
      siteProfileID: profile.id, title: "second", slug: "second", draft: false,
      bodyMarkdown: "second", status: .ready)
    store.setDrafts([first, second])
    var record = ReleaseRecord(
      kind: .remoteDirectCommit, title: "Batch", summary: "", siteProfileID: profile.id,
      branchName: "main", targetBranch: "main", commitSHA: "release-sha")
    record.batchItems = [first, second].map { draft in
      let package = PublishPackageBuilder().build(draft: draft, profile: profile)
      return ReleaseRecordBatchItem(
        draftID: draft.id, draftTitle: draft.title, markdownPath: package.markdownPath,
        publicPath: package.publicPath, publicURLText: package.publicURLText,
        sourceDocumentDigest: package.sourceDocumentDigest, changedPaths: [package.markdownPath])
    }
    let results = record.batchItems.enumerated().map { index, target in
      DeploymentArticleVerificationResult(
        target: target,
        signals: [
          DeploymentStatusSignal(
            level: index == 0 ? .success : .failed, title: "Page", message: "",
            verifiedSourceDocumentDigest: index == 0 ? target.sourceDocumentDigest : nil)
        ])
    }
    let snapshot = DeploymentStatusSnapshot(
      profileID: profile.id, releaseRecordID: record.id, provider: .custom,
      level: .failed, title: "Partial", message: "", siteURLText: nil, signals: [],
      expectedBranch: "main", expectedCommitSHA: "release-sha", attributionVerified: true,
      platformLevel: .success, articleResults: results)
    store.markVerifiedArticlesAsPublished(record: record, snapshot: snapshot, profile: profile)
    XCTAssertEqual(store.draft(for: first.id)?.status, .published)
    XCTAssertEqual(store.draft(for: second.id)?.status, .ready)
    var edited = first
    edited.bodyMarkdown += " edited"
    store.setDrafts([edited, second])
    store.markVerifiedArticlesAsPublished(record: record, snapshot: snapshot, profile: profile)
    XCTAssertEqual(store.draft(for: first.id)?.status, .ready)
    store.setDrafts([first, second])
    let buffer = store.draftBodyEditorBuffer(for: first.id)
    _ = store.stageDraftBody("unsaved", for: first.id, baseRevision: buffer.revision)
    store.markVerifiedArticlesAsPublished(record: record, snapshot: snapshot, profile: profile)
    XCTAssertEqual(store.draft(for: first.id)?.status, .ready)
  }

  func testHTMLMetadataAcceptsQuotesUnquotedEntitiesAndExactNames() {
    let service = DeploymentStatusService()
    let html =
      #"<!-- <meta property=og:url content=bad> --><script>"<meta property=og:url content=bad>"</script><META data-property=og:url content=bad><MeTa PROPERTY=og:url CONTENT=https://example.com/a?x=1&amp;y=2><link rel='canonical' href="https://example.com/a?x=1&#38;y=2"><meta property=og:title content="A > B &#x4e2d;&#25991;">"#
    XCTAssertEqual(
      service.firstMetaContent(in: html, nameOrProperty: "og:url"), "https://example.com/a?x=1&y=2")
    XCTAssertEqual(service.firstMetaContent(in: html, nameOrProperty: "og:title"), "A > B 中文")
    XCTAssertEqual(
      service.articlePageSEOSignal(body: html, expectedURLText: "https://example.com/a?x=1&y=2")
        .level, .success)
    XCTAssertNil(
      service.firstMetaContent(
        in: "<meta data-property='og:title' content='bad'>", nameOrProperty: "og:title"))
  }

  func testFinalConflictDocumentRefreshesFrozenTitleRouteAndDigest() throws {
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = try temporaryDirectoryURL().path
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://example.com/"
    let original = ArticleDraft(
      siteProfileID: profile.id, title: "Original", slug: "original", bodyMarkdown: "Original body")
    let package = PublishPackageBuilder().build(draft: original, profile: profile)
    var resolved = original
    resolved.title = "Merged title"
    resolved.bodyMarkdown = "Merged body"
    resolved.permalink = "/merged-route/"
    var files = package.files
    let index = try XCTUnwrap(
      files.firstIndex(where: { $0.kind == .markdown && $0.operation == .upsert }))
    files[index].content = FrontMatterRenderer().renderDocument(draft: resolved, profile: profile)
    let frozen = package.freezingArticleVerification(finalFiles: files, profile: profile)
    XCTAssertEqual(frozen.title, "Merged title")
    XCTAssertEqual(frozen.publicPath, "/merged-route/")
    XCTAssertEqual(frozen.publicURLText, "https://example.com/merged-route/")
    XCTAssertEqual(
      frozen.sourceDocumentDigest, resolved.renderedRepositoryContentDigest(profile: profile))
  }

  private func fixture() -> (SiteProfile, ReleaseRecord) {
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://example.com/"
    profile.deploymentStatusEndpointURL = "https://example.com/status"
    let items = ["first", "second"].map { title in
      ReleaseRecordBatchItem(
        draftID: UUID(), draftTitle: title, markdownPath: "content/posts/\(title).md",
        publicPath: "/\(title)/", publicURLText: "https://example.com/\(title)/",
        sourceDocumentDigest: ArticleDraft.repositoryDocumentDigest(title), changedPaths: [])
    }
    return (
      profile,
      ReleaseRecord(
        kind: .remoteDirectCommit, title: "Batch", summary: "", siteProfileID: profile.id,
        branchName: "main", targetBranch: "main", commitSHA: "release-sha", batchItems: items)
    )
  }
}

private actor ArticleVerificationTransport: RemoteRepositoryHTTPTransport {
  private var requestedPaths: [String] = []
  private var failingPaths: Set<String>
  private var commit = "release-sha"
  private let endpointStatusCode: Int
  init(failingPaths: Set<String> = [], endpointStatusCode: Int = 200) {
    self.failingPaths = failingPaths
    self.endpointStatusCode = endpointStatusCode
  }
  func setFailingPaths(_ paths: Set<String>) { failingPaths = paths }
  func setCommit(_ value: String) { commit = value }
  func paths() -> [String] { requestedPaths }
  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try XCTUnwrap(request.url)
    requestedPaths.append(
      url.path.hasSuffix("/") || url.path == "/status" ? url.path : url.path + "/")
    let path = requestedPaths.last ?? ""
    let body =
      path == "/status"
      ? "{\"status\":\"success\",\"branch\":\"main\",\"commit_sha\":\"\(commit)\"}"
      : "<html><head><meta name=repopress:source-digest content=\(ArticleDraft.repositoryDocumentDigest(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))><link rel=canonical href=\(url.absoluteString)></head><h1>\(path)</h1></html>"
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: url,
        statusCode: path == "/status"
          ? endpointStatusCode : (failingPaths.contains(path) ? 404 : 200),
        httpVersion: nil,
        headerFields: nil))
    return (Data(body.utf8), response)
  }
}
