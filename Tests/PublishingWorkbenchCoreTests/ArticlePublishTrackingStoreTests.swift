import Foundation
import PublishingDomainContracts
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class ArticlePublishTrackingStoreTests: XCTestCase {
  func testAutomaticFollowupWorksWithSitePollingDisabledAndPersistsCompletion() async throws {
    let (store, transport, url) = try fixture()
    defer { stop(store) }
    let record = trackedRecord(store)
    store.setReleaseRecords([record])

    let didRun = await store.deploymentStore.tickArticlePublishTracking(store: store, now: Date())

    XCTAssertTrue(didRun)
    XCTAssertFalse(store.deploymentPollingSettings.isEnabled)
    let completed = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertEqual(store.articlePublishProgress(for: completed)?.phase, .online)
    XCTAssertNotNil(completed.articlePublishTrackingRequest?.completedSnapshot)
    XCTAssertFalse(store.hasPendingArticlePublishTracking)
    let requests = await transport.requests()
    XCTAssertTrue(requests.contains { $0.url?.path == "/status" })
    XCTAssertTrue(
      requests.contains {
        $0.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "article"
      })

    await store.waitForPendingSave()
    let restored = makeStore(url: url, transport: transport)
    defer { stop(restored) }
    let restoredRecord = try XCTUnwrap(restored.releaseRecords.first)
    let restoredRequest = try XCTUnwrap(restoredRecord.articlePublishTrackingRequest)
    let originalRequest = try XCTUnwrap(completed.articlePublishTrackingRequest)
    XCTAssertEqual(restoredRequest.target, originalRequest.target)
    XCTAssertEqual(
      restoredRequest.startedAt.timeIntervalSince1970,
      originalRequest.startedAt.timeIntervalSince1970, accuracy: 1)
    XCTAssertEqual(
      restoredRequest.deadline.timeIntervalSince1970,
      originalRequest.deadline.timeIntervalSince1970, accuracy: 1)
    XCTAssertEqual(restoredRequest.completedSnapshot?.id, originalRequest.completedSnapshot?.id)
    XCTAssertEqual(restored.articlePublishProgress(for: restoredRecord)?.phase, .online)
    let before = await transport.requests().count
    let ranAgain = await restored.deploymentStore.tickArticlePublishTracking(
      store: restored, now: Date())
    XCTAssertFalse(ranAgain)
    let after = await transport.requests().count
    XCTAssertEqual(before, after)
  }

  func testCompletedTaskSurvivesLaterUnknownCheckUntilExplicitRecheck() async throws {
    let (store, transport, _) = try fixture()
    defer { stop(store) }
    store.setReleaseRecords([trackedRecord(store)])
    _ = await store.deploymentStore.tickArticlePublishTracking(store: store, now: Date())
    let completed = try XCTUnwrap(store.releaseRecords.first)
    await transport.setMode(.offline)
    _ = await store.refreshDeploymentStatus(for: completed)
    XCTAssertEqual(
      store.articlePublishProgress(for: try XCTUnwrap(store.releaseRecords.first))?.phase, .online)

    await store.recheckArticlePublication(completed)
    let renewed = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertNil(renewed.articlePublishTrackingRequest?.completedSnapshot)
    XCTAssertTrue(store.articlePublishProgress(for: renewed)?.isPending == true)
    XCTAssertEqual(renewed.commitSHA, completed.commitSHA)
    XCTAssertEqual(renewed.sourceDocumentDigest, completed.sourceDocumentDigest)
    XCTAssertEqual(store.releaseRecords.count, 1)
  }

  func testPendingRequestResumesAfterReloadWithoutChangingPollingPreference() async throws {
    let (store, transport, url) = try fixture()
    defer { stop(store) }
    let record = trackedRecord(store)
    store.setReleaseRecords([record])
    store.save()
    await store.waitForPendingSave()
    let restored = makeStore(url: url, transport: transport)
    defer { stop(restored) }
    XCTAssertTrue(restored.hasPendingArticlePublishTracking)
    XCTAssertTrue(restored.operationalPollingClientIDs.isEmpty)
    XCTAssertNotNil(restored.operationalPollingTask)
    for _ in 0..<200 where restored.hasPendingArticlePublishTracking {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(restored.hasPendingArticlePublishTracking)
    XCTAssertEqual(
      restored.articlePublishProgress(for: try XCTUnwrap(restored.releaseRecords.first))?.phase,
      .online)
    XCTAssertFalse(restored.deploymentPollingSettings.isEnabled)
  }

  func testClosingLastWindowKeepsPendingFollowupAlive() async throws {
    let (store, transport, _) = try fixture()
    defer { stop(store) }
    await transport.setMode(.building)
    store.setReleaseRecords([trackedRecord(store)])
    let client = UUID()
    store.startOperationalPolling(clientID: client)
    let generation = store.operationalPollingGeneration
    store.stopOperationalPolling(clientID: client)
    XCTAssertTrue(store.operationalPollingClientIDs.isEmpty)
    XCTAssertNotNil(store.operationalPollingTask)
    XCTAssertEqual(store.operationalPollingGeneration, generation)
    for _ in 0..<200 {
      if await transport.requests().isEmpty == false { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let requests = await transport.requests()
    XCTAssertFalse(requests.isEmpty)
  }

  func testConcurrentTicksCoalesceAndRespectCheckInterval() async throws {
    let (store, transport, _) = try fixture()
    defer { stop(store) }
    await transport.setMode(.building, delay: true)
    store.setReleaseRecords([trackedRecord(store)])
    let now = Date()
    let first = Task {
      await store.deploymentStore.tickArticlePublishTracking(store: store, now: now)
    }
    for _ in 0..<200 {
      if await transport.requests().isEmpty == false { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let second = await store.deploymentStore.tickArticlePublishTracking(store: store, now: now)
    XCTAssertFalse(second)
    let didRun = await first.value
    XCTAssertTrue(didRun)
    let before = await transport.requests().count
    let tooSoon = await store.deploymentStore.tickArticlePublishTracking(
      store: store, now: now.addingTimeInterval(1))
    XCTAssertFalse(tooSoon)
    let after = await transport.requests().count
    XCTAssertEqual(before, after)
  }

  func testTransientArticle404KeepsFollowingAndThenCompletes() async throws {
    let (store, transport, _) = try fixture()
    defer { stop(store) }
    await transport.setMode(.articleMissing)
    store.setReleaseRecords([trackedRecord(store)])
    _ = await store.deploymentStore.tickArticlePublishTracking(store: store, now: Date())
    let waiting = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertEqual(store.articlePublishProgress(for: waiting)?.phase, .verifyingArticle)
    XCTAssertNil(waiting.articlePublishTrackingRequest?.completedSnapshot)
    await transport.setMode(.ready)
    _ = await store.deploymentStore.tickArticlePublishTracking(
      store: store, now: Date().addingTimeInterval(16))
    XCTAssertEqual(
      store.articlePublishProgress(for: try XCTUnwrap(store.releaseRecords.first))?.phase, .online)
  }

  func testBackgroundTrackingUsesOriginalProfileAndRejectsDeletedOrChangedTarget() async throws {
    let (store, transport, _) = try fixture()
    defer { stop(store) }
    let profileA = store.activeProfile
    let record = trackedRecord(store)
    store.setReleaseRecords([record])
    var profileB = profileA
    profileB.id = UUID()
    profileB.deploymentStatusEndpointURL = "https://other.example/status"
    store.publishingStore.profiles.append(profileB)
    store.selectProfile(profileB.id)
    _ = await store.deploymentStore.tickArticlePublishTracking(store: store, now: Date())
    let requests = await transport.requests()
    XCTAssertFalse(requests.isEmpty)
    XCTAssertTrue(requests.allSatisfy { $0.url?.host == "tracking.example" })
    XCTAssertEqual(store.activeProfileID, profileB.id)

    store.setReleaseRecords([record])
    store.publishingStore.profiles.removeAll { $0.id == profileA.id }
    XCTAssertEqual(store.articlePublishProgress(for: record)?.phase, .needsAttention)
    XCTAssertFalse(store.canRecheckArticlePublication(record))
    XCTAssertFalse(store.canCheckDeploymentStatus(for: record))
    let deletedRefresh = await store.refreshDeploymentStatus(for: record)
    XCTAssertNil(deletedRefresh)
    let ranDeleted = await store.deploymentStore.tickArticlePublishTracking(
      store: store, now: Date().addingTimeInterval(20))
    XCTAssertFalse(ranDeleted)
    var changed = profileA
    changed.deploymentStatusEndpointURL = "https://changed.example/status"
    store.publishingStore.profiles.append(changed)
    XCTAssertFalse(store.canCheckDeploymentStatus(for: record))
    let changedRefresh = await store.refreshDeploymentStatus(for: record)
    XCTAssertNil(changedRefresh)
    let ranChanged = await store.deploymentStore.tickArticlePublishTracking(
      store: store, now: Date().addingTimeInterval(40))
    XCTAssertFalse(ranChanged)
    let after = await transport.requests()
    XCTAssertEqual(after.count, requests.count)
  }

  func testExpiredAndUnconfiguredRequestsDoNotFetch() async throws {
    let (store, transport, _) = try fixture()
    defer { stop(store) }
    var record = trackedRecord(store)
    record.articlePublishTrackingRequest = ArticlePublishTrackingRequest(
      profile: store.activeProfile, now: Date().addingTimeInterval(-1801))
    store.setReleaseRecords([record])
    let expired = await store.deploymentStore.tickArticlePublishTracking(store: store, now: Date())
    XCTAssertFalse(expired)
    XCTAssertEqual(store.articlePublishProgress(for: record)?.phase, .needsAttention)
    store.updateActiveProfile {
      $0.deploymentStatusEndpointURL = nil
      $0.deploymentSiteURL = nil
    }
    record = trackedRecord(store)
    store.setReleaseRecords([record])
    let unconfigured = await store.deploymentStore.tickArticlePublishTracking(
      store: store, now: Date())
    XCTAssertFalse(unconfigured)
    XCTAssertEqual(store.articlePublishProgress(for: record)?.phase, .needsAttention)
    let requests = await transport.requests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testChangedProfileDuringCheckDropsResponse() async throws {
    let (store, transport, _) = try fixture()
    defer { stop(store) }
    await transport.setMode(.ready, delay: true)
    let record = trackedRecord(store)
    store.setReleaseRecords([record])
    let check = Task {
      await store.deploymentStore.tickArticlePublishTracking(store: store, now: Date())
    }
    for _ in 0..<200 {
      if await transport.requests().isEmpty == false { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    store.updateActiveProfile { $0.deploymentStatusEndpointURL = "https://changed.example/status" }
    _ = await check.value
    XCTAssertNil(store.deploymentStatusSnapshot(for: record))
    XCTAssertNil(store.releaseRecords.first?.articlePublishTrackingRequest?.completedSnapshot)
  }

  func testExpiredRequestCannotCompleteFromLaterManualCheck() async throws {
    let (store, _, _) = try fixture()
    defer { stop(store) }
    var record = trackedRecord(store)
    record.articlePublishTrackingRequest = ArticlePublishTrackingRequest(
      profile: store.activeProfile, now: Date().addingTimeInterval(-1801))
    store.setReleaseRecords([record])
    let snapshot = await store.refreshDeploymentStatus(for: record)
    XCTAssertTrue(snapshot?.verifiesAllArticles(in: record) == true)
    let current = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertNil(current.articlePublishTrackingRequest?.completedSnapshot)
    XCTAssertEqual(store.articlePublishProgress(for: current)?.phase, .needsAttention)
  }

  func testAttributedPlatformFailureIsPersistedAsTerminalEvidence() async throws {
    let (store, transport, _) = try fixture()
    defer { stop(store) }
    await transport.setMode(.platformFailed)
    store.setReleaseRecords([trackedRecord(store)])
    _ = await store.deploymentStore.tickArticlePublishTracking(store: store, now: Date())
    let failed = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertEqual(failed.articlePublishTrackingRequest?.completedSnapshot?.platformLevel, .failed)
    XCTAssertEqual(store.articlePublishProgress(for: failed)?.phase, .needsAttention)
    XCTAssertFalse(store.hasPendingArticlePublishTracking)
  }

  private func fixture() throws -> (WorkbenchStore, ArticleTrackingTransport, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("workbench.json")
    let transport = ArticleTrackingTransport()
    let store = makeStore(url: url, transport: transport)
    store.updateActiveProfile {
      $0.branch = "main"
      $0.deploymentProvider = .custom
      $0.deploymentSiteURL = "https://tracking.example/"
      $0.deploymentStatusEndpointURL = "https://tracking.example/status"
    }
    return (store, transport, url)
  }

  private func makeStore(url: URL, transport: ArticleTrackingTransport) -> WorkbenchStore {
    WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: url),
      deploymentStatusService: DeploymentStatusService(transport: transport),
      deploymentTokenStore: KeychainTokenStore(
        service: "ArticleTrackingTests.\(UUID())", accountPrefix: "deployment-provider",
        inMemory: true))
  }

  private func trackedRecord(_ store: WorkbenchStore) -> ReleaseRecord {
    ReleaseRecord(
      kind: .remoteDirectCommit, title: "Article", summary: "",
      siteProfileID: store.activeProfileID,
      draftID: UUID(), draftTitle: "Article", publicPath: "/article/",
      publicURLText: "https://tracking.example/article/",
      sourceDocumentDigest: ArticleDraft.repositoryDocumentDigest("article"),
      markdownPath: "content/posts/article.md", branchName: "main", commitSHA: "release-sha",
      articlePublishTrackingRequest: ArticlePublishTrackingRequest(profile: store.activeProfile))
  }

  private func stop(_ store: WorkbenchStore) {
    store.operationalPollingClientIDs.removeAll()
    store.operationalPollingTask?.cancel()
    store.operationalPollingTask = nil
    store.operationalPollingTickTask?.cancel()
    store.operationalPollingTickTask = nil
  }
}

private actor ArticleTrackingTransport: RemoteRepositoryHTTPTransport {
  enum Mode: Equatable { case ready, building, articleMissing, offline, platformFailed }
  private var mode = Mode.ready
  private var delay = false
  private var captured: [URLRequest] = []
  func setMode(_ mode: Mode, delay: Bool = false) {
    self.mode = mode
    self.delay = delay
  }
  func requests() -> [URLRequest] { captured }
  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    captured.append(request)
    if delay { try await Task.sleep(for: .milliseconds(60)) }
    if mode == .offline { throw URLError(.notConnectedToInternet) }
    let url = try XCTUnwrap(request.url)
    let isStatus = url.path == "/status"
    let status = mode == .building ? "running" : mode == .platformFailed ? "failed" : "success"
    let body =
      isStatus
      ? "{\"status\":\"\(status)\",\"branch\":\"main\",\"commit_sha\":\"release-sha\"}"
      : "<html><head><meta name=repopress:source-digest content=\(ArticleDraft.repositoryDocumentDigest("article"))><link rel=canonical href=\(url.absoluteString)></head><h1>Article</h1></html>"
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: url, statusCode: !isStatus && mode == .articleMissing ? 404 : 200,
        httpVersion: nil, headerFields: nil))
    return (Data(body.utf8), response)
  }
}
