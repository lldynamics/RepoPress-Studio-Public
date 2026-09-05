import Foundation
import XCTest
import os

@testable import PublishingWorkbenchCore

final class RepositoryWorktreePushRetryServiceTests: XCTestCase {
  private struct Fixture {
    let baseURL: URL
    let worktreeURL: URL
    let remoteURL: URL
    let profile: SiteProfile
    let remoteBaseline: String
  }

  func testRebuildsReviewFromGitAndPushesLocalAheadCommit() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try "local committed change\n".write(
      to: fixture.worktreeURL.appendingPathComponent("tracked.md"),
      atomically: true,
      encoding: .utf8
    )
    _ = try git(["add", "--", "tracked.md"], at: fixture.worktreeURL)
    _ = try git(["commit", "-m", "local publish commit"], at: fixture.worktreeURL)
    let localHead = try git(["rev-parse", "HEAD"], at: fixture.worktreeURL)
      .trimmedForPublishing

    let service = RepositoryWorktreePushRetryService()
    let confirmation = try service.prepare(profile: fixture.profile)

    XCTAssertEqual(confirmation.snapshot.remoteBranchSHA, fixture.remoteBaseline)
    XCTAssertEqual(confirmation.snapshot.localHeadSHA, localHead)
    XCTAssertEqual(confirmation.snapshot.commitCount, 1)
    XCTAssertEqual(confirmation.snapshot.paths, ["tracked.md"])

    let incomplete = RepositoryWorktreePushRetryConfirmation(
      snapshot: confirmation.snapshot, safetyReport: confirmation.safetyReport,
      sitePreflightResult: confirmation.sitePreflightResult, fileReviews: [])
    XCTAssertThrowsError(try service.push(profile: fixture.profile, confirmation: incomplete)) {
      XCTAssertEqual($0 as? RepositoryWorktreePublishError, .incompleteReview)
    }
    XCTAssertEqual(try git(["rev-parse", "refs/heads/main"], at: fixture.remoteURL).trimmedForPublishing,
      fixture.remoteBaseline)

