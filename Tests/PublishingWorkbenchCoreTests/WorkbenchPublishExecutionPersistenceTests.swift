import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchPublishExecutionPersistenceTests: XCTestCase {
  private func package(content: String = "# Persisted") -> PublishPackage {
    PublishPackage(
      draftID: UUID(), title: "Persisted", markdownPath: "content/persisted.md",
      files: [
        PublishPackageFile(
          kind: .markdown, repositoryPath: "content/persisted.md", content: content)
      ],
      commitMessage: "Persisted", reviewBranchName: "publish/persisted",
      reviewTitle: "Persisted", reviewChecklist: [],
      builtAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  private func persistenceURL(_ name: String = UUID().uuidString) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("PublishExecution-\(name)-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("workbench.json")
  }

  private func makePlan(
    package: PublishPackage, profile: SiteProfile
  ) throws -> PublishExecutionPlan {
    let preview = RemoteRepositoryPublishPreview(
      provider: profile.repositoryProvider, repositoryName: profile.repositoryDisplayName,
      mode: .directCommit, branchName: profile.branch, targetBranch: profile.branch,
      changedPaths: package.files.map(\.repositoryPath), hasToken: true,
      accessCheck: RemoteRepositoryAccessCheck(
        provider: profile.repositoryProvider, repositoryName: profile.repositoryDisplayName,
        defaultBranch: profile.branch, canRead: true, canWrite: true, message: "ok"),
      blockingIssues: [], warningIssues: [])
    return try RemoteRepositoryPublishService().freezeExecutionPlan(
      package: package, batchItems: [], profile: profile, preview: preview)
  }

  func testBeginPublishExecutionFlushFailureMakesNoRemoteRequest() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PublishExecutionFlushFailure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let transport = SequencedRemoteRepositoryTransport(responses: [])
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directoryURL),
      initialSnapshotSource: .preloaded(WorkbenchSnapshotLoadResult(snapshot: nil)),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport))
    let profile = store.activeProfile

    XCTAssertThrowsError(
      try store.publishingStore.beginPublishExecution(
        id: UUID(), package: package(), profile: profile, mode: .directCommit, store: store))
    XCTAssertTrue((store.publishExecutionRecords.first?.state == .verifiedUnchanged))
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testReloadedPendingExecutionBlocksOverlappingPathBeforeRemotePublish() async throws {
    let url = persistenceURL("Overlap")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let store = WorkbenchStore(
      persistence: persistence,
      initialSnapshotSource: .preloaded(WorkbenchSnapshotLoadResult(snapshot: nil)))
    let plan = try makePlan(package: package(), profile: store.activeProfile)
    store.publishingStore.publishSession.executionRecords = [
      PublishExecutionRecord(
        id: UUID(), plan: plan, now: Date(timeIntervalSince1970: 1_700_000_000))
    ]
    XCTAssertTrue(store.flushPendingChanges())
    let transport = SequencedRemoteRepositoryTransport(responses: [])
    let reloaded = WorkbenchStore(
      persistence: persistence,
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport))
    XCTAssertEqual(reloaded.publishExecutionRecords.first?.state, .needsVerification)
    XCTAssertThrowsError(
      try reloaded.publishingStore.beginPublishExecution(
        id: UUID(), package: package(), profile: reloaded.activeProfile,
        mode: .directCommit, store: reloaded))
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testCleanStoreSavesNewExecutionPlanBeforeAnyRemoteRequest() async throws {
    let url = persistenceURL("CleanPlan")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let transport = SequencedRemoteRepositoryTransport(responses: [])
    let store = WorkbenchStore(
      persistence: persistence,
      initialSnapshotSource: .preloaded(WorkbenchSnapshotLoadResult(snapshot: nil)),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport))
    XCTAssertTrue(store.saveCurrentStateSynchronously())
    await store.waitForPendingSave()
    XCTAssertFalse(store.hasUnsavedChanges)
    let id = UUID()
    let frozen = try store.publishingStore.beginPublishExecution(
      id: id, package: package(), profile: store.activeProfile, mode: .directCommit, store: store)
    let saved = try XCTUnwrap(persistence.loadPrimarySnapshot().publishExecutionRecords.first)
    XCTAssertEqual(saved.id, id)
    XCTAssertEqual(saved.state, .awaitingRemoteResult)
    XCTAssertEqual(saved.plan.package, frozen)
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testRemoteAcceptedResultFromReadOnlyVerificationSurvivesStoreReload() async throws {
    try await verifyAcceptedResult(storageBlocked: false)
  }

  func testReadOnlyVerificationRetainsSaveWarningAndRecoversWithoutRemoteWrites() async throws {
    try await verifyAcceptedResult(storageBlocked: true)
  }

  private func verifyAcceptedResult(storageBlocked: Bool) async throws {
    let url = persistenceURL("Accepted")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let tokenStore = KeychainTokenStore(
      service: "PublishExecutionPersistenceTests.\(UUID().uuidString)", accountPrefix: "test",
      inMemory: true)
    let blob = RemoteRepositoryPublishService().gitBlobSHA(for: Data("# Persisted".utf8))
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"head"}}"#),
      response(json: #"{"sha":"\#(blob)"}"#),
      response(json: #"{"object":{"sha":"head"}}"#),
    ])
    let store = WorkbenchStore(
      persistence: persistence,
      initialSnapshotSource: .preloaded(WorkbenchSnapshotLoadResult(snapshot: nil)),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore)
    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    store.updateActiveProfile(profile)
    try tokenStore.saveRepositoryToken("token", for: profile)
    let plan = try makePlan(package: package(), profile: profile)
    let id = UUID()
    store.publishingStore.publishSession.executionRecords = [
      PublishExecutionRecord(id: id, plan: plan, now: Date(timeIntervalSince1970: 1_700_000_000))
    ]
    XCTAssertTrue(store.flushPendingChanges())
    let preservedURL = url.appendingPathExtension("preserved")
    if storageBlocked {
      try FileManager.default.moveItem(at: url, to: preservedURL)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    await store.verifyPublishExecution(id)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map { $0.httpMethod }, ["GET", "GET", "GET"])
    let expectedState: PublishExecutionState = storageBlocked ? .needsVerification : .remoteAccepted
    XCTAssertEqual(store.publishExecutionRecords.first?.state, expectedState)
    if storageBlocked {
      XCTAssertTrue(store.hasUnsavedChanges)
      XCTAssertEqual(store.publishActionFeedback?.status, .warning)
      XCTAssertTrue(store.publishActionMessage?.contains("本地记录保存失败") == true)
      XCTAssertTrue(store.publishActionMessage?.contains("已核实远端文件") == true)
      await store.waitForPendingSave()
      try FileManager.default.removeItem(at: url)
      try FileManager.default.moveItem(at: preservedURL, to: url)
    }
    XCTAssertTrue(store.flushPendingChanges())
    await store.waitForPendingSave()
    XCTAssertFalse(store.hasUnsavedChanges)
    let reloaded = WorkbenchStore(persistence: persistence)
    let record = try XCTUnwrap(reloaded.publishExecutionRecords.first)
    XCTAssertEqual(record.id, id)
    XCTAssertEqual(record.state, expectedState)
    XCTAssertEqual(record.plan, plan)
    let requestsAfterRetry = await transport.capturedRequests()
    XCTAssertEqual(requestsAfterRetry.count, requests.count)
  }

  func testFrozenPlanAndRecordStorageRoundTripRetainsEvidence() throws {
    let url = persistenceURL("RoundTrip")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let store = WorkbenchStore(
      persistence: persistence,
      initialSnapshotSource: .preloaded(WorkbenchSnapshotLoadResult(snapshot: nil)))
    let package = package(content: "# Exact evidence")
    let plan = try makePlan(package: package, profile: store.activeProfile)
    let original = PublishExecutionRecord(
      id: UUID(), plan: plan, now: Date(timeIntervalSince1970: 1_700_000_000))
    store.publishingStore.publishSession.executionRecords = [original]
    XCTAssertTrue(store.flushPendingChanges())
    let restored = try XCTUnwrap(persistence.loadPrimarySnapshot().publishExecutionRecords.first)
    XCTAssertEqual(restored, original)
    let reloaded = WorkbenchStore(persistence: persistence)
    XCTAssertEqual(reloaded.publishExecutionRecords.first?.state, .needsVerification)
  }
}

