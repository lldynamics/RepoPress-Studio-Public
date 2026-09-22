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

  func testRemoteAcceptedResultFromReadOnlyVerificationSurvivesStoreReload() async throws {
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
    await store.verifyPublishExecution(id)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map { $0.httpMethod }, ["GET", "GET", "GET"])
    XCTAssertEqual(store.publishExecutionRecords.first?.state, .remoteAccepted)
    XCTAssertTrue(store.flushPendingChanges())
    let reloaded = WorkbenchStore(persistence: persistence)
    let record = try XCTUnwrap(reloaded.publishExecutionRecords.first)
    XCTAssertEqual(record.id, id)
    XCTAssertEqual(record.state, .remoteAccepted)
    XCTAssertEqual(record.plan, plan)
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
