import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class RepositorySafeSyncStoreTests: XCTestCase {
  func testPrepareAlreadySynchronizedReportsSuccessAndReleasesLocks() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.parentURL) }
    let store = try TestWorkbenchFactory.makeStore(prefix: "RepositorySafeSyncAlreadySynchronized")
    store.updateActiveProfile(fixture.profile)

    let preparation = await store.prepareRepositorySafeSync()

    guard case .alreadySynchronized(let branch, let headSHA) = preparation else {
      return XCTFail("Expected an already-synchronized result")
    }
    XCTAssertEqual(branch, "main")
    XCTAssertEqual(headSHA, try git(["rev-parse", "HEAD"], rootURL: fixture.localURL))
    XCTAssertEqual(store.publishActionFeedback?.status, .success)
    XCTAssertFalse(store.isLocalRepositoryBranchOperationRunning)
    XCTAssertFalse(store.isLocalRepositoryMutationRunning)
  }

  func testApplySynchronizesFrozenReviewRescansAndReleasesLocks() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.parentURL) }
    try "remote change\n".write(
      to: fixture.seedURL.appendingPathComponent("remote.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "remote.md"], rootURL: fixture.seedURL)
    try git(["commit", "-m", "Remote change"], rootURL: fixture.seedURL)
    try git(["push", "origin", "main"], rootURL: fixture.seedURL)
    // Mirrors the original user-facing case: an untracked file collides with
    // a remote addition, but its bytes and mode are identical. The service
    // may reconcile this one narrow case without touching other WIP.
    try "remote change\n".write(
      to: fixture.localURL.appendingPathComponent("remote.md"),
      atomically: true,
      encoding: .utf8
    )

    let store = try TestWorkbenchFactory.makeStore(prefix: "RepositorySafeSyncApply")
    store.updateActiveProfile(fixture.profile)
    let preparation = await store.prepareRepositorySafeSync()
    guard case .confirmation(let confirmation) = preparation else {
      let message = store.publishActionFeedback?.message ?? "no feedback"
      return XCTFail("Expected a frozen safe-sync confirmation: \(message)")
    }

    let result = await store.applyRepositorySafeSync(confirmation)

    XCTAssertEqual(result?.branch, "main")
    XCTAssertEqual(
      result?.synchronizedHeadSHA, try git(["rev-parse", "HEAD"], rootURL: fixture.localURL))
    XCTAssertEqual(store.repositoryReport?.branchStatus?.behindCount, 0)
    XCTAssertEqual(store.publishActionFeedback?.status, .success)
    XCTAssertFalse(store.isLocalRepositoryBranchOperationRunning)
    XCTAssertFalse(store.isLocalRepositoryMutationRunning)
  }

  func testPrepareFailureReleasesLocksAndReportsBlockingMessage() async throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "RepositorySafeSyncInvalid")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = try TestWorkbenchFactory.makeStore(prefix: "RepositorySafeSyncFailure")
    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)

    let preparation = await store.prepareRepositorySafeSync()

    XCTAssertNil(preparation)
    XCTAssertEqual(store.publishActionFeedback?.status, .failure)
    XCTAssertFalse(store.isLocalRepositoryBranchOperationRunning)
    XCTAssertFalse(store.isLocalRepositoryMutationRunning)
  }

  func testStaleConfirmationAfterProfileSwitchDoesNotReplaceCurrentFeedback() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.parentURL) }
    try "remote change\n".write(
      to: fixture.seedURL.appendingPathComponent("remote.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "remote.md"], rootURL: fixture.seedURL)
    try git(["commit", "-m", "Remote change"], rootURL: fixture.seedURL)
    try git(["push", "origin", "main"], rootURL: fixture.seedURL)
    try "remote change\n".write(
      to: fixture.localURL.appendingPathComponent("remote.md"),
      atomically: true,
      encoding: .utf8
    )

    let store = try TestWorkbenchFactory.makeStore(prefix: "RepositorySafeSyncProfileSwitch")
    store.updateActiveProfile(fixture.profile)
    let preparation = await store.prepareRepositorySafeSync()
    guard case .confirmation(let confirmation) = preparation else {
      return XCTFail("Expected a frozen confirmation before switching profiles")
    }
    var other = SiteProfile.defaultProfile
    other.id = UUID()
    other.name = "Other site"
    store.setProfiles([fixture.profile, other])
    store.publishingStore.activeProfileID = other.id
    store.setPublishActionMessage("Current site feedback", status: .information)

    let result = await store.applyRepositorySafeSync(confirmation)

    XCTAssertNil(result)
    XCTAssertEqual(store.activeProfileID, other.id)
    XCTAssertEqual(store.publishActionFeedback?.message, "Current site feedback")
    XCTAssertFalse(store.isLocalRepositoryBranchOperationRunning)
    XCTAssertFalse(store.isLocalRepositoryMutationRunning)
  }

  func testRemotePublishingCannotStartWhileLocalMutationIsHeld() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "RepositorySafeSyncRemoteMutation")
    let operation = try XCTUnwrap(
      store.publishingStore.beginLocalRepositoryMutation(profile: store.activeProfile)
    )
    defer { store.publishingStore.finishLocalRepositoryMutation(operation) }

    XCTAssertNil(
      store.publishingStore.beginRemoteRepositoryMutation(
        profile: store.activeProfile, store: store)
    )
  }

  private func makeFixture() throws -> (
    parentURL: URL,
    localURL: URL,
    seedURL: URL,
    profile: SiteProfile
  ) {
    let parentURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "RepositorySafeSyncStore")
    let originURL = parentURL.appendingPathComponent("origin/repo.git")
    let localURL = parentURL.appendingPathComponent("local")
    let seedURL = parentURL.appendingPathComponent("seed")
    try FileManager.default.createDirectory(
      at: originURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try git(["init", "--bare", "--initial-branch=main", originURL.path], rootURL: parentURL)
    try git(["init", "-b", "main", localURL.path], rootURL: parentURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: localURL)
    try git(["config", "user.name", "Tests"], rootURL: localURL)
    try "initial\n".write(
      to: localURL.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "README.md"], rootURL: localURL)
    try git(["commit", "-m", "Initial"], rootURL: localURL)
    try git(["remote", "add", "origin", originURL.path], rootURL: localURL)
    try git(["push", "-u", "origin", "main"], rootURL: localURL)
    try git(["clone", originURL.path, seedURL.path], rootURL: parentURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: seedURL)
    try git(["config", "user.name", "Tests"], rootURL: seedURL)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(localURL)
    profile.branch = "main"
    profile.repoOwner = originURL.deletingLastPathComponent().lastPathComponent
    profile.repoName = "repo"
    return (parentURL, localURL, seedURL, profile)
  }

  @discardableResult
  private func git(_ arguments: [String], rootURL: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", rootURL.path] + arguments
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    let standardOutput =
      String(
        data: output.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    let standardError =
      String(
        data: error.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "RepositorySafeSyncStoreTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: standardOutput + standardError]
      )
    }
    return standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