@MainActor
final class WorkbenchPublishCompletionRecoveryTests: WorkbenchStoreRemotePublishingTestCase {
  func testSingleRemoteSuccessRetainsLocalRecoveryWarningAndRetriesWithoutRepublishing()
    async throws
  {
    try await verifyLocalRecovery(isBatch: false)
  }

  func testBatchRemoteSuccessRetainsLocalRecoveryWarningAndRetriesWithoutRepublishing() async throws
  {
    try await verifyLocalRecovery(isBatch: true)
  }

  func testLocalRecoveryDoesNotHideVerifiedDeploymentOrItsFailure() {
    for status in [PublishActionMessageStatus.success, .failure, .information] {
      let remote = PublishActionFeedback(
        message: "Remote and deployment evidence", status: status, source: .publishing)
      let outcome = RemotePublishCompletionOutcome(
        persistence: .requiresLocalRecovery, remoteFeedback: remote,
        remoteProgressMessage: "Remote operation complete")
      XCTAssertTrue(outcome.feedback.message.contains(remote.message))
      XCTAssertTrue(outcome.feedback.message.contains("本地记录保存失败"))
      XCTAssertEqual(outcome.feedback.status, status == .failure ? .failure : .warning)
      XCTAssertEqual(outcome.feedback.source, .publishing)
      XCTAssertTrue(outcome.progressMessage.contains("本地记录保存失败"))
    }
  }

