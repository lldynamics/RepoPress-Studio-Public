import CoreGraphics
import Foundation
import ImageIO
import PublishingDomainContracts
import UniformTypeIdentifiers
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreRemotePublishFrozenLifecycleTests:
  WorkbenchStoreRemotePublishingTestCase
{
  func testDirectPublishConfirmsFrozenAWithoutReplacingSavedBAndCStillSaves() async throws {
    let transport = FrozenPublishLifecycleTransport(responses: [
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(
        json: #"{"content":{"sha":"published-a-blob"},"commit":{"sha":"published-a-commit"}}"#),
    ])
    let fixture = try await makeFixture(mode: .directCommit, transport: transport)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let packageA = PublishPackageBuilder().build(draft: fixture.draft, profile: fixture.profile)
    let digestA = try XCTUnwrap(packageA.sourceDocumentDigest)
    let task = try await suspendedPublish(
      package: packageA, mode: .directCommit, fixture: fixture, transport: transport)

    let savedB = try await editAndSave("Version B saved while A uploads.", fixture: fixture)
    let digestB = savedB.renderedRepositoryContentDigest(profile: fixture.profile)
    XCTAssertNotEqual(digestA, digestB)
    await transport.releaseUpload()
    let result = await task.value

    XCTAssertEqual(result?.commitSHA, "published-a-commit")
    let confirmed = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))
    XCTAssertEqual(confirmed.bodyMarkdown, savedB.bodyMarkdown)
    XCTAssertEqual(confirmed.repositoryBinding?.renderedContentDigest, digestA)
    XCTAssertEqual(confirmed.repositoryBinding?.projectFileContentDigest, digestB)
    XCTAssertEqual(confirmed.repositoryBinding?.projectFileRenderedContentDigest, digestB)
    XCTAssertEqual(confirmed.repositorySHA, "published-a-blob")
    XCTAssertNil(confirmed.repositoryImportFingerprint)
    XCTAssertEqual(confirmed.repositorySyncState(for: fixture.profile), .localChanged)
    XCTAssertEqual(fixture.store.releaseRecords.first?.sourceDocumentDigest, digestA)
    try await assertUploadedDocumentIsA(packageA, transport: transport)

    let savedC = try await editAndSave("Version C must save after A completes.", fixture: fixture)
    XCTAssertEqual(savedC.repositoryBinding?.renderedContentDigest, digestA)
    XCTAssertEqual(savedC.repositorySHA, "published-a-blob")
    XCTAssertEqual(savedC.repositorySyncState(for: fixture.profile), .localChanged)
    XCTAssertEqual(
      savedC.repositoryBinding?.projectFileContentDigest,
      savedC.renderedRepositoryContentDigest(profile: fixture.profile))
  }

  func testReviewPublishTracksFrozenAWhileSavedBRemainsLocalChanged() async throws {
    let transport = reviewTransport()
    let fixture = try await makeFixture(mode: .reviewRequest, transport: transport)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let packageA = PublishPackageBuilder().build(draft: fixture.draft, profile: fixture.profile)
    let digestA = try XCTUnwrap(packageA.sourceDocumentDigest)
    let task = try await suspendedPublish(
      package: packageA, mode: .reviewRequest, fixture: fixture, transport: transport)

    let savedB = try await editAndSave("Version B is absent from the open PR.", fixture: fixture)
    await transport.releaseUpload()
    let result = await task.value

    XCTAssertEqual(result?.reviewURL, "https://github.com/owner/site/pull/12")
    let pending = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))
    XCTAssertEqual(pending.repositoryBinding?.pendingReviewContentDigest, digestA)
    XCTAssertEqual(pending.repositoryBinding?.syncState, .localChanged)
    XCTAssertEqual(pending.repositorySyncState(for: fixture.profile), .localChanged)
    XCTAssertEqual(
      pending.repositoryBinding?.projectFileContentDigest,
      savedB.renderedRepositoryContentDigest(profile: fixture.profile))
    XCTAssertNil(pending.repositoryImportFingerprint)
    try await assertUploadedDocumentIsA(packageA, transport: transport)

    let savedC = try await editAndSave(
      "Version C is also absent from the open PR.", fixture: fixture)
    XCTAssertEqual(savedC.repositoryBinding?.pendingReviewContentDigest, digestA)
    XCTAssertEqual(savedC.repositorySyncState(for: fixture.profile), .localChanged)
  }

  func testUneditedDirectPublishRemainsSyncedAndConfirmsItsFingerprint() async throws {
    let transport = FrozenPublishLifecycleTransport(responses: [
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(
        json: #"{"content":{"sha":"published-a-blob"},"commit":{"sha":"published-a-commit"}}"#),
    ])
    let fixture = try await makeFixture(mode: .directCommit, transport: transport)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let package = PublishPackageBuilder().build(draft: fixture.draft, profile: fixture.profile)
    let task = try await suspendedPublish(
      package: package, mode: .directCommit, fixture: fixture, transport: transport)
    await transport.releaseUpload()
    let result = await task.value

    XCTAssertNotNil(result)
    let confirmed = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))
    XCTAssertEqual(confirmed.repositorySyncState(for: fixture.profile), .synced)
    XCTAssertEqual(confirmed.repositoryImportFingerprint, confirmed.repositoryContentFingerprint)
    XCTAssertEqual(confirmed.repositoryBinding?.renderedContentDigest, package.sourceDocumentDigest)
  }

  func testUneditedReviewPublishRemainsAwaitingReview() async throws {
    let transport = reviewTransport()
    let fixture = try await makeFixture(mode: .reviewRequest, transport: transport)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let package = PublishPackageBuilder().build(draft: fixture.draft, profile: fixture.profile)
    let task = try await suspendedPublish(
      package: package, mode: .reviewRequest, fixture: fixture, transport: transport)
    await transport.releaseUpload()
    let result = await task.value

    XCTAssertNotNil(result)
    let pending = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))
    XCTAssertEqual(pending.repositorySyncState(for: fixture.profile), .awaitingReview)
    XCTAssertEqual(
      pending.repositoryBinding?.pendingReviewContentDigest, package.sourceDocumentDigest)
  }

  func testDirectPublishCannotRebindDraftMovedToAnotherSiteDuringUpload() async throws {
    try await assertPublishDoesNotRebindAfterOwnershipTransfer(
      mode: .directCommit, operation: .moveToSite)
  }

  func testDirectPublishCannotRebindDraftMovedToGeneralDuringUpload() async throws {
    try await assertPublishDoesNotRebindAfterOwnershipTransfer(
      mode: .directCommit, operation: .moveToGeneral)
  }

  func testReviewPublishCannotRebindDraftMovedToAnotherSiteDuringUpload() async throws {
    try await assertPublishDoesNotRebindAfterOwnershipTransfer(
      mode: .reviewRequest, operation: .moveToSite)
  }

  func testReviewPublishCannotRebindDraftMovedToGeneralDuringUpload() async throws {
    try await assertPublishDoesNotRebindAfterOwnershipTransfer(
      mode: .reviewRequest, operation: .moveToGeneral)
  }

  private func assertPublishDoesNotRebindAfterOwnershipTransfer(
    mode: RemoteRepositoryPublishMode,
    operation: DraftOwnershipTransferOperation
  ) async throws {
    let isDirect = mode == .directCommit
    let transport =
      isDirect
      ? FrozenPublishLifecycleTransport(responses: [
        workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
        workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
        workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
        workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
        workbenchRemoteResponse(json: #"{"id":"published-a-commit"}"#),
      ]) : reviewTransport()
    let fixture = try await makeFixture(
      mode: mode, transport: transport, provider: isDirect ? .gitlab : .github,
      includeAttachment: isDirect)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let packageA = PublishPackageBuilder().build(draft: fixture.draft, profile: fixture.profile)
    let task = try await suspendedPublish(
      package: packageA, mode: mode, fixture: fixture, transport: transport)

    var target = SiteProfile.defaultProfile
    target.id = UUID()
    target.name = "Target site"
    target.repoOwner = "target-owner"
    target.repoName = "target-repository"
    fixture.store.setProfiles(fixture.store.profiles + [target])
    let transferPlan = fixture.store.draftOwnershipTransferPlan(
      draftIDs: [fixture.draft.id], operation: operation,
      targetProfileID: operation == .moveToSite ? target.id : nil)
    XCTAssertTrue(transferPlan.canApply)
    XCTAssertNotNil(fixture.store.applyDraftOwnershipTransfer(transferPlan))
    let moved = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))
    XCTAssertNil(moved.repositoryBinding)
    XCTAssertNil(moved.repositorySHA)
    XCTAssertNil(moved.repositoryPath)
    if operation == .moveToSite {
      XCTAssertTrue(moved.belongs(toSiteProfileID: target.id))
    } else {
      XCTAssertTrue(moved.isGeneralDraft)
    }
    await transport.releaseUpload()
    let result = await task.value

    XCTAssertNotNil(result)
    XCTAssertEqual(fixture.store.releaseRecords.first?.siteProfileID, fixture.profile.id)
    XCTAssertEqual(
      fixture.store.releaseRecords.first?.sourceDocumentDigest, packageA.sourceDocumentDigest)
    let afterPublish = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))
    XCTAssertEqual(afterPublish, moved)
    XCTAssertNil(afterPublish.repositoryBinding)
    XCTAssertNil(afterPublish.repositorySHA)
    XCTAssertNil(afterPublish.repositoryImportFingerprint)
    XCTAssertTrue(afterPublish.attachments.allSatisfy { $0.repositorySHA == nil })
    if isDirect {
      let attachment = try XCTUnwrap(afterPublish.attachments.first)
      XCTAssertEqual(result?.remoteVersion(for: attachment.repositoryPath), "published-a-commit")
    }
  }

  private struct Fixture {
    var store: WorkbenchStore
    var rootURL: URL
    var profile: SiteProfile
    var draft: ArticleDraft
  }

  private func suspendedPublish(
    package: PublishPackage,
    mode: RemoteRepositoryPublishMode,
    fixture: Fixture,
    transport: FrozenPublishLifecycleTransport
  ) async throws -> Task<RemoteRepositoryPublishResult?, Never> {
    let task = Task {
      let result = await fixture.store.publishingStore.publishSelectedDraftOnline(
        package: package, profile: fixture.profile, mode: mode, store: fixture.store)
      await transport.publishFinished(
        message: fixture.store.publishActionMessage ?? "Publish returned without an action message")
      return result
    }
    do {
      try await transport.waitUntilUploadIsSuspended()
    } catch {
      task.cancel()
      await transport.releaseUpload()
      throw error
    }
    return task
  }

  private func makeFixture(
    mode: RemoteRepositoryPublishMode,
    transport: FrozenPublishLifecycleTransport,
    provider: RepositoryProvider = .github,
    includeAttachment: Bool = false
  ) async throws -> Fixture {
    let rootURL = try preparedGitRepositoryRoot(prefix: "FrozenPublishLifecycle")
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: rootURL.appendingPathComponent("app-data/workbench.json")),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore)
    var profile = store.activeProfile
    profile.repositoryProvider = provider
    profile.repositoryBaseURL = provider.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = mode == .directCommit ? .direct : .reviewRequest
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    try tokenStore.saveRepositoryToken("test-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
        provider: provider, repositoryName: "owner/site",
        apiBaseURL: provider == .github ? "https://api.github.com" : "https://gitlab.com/api/v4",
        defaultBranch: "main", targetBranch: "main",
        publishStrategy: profile.repositoryPublishStrategy,
        canRead: true, canWrite: true, message: "Fixture write access"))
    var draft = ArticleDraft(
      siteProfileID: profile.id, title: "Frozen lifecycle", date: fixedDate(),
      slug: "frozen-lifecycle",
      draft: false, bodyMarkdown: "Version A submitted in the frozen publishing package.",
      status: .ready)
    if includeAttachment {
      let sourceURL = rootURL.appendingPathComponent("original.png")
      try writeNativePNG(to: sourceURL)
      draft.attachments = [
        DraftAttachment(
          originalFilename: "original.png", relativePublishPath: "/images/photo.png",
          repositoryPath: "static/images/photo.png", sourceFilePath: sourceURL.path)
      ]
    }
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    let wasWritten = await store.writeSiteDraftToProject(draftID: draft.id)
    XCTAssertTrue(wasWritten)
    await store.waitForPendingSiteDraftFileWrites()
    return Fixture(
      store: store, rootURL: rootURL, profile: profile,
      draft: try XCTUnwrap(store.draft(for: draft.id)))
  }

  private func writeNativePNG(to url: URL) throws {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    let image = try XCTUnwrap(context.makeImage())
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw FrozenPublishLifecycleFixtureError.invalidPNG
    }
  }

  private func editAndSave(_ content: String, fixture: Fixture) async throws -> ArticleDraft {
    var edited = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))
    edited.bodyMarkdown = content
    XCTAssertTrue(fixture.store.updateDraftFromEditor(edited))
    await fixture.store.waitForPendingSiteDraftFileWrites()
    let saved = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))
    let repositoryPath = try XCTUnwrap(saved.repositoryPath)
    let document = try String(
      contentsOf: fixture.rootURL.appendingPathComponent(repositoryPath), encoding: .utf8)
    XCTAssertTrue(document.contains(content))
    XCTAssertNil(fixture.store.siteDraftFileSaveFailures[saved.id])
    return saved
  }

  private func assertUploadedDocumentIsA(
    _ package: PublishPackage, transport: FrozenPublishLifecycleTransport
  ) async throws {
    let requests = await transport.capturedRequests()
    let upload = try XCTUnwrap(requests.first { $0.httpMethod == "PUT" })
    let body = try XCTUnwrap(upload.httpBody)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let encodedContent = try XCTUnwrap(object["content"] as? String)
    let content = try XCTUnwrap(Data(base64Encoded: encodedContent))
    XCTAssertEqual(String(data: content, encoding: .utf8), package.markdownFile?.content)
  }

  private func reviewTransport() -> FrozenPublishLifecycleTransport {
    FrozenPublishLifecycleTransport(responses: [
      workbenchRemoteResponse(json: #"{"object":{"sha":"base-sha"}}"#),
      workbenchRemoteResponse(
        json: #"{"ref":"refs/heads/publish/frozen-lifecycle","object":{"sha":"base-sha"}}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(
        json: #"{"content":{"sha":"review-a-blob"},"commit":{"sha":"review-a-commit"}}"#),
      workbenchRemoteResponse(json: #"{"html_url":"https://github.com/owner/site/pull/12"}"#),
    ])
  }
}

private actor FrozenPublishLifecycleTransport: RemoteRepositoryHTTPTransport {
  private var responses: [WorkbenchRemoteRepositoryTransportResponse]
  private var requests: [URLRequest] = []
  private var uploadContinuation: CheckedContinuation<Void, Never>?
  private var suspensionWaiters: [CheckedContinuation<Void, Error>] = []
  private var uploadSuspended = false
  private var gateFailure: FrozenPublishLifecycleFixtureError?
  private var timeoutTask: Task<Void, Never>?

  init(responses: [WorkbenchRemoteRepositoryTransportResponse]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    if let gateFailure { throw gateFailure }
    requests.append(request)
    guard !responses.isEmpty else {
      XCTFail("Unexpected fixture request: \(request.url?.absoluteString ?? "")")
      throw URLError(.badServerResponse)
    }
    let response = responses.removeFirst()
    if request.httpMethod == "PUT"
      || (request.httpMethod == "POST"
        && request.url?.path.hasSuffix("/repository/commits") == true)
    {
      await withCheckedContinuation { continuation in
        uploadContinuation = continuation
        uploadSuspended = true
        timeoutTask?.cancel()
        timeoutTask = nil
        for waiter in suspensionWaiters { waiter.resume() }
        suspensionWaiters.removeAll()
      }
    }
    return (
      response.data,
      HTTPURLResponse(
        url: request.url!, statusCode: response.statusCode, httpVersion: nil,
        headerFields: response.headerFields)!
    )
  }

  func waitUntilUploadIsSuspended() async throws {
    guard !uploadSuspended else { return }
    if let gateFailure { throw gateFailure }
    try await withCheckedThrowingContinuation { continuation in
      suspensionWaiters.append(continuation)
      timeoutTask = Task {
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        failUploadGate(
          .uploadTimedOut(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }))
      }
    }
  }

  func publishFinished(message: String) {
    guard !uploadSuspended else { return }
    failUploadGate(.publishEndedBeforeUpload(message))
  }

  private func failUploadGate(_ error: FrozenPublishLifecycleFixtureError) {
    guard gateFailure == nil, !uploadSuspended else { return }
    gateFailure = error
    timeoutTask?.cancel()
    timeoutTask = nil
    for waiter in suspensionWaiters { waiter.resume(throwing: error) }
    suspensionWaiters.removeAll()
  }

  func releaseUpload() {
    uploadContinuation?.resume()
    uploadContinuation = nil
  }

  func capturedRequests() -> [URLRequest] { requests }
}

private enum FrozenPublishLifecycleFixtureError: LocalizedError {
  case invalidPNG
  case publishEndedBeforeUpload(String)
  case uploadTimedOut([String])

  var errorDescription: String? {
    switch self {
    case .invalidPNG:
      "Native PNG fixture could not be written."
    case .publishEndedBeforeUpload(let message):
      "Publish ended before the required upload request: \(message)"
    case .uploadTimedOut(let requests):
      "Required upload request did not arrive within 5 seconds. Captured requests: \(requests)"
    }
  }
}
