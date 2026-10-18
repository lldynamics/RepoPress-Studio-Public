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