  private func verifyLocalRecovery(isBatch: Bool) async throws {
    let rootURL = try preparedGitRepositoryRoot(prefix: "PublishCompletionRecovery")
    let persistenceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PublishCompletionRecovery-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: persistenceDirectory)
    }
    let persistenceURL = persistenceDirectory.appendingPathComponent("workbench.json")
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    let transport = LocalRecordWriteFailureTransport(
      responses: responses(isBatch: isBatch), persistenceURL: persistenceURL)
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: persistence,
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore)
    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.deploymentProvider = .custom
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    try tokenStore.saveRepositoryToken("isolated-test-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    let drafts = (1...(isBatch ? 2 : 1)).map { index in
      ArticleDraft(
        siteProfileID: profile.id, title: "Recovery \(index)", slug: "recovery-\(index)",
        draft: false,
        bodyMarkdown: String(
          repeating: "A sufficiently long article for remote publishing. ", count: 5),
        status: .ready)
    }
    store.setDrafts(drafts)
    store.setSelectedDraftID(drafts[0].id)
    store.setPublishPackage(store.publishingPackage(for: drafts[0]))
    await transport.beforeFailure { await store.waitForPendingSave() }

    let result: RemoteRepositoryPublishResult?
    if isBatch {
      result = await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy()
    } else {
      result = await store.publishSelectedDraftOnlineUsingPreferredStrategy()
    }

    XCTAssertNotNil(
      result, "The remote operation succeeded even though its local record could not be saved.")
    let planSavedBeforeMutation = await transport.planSavedBeforeMutation()
    XCTAssertTrue(planSavedBeforeMutation)
    XCTAssertEqual(store.publishExecutionRecords.first?.state, .needsVerification)
    XCTAssertEqual(store.publishActionFeedback?.status, .warning)
    XCTAssertTrue(store.publishActionMessage?.contains("本地记录保存失败") == true)
    XCTAssertTrue(store.remoteRepositoryPublishProgress?.detail?.contains("本地记录保存失败") == true)
    XCTAssertTrue(store.hasUnsavedChanges)
    let requestsBeforeRetry = await transport.capturedRequests()
    XCTAssertEqual(
      requestsBeforeRetry.filter { $0.httpMethod == (isBatch ? "PATCH" : "PUT") }.count, 1)

    var edited = try XCTUnwrap(store.draft(for: drafts[0].id))
    edited.bodyMarkdown = "Newer editor content while the local record still needs recovery."
    store.updateDraft(edited)
    await store.waitForPendingSave()
    XCTAssertTrue(store.hasUnsavedChanges)
    try await transport.repairPersistencePath()
    XCTAssertTrue(store.flushPendingChanges())
    await store.waitForPendingSave()
    XCTAssertFalse(store.hasUnsavedChanges)
    let saved = try persistence.loadPrimarySnapshot()
    XCTAssertEqual(
      saved.drafts.first(where: { $0.id == edited.id })?.bodyMarkdown, edited.bodyMarkdown)
    XCTAssertEqual(saved.publishExecutionRecords.first?.state, .needsVerification)
    XCTAssertEqual(saved.releaseRecords.first?.id, result?.releaseRecordID)
    let reloaded = WorkbenchStore(persistence: persistence)
    XCTAssertEqual(reloaded.draft(for: edited.id)?.bodyMarkdown, edited.bodyMarkdown)
    XCTAssertEqual(reloaded.publishExecutionRecords.first?.state, .needsVerification)
    let requestsAfterRetry = await transport.capturedRequests()
    XCTAssertEqual(
      requestsAfterRetry.count, requestsBeforeRetry.count,
      "Local recovery must not repeat the remote mutation.")
  }

  private func responses(isBatch: Bool) -> [WorkbenchRemoteRepositoryTransportResponse] {
    var values = [
      workbenchRemoteResponse(
        json: #"{"full_name":"owner/site","default_branch":"main","permissions":{"push":true}}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
    ]
    if !isBatch {
      values.append(
        workbenchRemoteResponse(
          json:
            #"{"content":{"path":"content/posts/recovery-1.md","sha":"content-sha"},"commit":{"sha":"accepted-commit"}}"#
        ))
      return values
    }
    values += [
      workbenchRemoteResponse(json: #"{"object":{"sha":"base-commit-sha"}}"#),
      workbenchRemoteResponse(
        json: #"{"sha":"base-commit-sha","tree":{"sha":"base-tree-sha"},"parents":[]}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"sha":"first-blob-sha"}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"sha":"second-blob-sha"}"#),
      workbenchRemoteResponse(json: #"{"sha":"batch-tree-sha"}"#),
      workbenchRemoteResponse(
        json:
          #"{"sha":"accepted-commit","tree":{"sha":"batch-tree-sha"},"parents":[{"sha":"base-commit-sha"}]}"#
      ),
      workbenchRemoteResponse(json: #"{"object":{"sha":"accepted-commit"}}"#),
    ]
    return values
  }
}

/// Fails the real workspace write only after the final remote mutation has
/// returned success. The persisted plan must already exist before that point.
private actor LocalRecordWriteFailureTransport: RemoteRepositoryHTTPTransport {
  private let transport: SequencedWorkbenchRemoteRepositoryTransport
  private let persistenceURL: URL
  private var savedPlanWasPresent = false
  private var waitForSave: (@MainActor @Sendable () async -> Void)?

  init(responses: [WorkbenchRemoteRepositoryTransportResponse], persistenceURL: URL) {
    transport = SequencedWorkbenchRemoteRepositoryTransport(responses: responses)
    self.persistenceURL = persistenceURL
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let response = try await transport.data(for: request)
    if request.httpMethod == "PUT" || request.httpMethod == "PATCH" {
      await waitForSave?()
      let snapshot = try WorkbenchPersistence(fileURL: persistenceURL).loadPrimarySnapshot()
      savedPlanWasPresent = snapshot.publishExecutionRecords.contains {
        $0.state == .awaitingRemoteResult
      }
      try FileManager.default.moveItem(
        at: persistenceURL, to: persistenceURL.appendingPathExtension("preserved"))
      try FileManager.default.createDirectory(at: persistenceURL, withIntermediateDirectories: true)
    }
    return response
  }

  func planSavedBeforeMutation() -> Bool { savedPlanWasPresent }

  func beforeFailure(_ operation: @escaping @MainActor @Sendable () async -> Void) {
    waitForSave = operation
  }

  func repairPersistencePath() throws {
    try FileManager.default.removeItem(at: persistenceURL)
    try FileManager.default.moveItem(
      at: persistenceURL.appendingPathExtension("preserved"), to: persistenceURL)
  }

  func capturedRequests() async -> [URLRequest] { await transport.capturedRequests() }
}
