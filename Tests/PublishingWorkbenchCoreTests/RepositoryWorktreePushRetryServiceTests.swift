import Foundation
import PublishingGitCore
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
    XCTAssertEqual(
      try git(["rev-parse", "refs/heads/main"], at: fixture.remoteURL).trimmedForPublishing,
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

  func testRetryPushesOnlyTheCommitAndKeepsUncommittedEditsLocal() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try "committed\n".write(
      to: fixture.worktreeURL.appendingPathComponent("tracked.md"),
      atomically: true,
      encoding: .utf8
    )
    _ = try git(["commit", "-am", "local"], at: fixture.worktreeURL)
    let localHead = try git(["rev-parse", "HEAD"], at: fixture.worktreeURL)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try "not reviewed tracked\n".write(
      to: fixture.worktreeURL.appendingPathComponent("tracked.md"),
      atomically: true,
      encoding: .utf8
    )
    try "not reviewed untracked\n".write(
      to: fixture.worktreeURL.appendingPathComponent("later.txt"),
      atomically: true,
      encoding: .utf8
    )

    try writePushPolicyHook("#!/bin/sh\nexit 0\n", root: fixture.worktreeURL)
    var profile = fixture.profile
    profile.gitExecutionPolicy = try RepositoryGitExecutionPolicyService().trustingHooks(
      at: fixture.worktreeURL)
    let service = RepositoryWorktreePushRetryService()
    let confirmation = try service.prepare(profile: profile)
    XCTAssertEqual(confirmation.snapshot.paths, ["tracked.md"])
    let result = try service.push(profile: profile, confirmation: confirmation)

    XCTAssertEqual(result.commitSHA, localHead)
    XCTAssertFalse(
      try git(["ls-tree", "-r", "--name-only", "refs/heads/main"], at: fixture.remoteURL)
        .contains("later.txt"))
    XCTAssertEqual(
      try String(
        contentsOf: fixture.worktreeURL.appendingPathComponent("tracked.md"), encoding: .utf8),
      "not reviewed tracked\n")
    XCTAssertEqual(
      try git(["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktreeURL),
      " M tracked.md\n?? later.txt\n")
    XCTAssertEqual(
      try String(
        contentsOf: fixture.worktreeURL.appendingPathComponent("later.txt"), encoding: .utf8),
      "not reviewed untracked\n")
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

  func testRejectsSensitiveFilesRemovedOrRenamedInLaterOutgoingCommits() throws {
    for rename in [false, true] {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
      try "TEST_VALUE=history fixture\n".write(
        to: fixture.worktreeURL.appendingPathComponent(".env"),
        atomically: true, encoding: .utf8)
      _ = try git(["add", ".env"], at: fixture.worktreeURL)
      _ = try git(["commit", "-m", "historical sensitive path"], at: fixture.worktreeURL)
      if rename {
        _ = try git(["mv", ".env", "ordinary.txt"], at: fixture.worktreeURL)
      } else {
        _ = try git(["rm", ".env"], at: fixture.worktreeURL)
      }
      _ = try git(["commit", "-m", "clean final tree"], at: fixture.worktreeURL)
      XCTAssertThrowsError(
        try RepositoryWorktreePushRetryService().prepare(profile: fixture.profile)
      ) {
        XCTAssertEqual($0 as? RepositoryWorktreePublishError, .sensitivePaths([".env"]))
      }
      XCTAssertEqual(
        try git(["rev-parse", "main"], at: fixture.remoteURL).trimmedForPublishing,
        fixture.remoteBaseline)
    }
  }

  func testRejectsDeletedHistoricalLFSPointerWithoutCurrentAttributes() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try "version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 1\n".write(
      to: fixture.worktreeURL.appendingPathComponent("historical.bin"), atomically: true,
      encoding: .utf8)
    _ = try git(["add", "historical.bin"], at: fixture.worktreeURL)
    _ = try git(["commit", "-m", "historical pointer"], at: fixture.worktreeURL)
    _ = try git(["rm", "historical.bin"], at: fixture.worktreeURL)
    _ = try git(["commit", "-m", "remove pointer"], at: fixture.worktreeURL)
    XCTAssertThrowsError(try RepositoryWorktreePushRetryService().prepare(profile: fixture.profile))
    {
      XCTAssertEqual($0 as? RepositoryWorktreePublishError, .unsupportedPaths(["historical.bin"]))
    }
  }

  func testAllowsOrdinaryMultiCommitHistoryIncludingDeletedTemporaryArticle() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try "temporary article\n".write(
      to: fixture.worktreeURL.appendingPathComponent("temporary.md"),
      atomically: true, encoding: .utf8)
    _ = try git(["add", "temporary.md"], at: fixture.worktreeURL)
    _ = try git(["commit", "-m", "draft article"], at: fixture.worktreeURL)
    _ = try git(["rm", "temporary.md"], at: fixture.worktreeURL)
    try "final article\n".write(
      to: fixture.worktreeURL.appendingPathComponent("tracked.md"),
      atomically: true, encoding: .utf8)
    _ = try git(["commit", "-am", "final article"], at: fixture.worktreeURL)
    let service = RepositoryWorktreePushRetryService()
    let review = try service.prepare(profile: fixture.profile)
    XCTAssertEqual(review.snapshot.commitCount, 2)
    XCTAssertTrue(review.snapshot.isHistoryReviewComplete)
    XCTAssertEqual(review.snapshot.commitReviews.count, 2)
    XCTAssertTrue(
      review.snapshot.commitReviews.contains { commit in
        commit.fileReviews.contains { $0.patch.contains("temporary article") }
      })
    XCTAssertTrue(try service.push(profile: fixture.profile, confirmation: review).pushed)
  }

  func testReplacementCommitCannotHideSensitiveOutgoingHistory() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try "TEST_VALUE=replacement fixture\n".write(
      to: fixture.worktreeURL.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    _ = try git(["add", ".env"], at: fixture.worktreeURL)
    _ = try git(["commit", "-m", "sensitive original"], at: fixture.worktreeURL)
    let sensitiveCommit = try git(["rev-parse", "HEAD"], at: fixture.worktreeURL)
      .trimmedForPublishing
    _ = try git(["rm", ".env"], at: fixture.worktreeURL)
    try "final\n".write(
      to: fixture.worktreeURL.appendingPathComponent("tracked.md"), atomically: true,
      encoding: .utf8)
    _ = try git(["commit", "-am", "clean final tree"], at: fixture.worktreeURL)
    let baseTree = try git(["rev-parse", "origin/main^{tree}"], at: fixture.worktreeURL)
      .trimmedForPublishing
    let replacement = try git(
      ["commit-tree", baseTree, "-p", fixture.remoteBaseline, "-m", "clean replacement"],
      at: fixture.worktreeURL
    ).trimmedForPublishing
    _ = try git(["replace", sensitiveCommit, replacement], at: fixture.worktreeURL)
    XCTAssertFalse(
      try git(["ls-tree", sensitiveCommit], at: fixture.worktreeURL).contains(".env"))

    XCTAssertThrowsError(try RepositoryWorktreePushRetryService().prepare(profile: fixture.profile))
    {
      XCTAssertEqual($0 as? RepositoryWorktreePublishError, .sensitivePaths([".env"]))
    }
    XCTAssertEqual(
      try git(["rev-parse", "main"], at: fixture.remoteURL).trimmedForPublishing,
      fixture.remoteBaseline)
  }

  func testGraftedHistoryCannotHideDeletedLFSPointer() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try "version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 1\n".write(
      to: fixture.worktreeURL.appendingPathComponent("historical.bin"), atomically: true,
      encoding: .utf8)
    _ = try git(["add", "historical.bin"], at: fixture.worktreeURL)
    _ = try git(["commit", "-m", "hidden pointer"], at: fixture.worktreeURL)
    _ = try git(["rm", "historical.bin"], at: fixture.worktreeURL)
    try "final\n".write(
      to: fixture.worktreeURL.appendingPathComponent("tracked.md"), atomically: true,
      encoding: .utf8)
    _ = try git(["commit", "-am", "clean final tree"], at: fixture.worktreeURL)
    let head = try git(["rev-parse", "HEAD"], at: fixture.worktreeURL).trimmedForPublishing
    try "\(head) \(fixture.remoteBaseline)\n".write(
      to: fixture.worktreeURL.appendingPathComponent(".git/info/grafts"), atomically: true,
      encoding: .utf8)

    XCTAssertThrowsError(try RepositoryWorktreePushRetryService().prepare(profile: fixture.profile))
    {
      XCTAssertTrue($0.localizedDescription.contains("info/grafts"), $0.localizedDescription)
    }
    XCTAssertEqual(
      try git(["rev-parse", "main"], at: fixture.remoteURL).trimmedForPublishing,
      fixture.remoteBaseline)
  }

  func testPushRetryRunsPrePushWithExactFrozenRefs() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try "ahead\n".write(
      to: fixture.worktreeURL.appendingPathComponent("tracked.md"), atomically: true,
      encoding: .utf8)
    _ = try git(["commit", "-am", "local ahead"], at: fixture.worktreeURL)
    let head = try git(["rev-parse", "HEAD"], at: fixture.worktreeURL).trimmedForPublishing
    let marker = fixture.worktreeURL.appendingPathComponent(".git/push-policy-marker")
    try writePushPolicyHook("#!/bin/sh\ncat > '\(marker.path)'\n", root: fixture.worktreeURL)
    var profile = fixture.profile
    profile.gitExecutionPolicy = try RepositoryGitExecutionPolicyService().trustingHooks(
      at: fixture.worktreeURL)
    let service = RepositoryWorktreePushRetryService()
    let confirmation = try service.prepare(profile: profile)
    let result = try service.push(profile: profile, confirmation: confirmation)
    XCTAssertTrue(result.pushed)
    XCTAssertEqual(
      try String(contentsOf: marker, encoding: .utf8),
      "\(head) \(head) refs/heads/main \(fixture.remoteBaseline)\n")
  }

  func testPushRetryPolicyChangeInvalidatesReviewWithoutRunningHook() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    try "ahead\n".write(
      to: fixture.worktreeURL.appendingPathComponent("tracked.md"), atomically: true,
      encoding: .utf8)
    _ = try git(["commit", "-am", "local ahead"], at: fixture.worktreeURL)
    let service = RepositoryWorktreePushRetryService()
    let confirmation = try service.prepare(profile: fixture.profile)
    let marker = fixture.worktreeURL.appendingPathComponent(".git/push-policy-marker")
    try writePushPolicyHook("#!/bin/sh\ntouch '\(marker.path)'\n", root: fixture.worktreeURL)
    var profile = fixture.profile
    profile.gitExecutionPolicy = try RepositoryGitExecutionPolicyService().trustingHooks(
      at: fixture.worktreeURL)
    XCTAssertThrowsError(try service.push(profile: profile, confirmation: confirmation)) {
      XCTAssertEqual($0 as? RepositoryWorktreePublishError, .snapshotDrift)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertEqual(
      try git(["rev-parse", "main"], at: fixture.remoteURL).trimmedForPublishing,
      fixture.remoteBaseline)
  }

  func testPushRetryHookFailureAndMutationPreserveExistingCommitWithoutPushing() throws {
    for body in ["echo prepush-rejected >&2\nexit 4\n", "printf 'unreviewed\\n' >> tracked.md\n"] {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
      try "ahead\n".write(
        to: fixture.worktreeURL.appendingPathComponent("tracked.md"), atomically: true,
        encoding: .utf8)
      _ = try git(["commit", "-am", "local ahead"], at: fixture.worktreeURL)
      let head = try git(["rev-parse", "HEAD"], at: fixture.worktreeURL).trimmedForPublishing
      try writePushPolicyHook("#!/bin/sh\n" + body, root: fixture.worktreeURL)
      var profile = fixture.profile
      profile.gitExecutionPolicy = try RepositoryGitExecutionPolicyService().trustingHooks(
        at: fixture.worktreeURL)
      let service = RepositoryWorktreePushRetryService()
      let confirmation = try service.prepare(profile: profile)
      XCTAssertThrowsError(try service.push(profile: profile, confirmation: confirmation)) {
        error in
        guard
          case .commitSucceededButPushFailed(let sha, _) = error as? RepositoryWorktreePublishError
        else {
          return XCTFail("Expected already committed failure, received \(error)")
        }
        XCTAssertEqual(sha, head)
      }
      XCTAssertEqual(
        try git(["rev-parse", "HEAD"], at: fixture.worktreeURL).trimmedForPublishing, head)
      XCTAssertEqual(
        try git(["rev-parse", "main"], at: fixture.remoteURL).trimmedForPublishing,
        fixture.remoteBaseline)
    }
  }

  func testPushRetryRejectsTrustedHookRewritingExistingDirtyPath() throws {
    for (path, hookBody, expectedContent, expectedStatus) in [
      (
        "tracked.md", "printf 'hook changed tracked\\n' > tracked.md\n", "hook changed tracked\n",
        " M tracked.md\n"
      ),
      (
        "later.txt", "printf 'hook changed untracked\\n' > later.txt\n", "hook changed untracked\n",
        "?? later.txt\n"
      ),
    ] {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
      try "ahead\n".write(
        to: fixture.worktreeURL.appendingPathComponent("tracked.md"), atomically: true,
        encoding: .utf8)
      _ = try git(["commit", "-am", "local ahead"], at: fixture.worktreeURL)
      let head = try git(["rev-parse", "HEAD"], at: fixture.worktreeURL).trimmedForPublishing
      let dirtyPath = fixture.worktreeURL.appendingPathComponent(path)
      try "dirty before hook\n".write(to: dirtyPath, atomically: true, encoding: .utf8)
      try writePushPolicyHook("#!/bin/sh\n" + hookBody, root: fixture.worktreeURL)
      var profile = fixture.profile
      profile.gitExecutionPolicy = try RepositoryGitExecutionPolicyService().trustingHooks(
        at: fixture.worktreeURL)

      let service = RepositoryWorktreePushRetryService()
      let confirmation = try service.prepare(profile: profile)
      XCTAssertThrowsError(try service.push(profile: profile, confirmation: confirmation)) {
        error in
        guard
          case .commitSucceededButPushFailed(let sha, _) = error as? RepositoryWorktreePublishError
        else {
          return XCTFail("Expected already committed failure, received \(error)")
        }
        XCTAssertEqual(sha, head)
      }
      XCTAssertEqual(
        try git(["rev-parse", "HEAD"], at: fixture.worktreeURL).trimmedForPublishing, head)
      XCTAssertEqual(
        try git(["rev-parse", "main"], at: fixture.remoteURL).trimmedForPublishing,
        fixture.remoteBaseline)
      XCTAssertEqual(try String(contentsOf: dirtyPath, encoding: .utf8), expectedContent)
      XCTAssertEqual(
        try git(["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktreeURL),
        expectedStatus)
    }
  }

  private func writePushPolicyHook(_ script: String, root: URL) throws {
    let hook = root.appendingPathComponent(".git/hooks/pre-push")
    try script.write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: hook.path)
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

/// Focused coverage for publishing from a worktree whose branch already has
/// local commits. These tests intentionally stop before a successful publish,
/// so they never exercise a network push.
final class RepositoryWorktreeAheadPublishTests: XCTestCase {
  private struct Fixture {
    let base: URL
    let worktree: URL
    let remote: URL
    let profile: SiteProfile
    let baseline: String
  }

  func testCleanAheadPreparesWithHistoryAndDoesNotChangeWorktreeOrRemote() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }

    for index in 1...5 {
      _ = try git(
        ["commit", "--allow-empty", "-m", "local history \(index)"], at: fixture.worktree)
    }
    let localHead = try revision(at: fixture.worktree)
    let beforeStatus = try git(
      ["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktree)
    let confirmation = try RepositoryWorktreePublishService().prepare(
      profile: fixture.profile, commitMessage: "Publish local history")

    XCTAssertEqual(confirmation.snapshot.headSHA, localHead)
    XCTAssertEqual(confirmation.snapshot.remoteBranchSHA, fixture.baseline)
    XCTAssertTrue(confirmation.snapshot.entries.isEmpty)
    XCTAssertTrue(confirmation.snapshot.paths.isEmpty)
    let history = try XCTUnwrap(confirmation.snapshot.outgoingHistory)
    XCTAssertEqual(history.commitCount, 5)
    XCTAssertEqual(history.localHeadSHA, localHead)
    XCTAssertEqual(history.remoteBranchSHA, fixture.baseline)
    XCTAssertEqual(try revision(at: fixture.worktree), localHead)
    XCTAssertEqual(
      try git(["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktree),
      beforeStatus)
    XCTAssertEqual(try revision(at: fixture.remote), fixture.baseline)

    XCTAssertThrowsError(
      try RepositoryWorktreePublishService().publish(
        profile: fixture.profile, confirmation: confirmation
      ) { _ in
        throw NSError(
          domain: "RepositoryWorktreeAheadPublishTests.beforeMovingHead", code: 1)
      })
    XCTAssertEqual(try revision(at: fixture.worktree), localHead)
    XCTAssertEqual(try revision(at: fixture.remote), fixture.baseline)
  }

  func testScopedDirtyArticleExcludesUnrelatedEditsButRetainsOutgoingHistory() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }

    try write("historical article\n", to: fixture.worktree, path: "history.md")
    _ = try git(["add", "history.md"], at: fixture.worktree)
    _ = try git(["commit", "-m", "historical content"], at: fixture.worktree)
    try write("article draft\n", to: fixture.worktree, path: "content/posts/article.md")
    try write("private unrelated draft\n", to: fixture.worktree, path: "private.txt")

    let confirmation = try RepositoryWorktreePublishService().prepare(
      profile: fixture.profile,
      commitMessage: "Publish article",
      pathScope: ["content/posts/article.md"])

    XCTAssertEqual(confirmation.snapshot.paths, ["content/posts/article.md"])
    XCTAssertEqual(confirmation.snapshot.entries.map(\.path), ["content/posts/article.md"])
    let history = try XCTUnwrap(confirmation.snapshot.outgoingHistory)
    XCTAssertEqual(history.commitCount, 1)
    XCTAssertEqual(history.paths, ["history.md"])
    XCTAssertFalse(confirmation.snapshot.paths.contains("private.txt"))
    XCTAssertTrue(
      try git(["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktree)
        .contains("?? private.txt"))
  }

  func testAllDirtyReviewHasDirtyEntriesAndNoOutgoingHistory() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try write("article draft\n", to: fixture.worktree, path: "content/posts/article.md")
    try write("notes\n", to: fixture.worktree, path: "notes.txt")

    let confirmation = try RepositoryWorktreePublishService().prepare(
      profile: fixture.profile, commitMessage: "Review all changes")

    XCTAssertEqual(
      confirmation.snapshot.paths,
      ["content/posts/article.md", "notes.txt"])
    XCTAssertNil(confirmation.snapshot.outgoingHistory)
    XCTAssertEqual(confirmation.snapshot.headSHA, fixture.baseline)
  }

  func testCommittedThenRemovedSensitiveHistoryIsStillBlocked() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try write("TOKEN=history\n", to: fixture.worktree, path: ".env")
    _ = try git(["add", ".env"], at: fixture.worktree)
    _ = try git(["commit", "-m", "sensitive history"], at: fixture.worktree)
    _ = try git(["rm", ".env"], at: fixture.worktree)
    _ = try git(["commit", "-m", "remove sensitive history"], at: fixture.worktree)

    XCTAssertThrowsError(
      try RepositoryWorktreePublishService().prepare(
        profile: fixture.profile, commitMessage: "Review history")
    ) { error in
      XCTAssertEqual(error as? RepositoryWorktreePublishError, .sensitivePaths([".env"]))
    }
    XCTAssertEqual(try revision(at: fixture.remote), fixture.baseline)
  }

  func testCommittedThenRemovedDraftHistoryRemainsAnExplicitWarning() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try write(
      """
      +++
      title = "Historical draft"
      draft = true
      +++

      This source is removed from the final tree.
      """,
      to: fixture.worktree, path: "content/posts/historical-draft.md")
    _ = try git(["add", "content/posts/historical-draft.md"], at: fixture.worktree)
    _ = try git(["commit", "-m", "add historical draft"], at: fixture.worktree)
    _ = try git(["rm", "content/posts/historical-draft.md"], at: fixture.worktree)
    _ = try git(["commit", "-m", "remove historical draft"], at: fixture.worktree)

    let confirmation = try RepositoryWorktreePublishService().prepare(
      profile: fixture.profile, commitMessage: "Review removed draft")
    XCTAssertTrue(confirmation.snapshot.entries.isEmpty)
    XCTAssertEqual(
      confirmation.safetyReport.diagnostics.map(\.code), [.draftSourcePublication])
    XCTAssertTrue(confirmation.safetyReport.canPublish)
  }

  func testCommittedThenRemovedPrivateFrontMatterRemainsBlocked() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try write(
      """
      +++
      title = "Historical private"
      private = true
      +++

      This source is removed from the final tree.
      """,
      to: fixture.worktree, path: "content/posts/historical-private.md")
    _ = try git(["add", "content/posts/historical-private.md"], at: fixture.worktree)
    _ = try git(["commit", "-m", "add historical private"], at: fixture.worktree)
    _ = try git(["rm", "content/posts/historical-private.md"], at: fixture.worktree)
    _ = try git(["commit", "-m", "remove historical private"], at: fixture.worktree)

    XCTAssertThrowsError(
      try RepositoryWorktreePublishService().prepare(
        profile: fixture.profile, commitMessage: "Review removed private")
    ) { error in
      XCTAssertEqual(
        error as? RepositoryWorktreePublishError,
        .sensitivePaths(["content/posts/historical-private.md"]))
    }
  }

  func testCommittedThenRemovedPrivateDirectoryHistoryRemainsBlocked() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try write(
      """
      +++
      title = "Historical private directory content"
      +++

      This source is removed from the final tree.
      """,
      to: fixture.worktree, path: "private/posts/historical.md")
    _ = try git(["add", "private/posts/historical.md"], at: fixture.worktree)
    _ = try git(["commit", "-m", "add historical private directory content"], at: fixture.worktree)
    _ = try git(["rm", "private/posts/historical.md"], at: fixture.worktree)
    _ = try git(
      ["commit", "-m", "remove historical private directory content"], at: fixture.worktree)

    XCTAssertThrowsError(
      try RepositoryWorktreePublishService().prepare(
        profile: fixture.profile, commitMessage: "Review removed private directory")
    ) { error in
      XCTAssertEqual(
        error as? RepositoryWorktreePublishError,
        .sensitivePaths(["private/posts/historical.md"]))
    }
  }

  func testBehindDivergedAndStagedWorktreesRemainBlocked() throws {
    do {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      let peer = try clonePeer(from: fixture.remote, under: fixture.base, name: "behind-peer")
      try write("remote ahead\n", to: peer, path: "remote.txt")
      _ = try git(["add", "remote.txt"], at: peer)
      _ = try git(["commit", "-m", "remote ahead"], at: peer)
      _ = try git(["fetch", peer.path, "main:main"], at: fixture.remote)
      _ = try git(["fetch", "origin"], at: fixture.worktree)
      XCTAssertThrowsError(
        try RepositoryWorktreePublishService().prepare(
          profile: fixture.profile, commitMessage: "Behind")
      ) { error in
        guard case .remoteOutOfDate = error as? RepositoryWorktreePublishError else {
          return XCTFail("Expected remoteOutOfDate, got \(error)")
        }
      }
    }

    do {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      try write("local diverged\n", to: fixture.worktree, path: "local.txt")
      _ = try git(["add", "local.txt"], at: fixture.worktree)
      _ = try git(["commit", "-m", "local diverged"], at: fixture.worktree)
      let peer = try clonePeer(from: fixture.remote, under: fixture.base, name: "diverged-peer")
      try write("remote diverged\n", to: peer, path: "remote.txt")
      _ = try git(["add", "remote.txt"], at: peer)
      _ = try git(["commit", "-m", "remote diverged"], at: peer)
      _ = try git(["fetch", peer.path, "main:main"], at: fixture.remote)
      _ = try git(["fetch", "origin"], at: fixture.worktree)
      XCTAssertThrowsError(
        try RepositoryWorktreePublishService().prepare(
          profile: fixture.profile, commitMessage: "Diverged")
      ) { error in
        guard case .remoteOutOfDate = error as? RepositoryWorktreePublishError else {
          return XCTFail("Expected remoteOutOfDate, got \(error)")
        }
      }
    }

    do {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      try write("staged\n", to: fixture.worktree, path: "staged.txt")
      _ = try git(["add", "staged.txt"], at: fixture.worktree)
      XCTAssertThrowsError(
        try RepositoryWorktreePublishService().prepare(
          profile: fixture.profile, commitMessage: "Staged")
      ) { error in
        XCTAssertEqual(error as? RepositoryWorktreePublishError, .dirtyIndex(["staged.txt"]))
      }
    }
  }

  func testRemoteAndHeadDriftRejectsOldConfirmationBeforeMutation() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try write("first draft\n", to: fixture.worktree, path: "content/posts/article.md")
    let service = RepositoryWorktreePublishService()
    let confirmation = try service.prepare(
      profile: fixture.profile, commitMessage: "Old confirmation")

    _ = try git(["add", "content/posts/article.md"], at: fixture.worktree)
    _ = try git(["commit", "-m", "drift after review"], at: fixture.worktree)
    let driftedHead = try revision(at: fixture.worktree)
    XCTAssertThrowsError(try service.publish(profile: fixture.profile, confirmation: confirmation))
    {
      XCTAssertEqual($0 as? RepositoryWorktreePublishError, .snapshotDrift)
    }
    XCTAssertEqual(try revision(at: fixture.worktree), driftedHead)
    XCTAssertEqual(try revision(at: fixture.remote), fixture.baseline)
  }

  func testRemoteDriftRejectsOldConfirmationBeforeAnyPublishMutation() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try write("article draft\n", to: fixture.worktree, path: "content/posts/article.md")
    let service = RepositoryWorktreePublishService()
    let confirmation = try service.prepare(
      profile: fixture.profile, commitMessage: "Remote drift")
    let peer = try clonePeer(from: fixture.remote, under: fixture.base, name: "remote-drift-peer")
    try write("remote drift\n", to: peer, path: "remote.txt")
    _ = try git(["add", "remote.txt"], at: peer)
    _ = try git(["commit", "-m", "remote drift"], at: peer)
    _ = try git(["fetch", peer.path, "main:main"], at: fixture.remote)
    _ = try git(["fetch", "origin"], at: fixture.worktree)

    XCTAssertThrowsError(try service.publish(profile: fixture.profile, confirmation: confirmation))
    {
      guard case .remoteOutOfDate = $0 as? RepositoryWorktreePublishError else {
        return XCTFail("Expected remoteOutOfDate, got \($0)")
      }
    }
    XCTAssertEqual(try revision(at: fixture.worktree), fixture.baseline)
    XCTAssertEqual(try revision(at: fixture.remote), try revision(at: peer))
  }

  private func makeFixture() throws -> Fixture {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("repopress-ahead-\(UUID().uuidString)", isDirectory: true)
    let seed = base.appendingPathComponent("seed", isDirectory: true)
    let owner = base.appendingPathComponent("owner", isDirectory: true)
    let remote = owner.appendingPathComponent("site.git", isDirectory: true)
    let worktree = base.appendingPathComponent("worktree", isDirectory: true)
    try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
    _ = try git(["init", "-b", "main"], at: seed)
    try configure(seed)
    try write("base\n", to: seed, path: "README.md")
    _ = try git(["add", "README.md"], at: seed)
    _ = try git(["commit", "-m", "initial"], at: seed)
    _ = try git(["clone", "--bare", seed.path, remote.path], at: base)
    _ = try git(["clone", remote.path, worktree.path], at: base)
    try configure(worktree)
    let baseline = try revision(at: worktree)
    var profile = SiteProfile(
      name: "Test", localRepositoryRootPath: worktree.path,
      repoOwner: "owner", repoName: "site", branch: "main")
    profile.contentRoot = "content"
    return Fixture(
      base: base, worktree: worktree, remote: remote, profile: profile, baseline: baseline)
  }

  private func clonePeer(from remote: URL, under base: URL, name: String) throws -> URL {
    let peer = base.appendingPathComponent(name, isDirectory: true)
    _ = try git(["clone", remote.path, peer.path], at: base)
    try configure(peer)
    return peer
  }

  private func configure(_ root: URL) throws {
    _ = try git(["config", "user.email", "tests@example.com"], at: root)
    _ = try git(["config", "user.name", "RepoPress Tests"], at: root)
  }

  private func write(_ value: String, to root: URL, path: String) throws {
    let file = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try value.write(to: file, atomically: true, encoding: .utf8)
  }

  private func revision(at root: URL) throws -> String {
    try git(["rev-parse", "HEAD"], at: root).trimmedForPublishing
  }

  @discardableResult
  private func git(_ arguments: [String], at root: URL) throws -> String {
    let result = GitCommandRunner(timeout: 30).run(arguments, rootURL: root)
    guard result.terminationStatus == 0 else {
      throw NSError(
        domain: "RepositoryWorktreeAheadPublishTests.Git",
        code: Int(result.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: result.output])
    }
    return result.standardOutput
  }
}