    let result = try service.push(profile: fixture.profile, confirmation: confirmation)
    XCTAssertTrue(result.pushed)
    XCTAssertEqual(result.commitSHA, localHead)
    XCTAssertEqual(
      try git(["rev-parse", "refs/heads/main"], at: fixture.remoteURL)
        .trimmedForPublishing,
      localHead
    )
  }

  func testRetryReviewSurvivesARecreatedServiceInstance() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try "recover after relaunch\n".write(
      to: fixture.worktreeURL.appendingPathComponent("tracked.md"),
      atomically: true,
      encoding: .utf8
    )
    _ = try git(["commit", "-am", "commit left after failed push"], at: fixture.worktreeURL)

    let firstReview = try RepositoryWorktreePushRetryService().prepare(profile: fixture.profile)
    let rebuiltReview = try RepositoryWorktreePushRetryService().prepare(profile: fixture.profile)

    XCTAssertEqual(rebuiltReview, firstReview)
  }

  func testRejectsDivergedRemoteInsteadOfForcePushing() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try "local change\n".write(
      to: fixture.worktreeURL.appendingPathComponent("tracked.md"),
      atomically: true,
      encoding: .utf8
    )
    _ = try git(["commit", "-am", "local"], at: fixture.worktreeURL)
    try advanceRemoteFromPeer(fixture)

    XCTAssertThrowsError(
      try RepositoryWorktreePushRetryService().prepare(profile: fixture.profile)
    ) { error in
      guard case .remoteOutOfDate = error as? RepositoryWorktreePublishError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertNotEqual(
      try git(["rev-parse", "refs/heads/main"], at: fixture.remoteURL)
        .trimmedForPublishing,
      try git(["rev-parse", "HEAD"], at: fixture.worktreeURL)
        .trimmedForPublishing
    )
  }

  func testRejectsNewWorktreeChangeBeforeRetry() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try "committed\n".write(
      to: fixture.worktreeURL.appendingPathComponent("tracked.md"),
      atomically: true,
      encoding: .utf8
    )
    _ = try git(["commit", "-am", "local"], at: fixture.worktreeURL)
    try "not reviewed\n".write(
      to: fixture.worktreeURL.appendingPathComponent("later.txt"),
      atomically: true,
      encoding: .utf8
    )

    XCTAssertThrowsError(
      try RepositoryWorktreePushRetryService().prepare(profile: fixture.profile)
    ) { error in
      guard case .invalidRepository(let message) = error as? RepositoryWorktreePublishError else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("未提交"))
    }
  }

  func testRejectsSensitivePathAlreadyCommittedByAnotherTool() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try "TOKEN=do-not-push\n".write(
      to: fixture.worktreeURL.appendingPathComponent(".env"),
      atomically: true,
      encoding: .utf8
    )
    _ = try git(["add", "--", ".env"], at: fixture.worktreeURL)
    _ = try git(["commit", "-m", "sensitive local commit"], at: fixture.worktreeURL)

    XCTAssertThrowsError(
      try RepositoryWorktreePushRetryService().prepare(profile: fixture.profile)
    ) { error in
      XCTAssertEqual(
        error as? RepositoryWorktreePublishError,
        .sensitivePaths([".env"])
      )
    }
    XCTAssertEqual(
      try git(["rev-parse", "refs/heads/main"], at: fixture.remoteURL)
        .trimmedForPublishing,
      fixture.remoteBaseline
    )
  }

  func testRejectsPushURLThatTargetsAnotherRepository() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let otherRemote = fixture.baseURL.appendingPathComponent("other.git", isDirectory: true)
    _ = try git(["init", "--bare", "-b", "main", otherRemote.path], at: fixture.baseURL)
    _ = try git(
      ["remote", "set-url", "--push", "origin", otherRemote.path],
      at: fixture.worktreeURL
    )
    try "local committed change\n".write(
      to: fixture.worktreeURL.appendingPathComponent("tracked.md"),
      atomically: true,
      encoding: .utf8
    )
    _ = try git(["commit", "-am", "local"], at: fixture.worktreeURL)

    XCTAssertThrowsError(
      try RepositoryWorktreePushRetryService().prepare(profile: fixture.profile)
    ) { error in
      guard case .originMismatch = error as? RepositoryWorktreePublishError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertEqual(
      try git(["rev-parse", "refs/heads/main"], at: fixture.remoteURL)
        .trimmedForPublishing,
      fixture.remoteBaseline
    )
  }

  func testRejectsCommittedGitLFSPointer() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try "*.bin filter=lfs diff=lfs merge=lfs -text\n".write(
      to: fixture.worktreeURL.appendingPathComponent(".gitattributes"),
      atomically: true,
      encoding: .utf8
    )
    try "version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 1\n".write(
      to: fixture.worktreeURL.appendingPathComponent("asset.bin"),
      atomically: true,
      encoding: .utf8
    )
    _ = try git(["add", "--", ".gitattributes", "asset.bin"], at: fixture.worktreeURL)
    _ = try git(["commit", "-m", "local LFS pointer"], at: fixture.worktreeURL)

    XCTAssertThrowsError(
      try RepositoryWorktreePushRetryService().prepare(profile: fixture.profile)
    ) { error in
      guard case .unsupportedPaths(let paths) = error as? RepositoryWorktreePublishError else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(paths, ["asset.bin"])
    }
  }

  func testAllowsPreflightDiagnosticsToChangeWhenTheOutcomeAndGitSnapshotRemainStable() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try "local committed change\n".write(
      to: fixture.worktreeURL.appendingPathComponent("tracked.md"),
      atomically: true,
      encoding: .utf8
    )
    try "base_url = \"https://example.com\"\n".write(
      to: fixture.worktreeURL.appendingPathComponent("config.toml"),
      atomically: true,
      encoding: .utf8
    )
    _ = try git(["add", "--", "tracked.md", "config.toml"], at: fixture.worktreeURL)
    _ = try git(["commit", "-m", "local Zola update"], at: fixture.worktreeURL)
    var profile = fixture.profile
    profile.siteKind = .zola
    let sequence = RetryPreflightSequence()
    let preflight = RepositoryPublishPreflightService(
      commandRunner: sequence.runner,
      trustedZolaExecutable: { "/usr/local/bin/zola" }
    )
    let service = RepositoryWorktreePushRetryService(sitePreflightService: preflight)

    let confirmation = try service.prepare(profile: profile)
    XCTAssertEqual(confirmation.sitePreflightResult?.outcome, .passed)
    let result = try service.push(profile: profile, confirmation: confirmation)

    XCTAssertTrue(result.pushed)
    XCTAssertEqual(sequence.commandCount, 4)
  }

  private func makeFixture() throws -> Fixture {
    let baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("repopress-push-retry-\(UUID().uuidString)", isDirectory: true)
    let worktreeURL = baseURL.appendingPathComponent("worktree", isDirectory: true)
    let ownerURL = baseURL.appendingPathComponent("owner", isDirectory: true)
    let remoteURL = ownerURL.appendingPathComponent("site.git", isDirectory: true)
    try FileManager.default.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: ownerURL, withIntermediateDirectories: true)
    _ = try git(["init", "--bare", "-b", "main", remoteURL.path], at: baseURL)
    _ = try git(["init", "-b", "main"], at: worktreeURL)
    _ = try git(["config", "user.email", "test@example.com"], at: worktreeURL)
    _ = try git(["config", "user.name", "RepoPress Tests"], at: worktreeURL)
    try "base\n".write(
      to: worktreeURL.appendingPathComponent("tracked.md"),
      atomically: true,
      encoding: .utf8
    )
    _ = try git(["add", "--", "tracked.md"], at: worktreeURL)
    _ = try git(["commit", "-m", "base"], at: worktreeURL)
    _ = try git(["remote", "add", "origin", remoteURL.path], at: worktreeURL)
    _ = try git(["push", "-u", "origin", "main"], at: worktreeURL)
    let baseline = try git(["rev-parse", "HEAD"], at: worktreeURL).trimmedForPublishing
    return Fixture(
      baseURL: baseURL,
      worktreeURL: worktreeURL,
      remoteURL: remoteURL,
      profile: SiteProfile(
        name: "Test",
        localRepositoryRootPath: worktreeURL.path,
        repoOwner: "owner",
        repoName: "site",
        branch: "main"
      ),
      remoteBaseline: baseline
    )
  }

  private func advanceRemoteFromPeer(_ fixture: Fixture) throws {
    let peerURL = fixture.baseURL.appendingPathComponent("peer", isDirectory: true)
    _ = try git(["clone", fixture.remoteURL.path, peerURL.path], at: fixture.baseURL)
    _ = try git(["config", "user.email", "peer@example.com"], at: peerURL)
    _ = try git(["config", "user.name", "Peer"], at: peerURL)
    try "peer change\n".write(
      to: peerURL.appendingPathComponent("peer.txt"),
      atomically: true,
      encoding: .utf8
    )
    _ = try git(["add", "--", "peer.txt"], at: peerURL)
    _ = try git(["commit", "-m", "peer advance"], at: peerURL)
    _ = try git(["push", "origin", "main"], at: peerURL)
  }

  @discardableResult
  private func git(_ arguments: [String], at rootURL: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", rootURL.path] + arguments
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let output = String(
      decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
    let error = String(
      decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "RepositoryWorktreePushRetryServiceTests.Git",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: error]
      )
    }
    return output
  }
}

private struct RetryPreflightSequenceState {
  var commandCount = 0
}

private final class RetryPreflightSequence: Sendable {
  private let state = OSAllocatedUnfairLock(initialState: RetryPreflightSequenceState())

  var runner: RepositoryPublishPreflightCommandRunner {
    RepositoryPublishPreflightCommandRunner { [state] command in
      let count = state.withLock { value in
        value.commandCount += 1
        return value.commandCount
      }
      return .init(
        termination: .exited,
        exitStatus: 0,
        standardOutput: "\(command.stage.rawValue) diagnostic run \(count)"
      )
    }
  }

  var commandCount: Int {
    state.withLock { $0.commandCount }
  }
}
