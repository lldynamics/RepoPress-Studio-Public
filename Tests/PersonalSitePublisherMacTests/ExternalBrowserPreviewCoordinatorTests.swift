import Foundation
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

private actor ExternalBrowserPreviewProbeGate {
  private var didStart = false
  private var isReleased = false

  func probe(_ request: URLRequest) async throws -> LocalSitePreviewPageProbeResult {
    didStart = true
    while !isReleased {
      try await Task.sleep(for: .milliseconds(10))
    }
    return LocalSitePreviewPageProbeResult(
      statusCode: 200,
      responseURL: request.url
    )
  }

  func waitUntilStarted(timeout: Duration = .seconds(2)) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !didStart {
      try Task.checkCancellation()
      guard clock.now < deadline else {
        throw ExternalBrowserPreviewProbeGateError.timedOutWaitingForProbe
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func release() {
    isReleased = true
  }
}

private enum ExternalBrowserPreviewProbeGateError: Error {
  case timedOutWaitingForProbe
}

@MainActor
final class ExternalBrowserPreviewCoordinatorTests: XCTestCase {
  func testStopDuringReadinessPreventsOpenAndFreshRetryOpensExactlyOnce() async throws {
    let rootURL = try temporaryDirectoryURL(prefix: "ExternalBrowserPreviewCoordinator")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let siteURL = rootURL.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: siteURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: siteURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )

    let processService = LocalSitePreviewProcessService(
      trustStore: LocalSitePreviewTrustStore(
        fileURL: rootURL.appendingPathComponent("preview-trust.json")
      ),
      isPortAvailable: { _ in true }
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: rootURL.appendingPathComponent("workbench.json")
      ),
      localSitePreviewProcessService: processService
    )
    defer { store.stopLocalSitePreviewImmediately() }
    store.updateActiveProfile { profile in
      profile.siteKind = .zola
      profile.localRepositoryRootPath = siteURL.path
      profile.markdownPathPattern = "content/posts/{slug}.md"
    }
    var draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Coordinator Preview",
      slug: "coordinator-preview",
      bodyMarkdown: "preview body"
    )
    draft.repositoryPath = "content/posts/coordinator-preview.md"
    store.setDrafts([draft])
    store.selectDraft(draft.id)

    let plan = try makeControlledPreviewPlan(
      profileID: store.activeProfileID,
      rootPath: siteURL.path
    )
    try authorizeAndStart(plan: plan, store: store, processService: processService)

    let gate = ExternalBrowserPreviewProbeGate()
    let readinessService = LocalSitePreviewPageReadinessService { request in
      try await gate.probe(request)
    }
    var openedURLs: [URL] = []
    let coordinator = ExternalBrowserPreviewCoordinator(
      store: store,
      readinessService: readinessService,
      urlOpener: { url, _, _ in
        openedURLs.append(url)
        return true
      }
    )

    coordinator.openCurrentArticle(for: draft.id)
    try await gate.waitUntilStarted()
    store.stopLocalSitePreview()
    await gate.release()
    await waitUntilIdle(coordinator)

    XCTAssertTrue(openedURLs.isEmpty)
    XCTAssertNotNil(coordinator.errorMessage)

    store.stopLocalSitePreviewImmediately()
    try authorizeAndStart(plan: plan, store: store, processService: processService)
    coordinator.dismissError()
    coordinator.openCurrentArticle(for: draft.id)
    await waitUntilIdle(coordinator)

    XCTAssertEqual(openedURLs.count, 1)
    XCTAssertEqual(openedURLs.first?.host, "127.0.0.1")
  }

  func testSwitchingFromDraftAToDraftBNeverOpensDraftA() async throws {
    let rootURL = try temporaryDirectoryURL(prefix: "ExternalBrowserPreviewDraftSwitch")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let siteURL = rootURL.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: siteURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: siteURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
    let processService = LocalSitePreviewProcessService(
      trustStore: LocalSitePreviewTrustStore(
        fileURL: rootURL.appendingPathComponent("preview-trust.json")
      ),
      isPortAvailable: { _ in true }
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: rootURL.appendingPathComponent("workbench.json")),
      localSitePreviewProcessService: processService
    )
    defer { store.stopLocalSitePreviewImmediately() }
    store.updateActiveProfile { profile in
      profile.siteKind = .zola
      profile.localRepositoryRootPath = siteURL.path
      profile.markdownPathPattern = "content/posts/{slug}.md"
    }
    var draftA = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Draft A",
      slug: "draft-a",
      bodyMarkdown: "A"
    )
    draftA.repositoryPath = "content/posts/draft-a.md"
    var draftB = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Draft B",
      slug: "draft-b",
      bodyMarkdown: "B"
    )
    draftB.repositoryPath = "content/posts/draft-b.md"
    store.setDrafts([draftA, draftB])
    store.selectDraft(draftA.id)

    let plan = try makeControlledPreviewPlan(
      profileID: store.activeProfileID,
      rootPath: siteURL.path
    )
    try authorizeAndStart(plan: plan, store: store, processService: processService)
    let gate = ExternalBrowserPreviewProbeGate()
    let readinessService = LocalSitePreviewPageReadinessService { request in
      try await gate.probe(request)
    }
    var openedURLs: [URL] = []
    let coordinator = ExternalBrowserPreviewCoordinator(
      store: store,
      readinessService: readinessService,
      urlOpener: { url, _, _ in
        openedURLs.append(url)
        return true
      }
    )

    coordinator.openCurrentArticle(for: draftA.id)
    try await gate.waitUntilStarted()
    store.selectDraft(draftB.id)
    coordinator.cancelPendingOpen(ifDraftIsNoLongerCurrent: draftB.id)
    coordinator.openCurrentArticle(for: draftB.id)
    await gate.release()
    await waitUntilIdle(coordinator)

    XCTAssertEqual(openedURLs.count, 1)
    XCTAssertTrue(openedURLs[0].path.contains("draft-b"))
    XCTAssertFalse(openedURLs[0].path.contains("draft-a"))
  }

  private func makeControlledPreviewPlan(
    profileID: UUID,
    rootPath: String
  ) throws -> LocalSitePreviewPlan {
    let arguments = ["30"]
    let executablePath = "/bin/sleep"
    let command = "sleep 30"
    let identity = try LocalSitePreviewExecutionFingerprint.makeIdentity(
      profileID: profileID,
      rootPath: rootPath,
      siteKind: .zola,
      executablePath: executablePath,
      arguments: arguments,
      command: command
    )
    return LocalSitePreviewPlan(
      siteKind: .zola,
      rootPath: identity.canonicalRootPath,
      executablePath: executablePath,
      arguments: arguments,
      command: command,
      previewURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1111")),
      notes: [],
      executionIdentity: identity
    )
  }

  private func authorizeAndStart(
    plan: LocalSitePreviewPlan,
    store: WorkbenchStore,
    processService: LocalSitePreviewProcessService
  ) throws {
    if let request = try processService.authorizationRequest(for: plan) {
      try processService.authorize(plan: plan, matching: request)
    }
    store.publishingStore.localSitePreviewPlan = plan
    guard case .started = store.publishingStore.startLocalSitePreview() else {
      return XCTFail("Expected controlled preview process to start")
    }
    XCTAssertTrue(store.localSitePreviewRuntimeStatus.isRunning)
  }

  private func waitUntilIdle(
    _ coordinator: ExternalBrowserPreviewCoordinator
  ) async {
    for _ in 0..<200 where coordinator.isBusy {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(coordinator.isBusy, "Coordinator did not finish in time")
  }

  private func temporaryDirectoryURL(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(prefix)-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
