import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class AIPublishAuthorizationTests: XCTestCase {
  func testUnchangedAuthorizationScopeValidates() async throws {
    let fixture = try makeFixture(prefix: "HappyPath")
    defer { fixture.cleanup() }
    let authorization = try await AIPublishAuthorizationService.prepare(in: fixture.store)
    let plan = try XCTUnwrap(fixture.store.batchPublishPlan)
    let package = try XCTUnwrap(fixture.store.remotePublishPackage(for: plan))
    let preview = fixture.store.remoteRepositoryPublishPreview(
      package: package,
      profile: fixture.store.activeProfile,
      mode: fixture.store.preferredRemoteRepositoryPublishMode(for: fixture.store.activeProfile),
      extraWarningIssues: fixture.store.batchRemoteRepositoryPublishWarningIssues(for: plan)
    )

    XCTAssertNoThrow(
      try AIPublishAuthorizationService.validate(
        authorization,
        package: package,
        preview: preview,
        profile: fixture.store.activeProfile,
        repositoryReport: fixture.store.repositoryReport(for: fixture.store.activeProfile)
      )
    )
    let requestCount = await fixture.transport.requestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testAuthorizationCapturesCompleteScopeWithoutPersistingMachinePathsOrEndpoint() async throws
  {
    let fixture = try makeFixture(prefix: "Privacy")
    defer { fixture.cleanup() }

    let authorization = try await AIPublishAuthorizationService.prepare(in: fixture.store)
    let step = WorkbenchAutomationStep(
      command: .publishOnline,
      publishAuthorization: authorization,
      status: .awaitingConfirmation
    )
    let data = try JSONEncoder().encode(step)
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertEqual(authorization.scope.siteName, fixture.profile.name)
    XCTAssertEqual(authorization.scope.repositoryDisplayName, "owner/site")
    XCTAssertEqual(authorization.scope.targetBranch, "main")
    XCTAssertEqual(
      authorization.scope.publishMode, RemoteRepositoryPublishMode.directCommit.rawValue)
    XCTAssertEqual(authorization.scope.changedPaths, authorization.scope.files.map(\.path))
    XCTAssertTrue(authorization.scope.files.allSatisfy { $0.contentSHA256.count == 64 })
    XCTAssertEqual(authorization.scope.repositoryIdentitySHA256.count, 64)
    XCTAssertEqual(authorization.scope.localRepositoryIdentitySHA256?.count, 64)
    XCTAssertFalse(json.contains(fixture.rootURL.path))
    XCTAssertFalse(json.contains("https://api.example.test/private"))
    XCTAssertFalse(json.contains("contentSHA256"))
    XCTAssertFalse(json.contains(authorization.nonce.uuidString))
    XCTAssertNil(
      try JSONDecoder().decode(WorkbenchAutomationStep.self, from: data).publishAuthorization)
  }

  func testAutomationFirstConfirmationCreatesSnapshotWithoutCallingTransport() async throws {
    let fixture = try makeFixture(prefix: "Prepare")
    defer { fixture.cleanup() }
    let step = WorkbenchAutomationStep(command: .publishOnline)

    let result = await WorkbenchAutomationExecutor.execute(
      plan: WorkbenchAutomationPlan(goal: "发布", steps: [step]),
      in: fixture.store,
      onlyStepID: step.id,
      confirmedStepIDs: [step.id]
    )

    XCTAssertEqual(result.plan.steps.first?.status, .awaitingConfirmation)
    XCTAssertNotNil(result.plan.steps.first?.publishAuthorization)
    let requestCount = await fixture.transport.requestCount()
    XCTAssertEqual(requestCount, 0)
    XCTAssertFalse(fixture.store.isRemoteRepositoryPublishing)
  }

  func testPathAdditionAfterConfirmationFailsClosedBeforeTransport() async throws {
    try await assertDraftDriftFailsClosed(prefix: "PathAddition") { draft in
      draft.slug = "changed-path"
    }
  }

  func testPathRemovalAfterConfirmationFailsClosedBeforeTransport() async throws {
    try await assertDraftDriftFailsClosed(prefix: "PathRemoval", draftCount: 2) { drafts in
      drafts.removeLast()
    }
  }

  func testContentChangeAfterConfirmationFailsClosedBeforeTransport() async throws {
    try await assertDraftDriftFailsClosed(prefix: "ContentChange") { draft in
      draft.bodyMarkdown += "\n\nChanged after confirmation."
    }
  }

  func testAttachmentContentChangeAfterConfirmationFailsClosedBeforeTransport() async throws {
    let fixture = try makeFixture(prefix: "AttachmentContent", addsAttachment: true)
    defer { fixture.cleanup() }
    let authorization = try await AIPublishAuthorizationService.prepare(in: fixture.store)
    try Data("changed image bytes".utf8).write(to: try XCTUnwrap(fixture.attachmentURL))

    await assertRejectedBeforeTransport(fixture: fixture, authorization: authorization)
  }

  func testProfileSwitchAfterConfirmationFailsClosedBeforeTransport() async throws {
    let fixture = try makeFixture(prefix: "ProfileSwitch")
    defer { fixture.cleanup() }
    let authorization = try await AIPublishAuthorizationService.prepare(in: fixture.store)
    var second = fixture.profile
    second.id = UUID()
    second.name = "Second Site"
    fixture.store.setProfiles([fixture.profile, second])
    fixture.store.selectProfile(second.id)

    await assertRejectedBeforeTransport(fixture: fixture, authorization: authorization)
  }

  func testDestinationChangeAfterConfirmationFailsClosedBeforeTransport() async throws {
    let fixture = try makeFixture(prefix: "Destination")
    defer { fixture.cleanup() }
    let authorization = try await AIPublishAuthorizationService.prepare(in: fixture.store)
    var changed = fixture.store.activeProfile
    changed.repoName = "another-site"
    fixture.store.updateActiveProfile(changed)

    await assertRejectedBeforeTransport(fixture: fixture, authorization: authorization)
  }

  func testRepositoryEndpointChangeAfterConfirmationFailsClosedWithoutPersistingEndpoint()
    async throws
  {
    let fixture = try makeFixture(prefix: "Endpoint")
    defer { fixture.cleanup() }
    let authorization = try await AIPublishAuthorizationService.prepare(in: fixture.store)
    var changed = fixture.store.activeProfile
    changed.repositoryBaseURL = "https://api.example.test/another-private-endpoint"
    fixture.store.updateActiveProfile(changed)

    await assertRejectedBeforeTransport(fixture: fixture, authorization: authorization)
  }

  func testBranchChangeAfterConfirmationFailsClosedBeforeTransport() async throws {
    let fixture = try makeFixture(prefix: "Branch")
    defer { fixture.cleanup() }
    let authorization = try await AIPublishAuthorizationService.prepare(in: fixture.store)
    var changed = fixture.store.activeProfile
    changed.branch = "release"
    fixture.store.updateActiveProfile(changed)

    await assertRejectedBeforeTransport(fixture: fixture, authorization: authorization)
  }

  func testModeAndStrategyChangeAfterConfirmationFailsClosedBeforeTransport() async throws {
    let fixture = try makeFixture(prefix: "Mode")
    defer { fixture.cleanup() }
    let authorization = try await AIPublishAuthorizationService.prepare(in: fixture.store)
    var changed = fixture.store.activeProfile
    changed.repositoryPublishStrategy = .reviewRequest
    fixture.store.updateActiveProfile(changed)

    await assertRejectedBeforeTransport(fixture: fixture, authorization: authorization)
  }

  func testGitBaseChangeAfterConfirmationFailsClosedBeforeTransport() async throws {
    let fixture = try makeFixture(prefix: "GitBase")
    defer { fixture.cleanup() }
    let authorization = try await AIPublishAuthorizationService.prepare(in: fixture.store)
    try "baseline changed\n".write(
      to: fixture.rootURL.appendingPathComponent("BASELINE.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "BASELINE.md"], at: fixture.rootURL)
    try git(["commit", "-m", "Move baseline"], at: fixture.rootURL)

    await assertRejectedBeforeTransport(fixture: fixture, authorization: authorization)
  }

  func testExpiredAuthorizationFailsClosedBeforeTransport() async throws {
    let fixture = try makeFixture(prefix: "Expired")
    defer { fixture.cleanup() }
    let prepared = try await AIPublishAuthorizationService.prepare(in: fixture.store)
    let expired = AIPublishAuthorizationSnapshot(
      nonce: prepared.nonce,
      generatedAt: Date(timeIntervalSince1970: 1),
      expiresAt: Date(timeIntervalSince1970: 2),
      scope: prepared.scope
    )

    await assertRejectedBeforeTransport(fixture: fixture, authorization: expired)
  }

  func testAutomationDriftClearsAuthorizationAndRequiresReconfirmationWithoutTransport()
    async throws
  {
    let fixture = try makeFixture(prefix: "AutomationDrift")
    defer { fixture.cleanup() }
    let authorization = try await AIPublishAuthorizationService.prepare(in: fixture.store)
    var changedDraft = try XCTUnwrap(fixture.store.selectedDraft)
    changedDraft.bodyMarkdown += "\n\nDrift"
    fixture.store.updateDraft(changedDraft)
    let step = WorkbenchAutomationStep(
      command: .publishOnline,
      publishAuthorization: authorization,
      status: .awaitingConfirmation
    )

    let result = await WorkbenchAutomationExecutor.execute(
      plan: WorkbenchAutomationPlan(goal: "发布", steps: [step]),
      in: fixture.store,
      onlyStepID: step.id,
      confirmedStepIDs: [step.id]
    )

    XCTAssertEqual(result.plan.steps.first?.status, .awaitingConfirmation)
    XCTAssertNil(result.plan.steps.first?.publishAuthorization)
    XCTAssertTrue(result.plan.steps.first?.resultMessage?.contains("重新审阅") == true)
    let requestCount = await fixture.transport.requestCount()
    XCTAssertEqual(requestCount, 0)
  }

  private func assertDraftDriftFailsClosed(
    prefix: String,
    _ mutate: (inout ArticleDraft) -> Void
  ) async throws {
    try await assertDraftDriftFailsClosed(prefix: prefix, draftCount: 1) { drafts in
      mutate(&drafts[0])
    }
  }

  private func assertDraftDriftFailsClosed(
    prefix: String,
    draftCount: Int,
    _ mutate: (inout [ArticleDraft]) -> Void
  ) async throws {
    let fixture = try makeFixture(prefix: prefix, draftCount: draftCount)
    defer { fixture.cleanup() }
    let authorization = try await AIPublishAuthorizationService.prepare(in: fixture.store)
    var drafts = fixture.store.drafts
    mutate(&drafts)
    fixture.store.setDrafts(drafts)

    await assertRejectedBeforeTransport(fixture: fixture, authorization: authorization)
  }

  private func assertRejectedBeforeTransport(
    fixture: Fixture,
    authorization: AIPublishAuthorizationSnapshot
  ) async {
    let result = await fixture.store.publishBatchReadyDraftsOnlineUsingPreferredStrategy(
      expectedChangedPaths: Set(authorization.scope.changedPaths),
      authorization: authorization
    )

    XCTAssertNil(result)
    XCTAssertTrue(
      AIPublishAuthorizationError.isReconfirmationMessage(fixture.store.publishActionMessage),
      fixture.store.publishActionMessage ?? "Missing fail-closed message"
    )
    let requestCount = await fixture.transport.requestCount()
    XCTAssertEqual(requestCount, 0)
    XCTAssertFalse(fixture.store.isRemoteRepositoryPublishing)
    XCTAssertNil(fixture.store.remoteRepositoryPublishResult)
  }

  private func makeFixture(
    prefix: String,
    draftCount: Int = 1,
    addsAttachment: Bool = false
  ) throws -> Fixture {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "AIPublishAuth-\(prefix)")
    try git(["init", "-b", "main"], at: rootURL)
    try git(["config", "user.email", "tests@example.com"], at: rootURL)
    try git(["config", "user.name", "Tests"], at: rootURL)
    try "initial\n".write(
      to: rootURL.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "README.md"], at: rootURL)
    try git(["commit", "-m", "Initial"], at: rootURL)

    let transport = CountingAIPublishAuthorizationTransport()
    let tokenStore = KeychainTokenStore(
      service: "AIPublishAuthorizationTests.\(UUID().uuidString)",
      accountPrefix: "repository",
      inMemory: true
    )
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "AIPublishAuth-\(prefix)"),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )
    var profile = store.activeProfile
    profile.name = "Authorized Site"
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.example.test/private"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    try tokenStore.saveRepositoryToken("token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
        provider: .github,
        repositoryName: "owner/site",
        apiBaseURL: profile.repositoryBaseURL,
        defaultBranch: "main",
        canRead: true,
        canWrite: true,
        message: "Writable"
      ))

    var attachmentURL: URL?
    var drafts = (0..<draftCount).map { index in
      ArticleDraft(
        siteProfileID: profile.id,
        title: "Authorized \(index)",
        slug: "authorized-\(index)",
        draft: false,
        bodyMarkdown:
          "This article body is intentionally long enough to pass preflight and exercise immutable AI publish authorization."
      )
    }
    if addsAttachment {
      let url = rootURL.appendingPathComponent("attachment.png")
      try Data("initial image bytes".utf8).write(to: url)
      attachmentURL = url
      drafts[0].attachments = [
        DraftAttachment(
          originalFilename: "attachment.png",
          relativePublishPath: "/images/attachment.png",
          repositoryPath: "static/images/attachment.png",
          altText: "Attachment",
          byteSize: Int64(try Data(contentsOf: url).count),
          sourceFilePath: url.path
        )
      ]
    }
    store.setDrafts(drafts)
    store.setSelectedDraftID(drafts.first?.id)
    return Fixture(
      store: store,
      transport: transport,
      profile: profile,
      rootURL: rootURL,
      attachmentURL: attachmentURL
    )
  }

  @discardableResult
  private func git(_ arguments: [String], at rootURL: URL) throws -> String {
    let result = GitCommandRunner().run(arguments, rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      throw NSError(
        domain: "AIPublishAuthorizationTests",
        code: Int(result.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: result.output]
      )
    }
    return result.standardOutput
  }

  private struct Fixture {
    let store: WorkbenchStore
    let transport: CountingAIPublishAuthorizationTransport
    let profile: SiteProfile
    let rootURL: URL
    let attachmentURL: URL?

    func cleanup() {
      try? FileManager.default.removeItem(at: rootURL)
    }
  }
}

private actor CountingAIPublishAuthorizationTransport: RemoteRepositoryHTTPTransport {
  private var count = 0

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    count += 1
    throw URLError(.badServerResponse)
  }

  func requestCount() -> Int {
    count
  }
}
