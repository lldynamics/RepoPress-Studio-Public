import Foundation
import PublishingCoreSupport
import PublishingDomainContracts
import PublishingGitCore
import XCTest
import os

@testable import PublishingWorkbenchCore

final class RepositoryWorktreePublishServiceTests: XCTestCase {
  private struct Fixture: Sendable {
    let base: URL
    let worktree: URL
    let remote: URL
    let profile: SiteProfile
    let initialSHA: String
  }

  func testRecordedPushCanBeReconciledAfterRestartWithoutTouchingNewLocalEdits() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("reviewed\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.md"))
    let service = RepositoryWorktreePublishService()
    let confirmation = try service.prepare(profile: fixture.profile, commitMessage: "Recorded push")
    let storageURL = fixture.base.appendingPathComponent("workbench.json")
    let journal = RepositoryWorktreePushRecoveryStore(workbenchFileURL: storageURL)
    let result = try service.publish(profile: fixture.profile, confirmation: confirmation) { sha in
      // The receipt is already durable before HEAD moves or a push starts.
      let head = GitCommandRunner().run(["rev-parse", "HEAD"], rootURL: fixture.worktree)
      XCTAssertEqual(head.standardOutput.trimmedForPublishing, fixture.initialSHA)
      try journal.save(.init(profile: fixture.profile, confirmation: confirmation, commitSHA: sha))
    }
    // Simulate losing the application acknowledgement, then editing again.
    let newDocument = "new local edits after upload\n"
    try Data(newDocument.utf8).write(to: fixture.worktree.appendingPathComponent("tracked.md"))
    let reopened = RepositoryWorktreePushRecoveryStore(workbenchFileURL: storageURL)
    let receipt = try XCTUnwrap(reopened.records(profileID: fixture.profile.id).first)
    let retry = RepositoryWorktreePushRetryService()
    XCTAssertEqual(try retry.confirmedRecordedPush(receipt, profile: fixture.profile), result)
    XCTAssertEqual(try retry.confirmedRecordedPush(receipt, profile: fixture.profile), result)
    XCTAssertEqual(
      try String(
        contentsOf: fixture.worktree.appendingPathComponent("tracked.md"), encoding: .utf8),
      newDocument)
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing, result.commitSHA)
    var otherProfile = fixture.profile
    otherProfile.repoName = "another-repository"
    XCTAssertThrowsError(try retry.confirmedRecordedPush(receipt, profile: otherProfile))
    try reopened.remove(receipt)
    XCTAssertTrue(try reopened.records(profileID: fixture.profile.id).isEmpty)
  }

  func testRecoveryReceiptFailurePreventsHeadChangeAndPush() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("reviewed\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.md"))
    let service = RepositoryWorktreePublishService()
    let confirmation = try service.prepare(profile: fixture.profile, commitMessage: "Receipt fails")
    XCTAssertThrowsError(
      try service.publish(profile: fixture.profile, confirmation: confirmation) { _ in
        throw CocoaError(.fileWriteOutOfSpace)
      })
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing, fixture.initialSHA)
    XCTAssertEqual(
      try git(["rev-parse", "main"], at: fixture.remote).trimmedForPublishing, fixture.initialSHA)
    XCTAssertTrue(try git(["diff", "--cached", "--name-only"], at: fixture.worktree).isEmpty)
  }

  func testPublishesAllModifiedDeletedUntrackedBinaryAndExecutableFiles() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }

    try Data("changed\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.md"))
    try FileManager.default.removeItem(
      at: fixture.worktree.appendingPathComponent("remove-me.txt")
    )
    try Data([0x00, 0xFF, 0x01, 0x0A]).write(
      to: fixture.worktree.appendingPathComponent("素材.bin")
    )
    let script = fixture.worktree.appendingPathComponent("deploy script.sh")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o755))],
      ofItemAtPath: script.path
    )

    let service = RepositoryWorktreePublishService()
    let confirmation = try service.prepare(
      profile: fixture.profile,
      commitMessage: "Publish every file"
    )

    XCTAssertEqual(
      Set(confirmation.snapshot.paths),
      ["deploy script.sh", "remove-me.txt", "tracked.md", "素材.bin"]
    )
    XCTAssertEqual(
      confirmation.snapshot.entries.first(where: { $0.path == "deploy script.sh" })?.mode,
      "100755"
    )
    XCTAssertEqual(
      confirmation.snapshot.entries.first(where: { $0.path == "remove-me.txt" })?.kind,
      .deleted
    )

    let incomplete = RepositoryWorktreePublishConfirmation(
      snapshot: confirmation.snapshot, commitMessage: confirmation.commitMessage,
      safetyReport: confirmation.safetyReport,
      sitePreflightResult: confirmation.sitePreflightResult,
      fileReviews: [])
    XCTAssertThrowsError(try service.publish(profile: fixture.profile, confirmation: incomplete)) {
      XCTAssertEqual($0 as? RepositoryWorktreePublishError, .incompleteReview)
    }
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing,
      fixture.initialSHA)

    let result = try service.publish(profile: fixture.profile, confirmation: confirmation)

    XCTAssertTrue(result.pushed)
    XCTAssertEqual(Set(result.committedPaths), Set(confirmation.snapshot.paths))
    XCTAssertEqual(
      try git(["rev-parse", "refs/heads/main"], at: fixture.remote).trimmedForPublishing,
      result.commitSHA
    )
    XCTAssertTrue(
      try git(
        ["status", "--porcelain=v1", "--untracked-files=all"],
        at: fixture.worktree
      ).isEmpty
    )
    let remotePaths = try git(
      ["ls-tree", "-r", "-z", "--name-only", "refs/heads/main"],
      at: fixture.remote
    ).split(separator: "\0").map(String.init)
    XCTAssertEqual(
      Set(remotePaths),
      ["deploy script.sh", "tracked.md", "素材.bin"]
    )
  }

  func testScopedPublishCommitsOnlyScopedPathsAndKeepsOtherEditsLocal() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let postsURL = fixture.worktree.appendingPathComponent("content/posts", isDirectory: true)
    try FileManager.default.createDirectory(at: postsURL, withIntermediateDirectories: true)
    try Data("article\n".utf8).write(to: postsURL.appendingPathComponent("hello*world.md"))
    try Data([0x01, 0x02]).write(to: postsURL.appendingPathComponent("cover.png"))
    try Data("unrelated edit\n".utf8).write(
      to: fixture.worktree.appendingPathComponent("tracked.md"))
    try Data("theme\n".utf8).write(to: fixture.worktree.appendingPathComponent("theme.css"))
    // A glob-looking sibling must not be swept in by the literal pathspec.
    try Data("sibling\n".utf8).write(to: postsURL.appendingPathComponent("hello-world.md"))

    let service = RepositoryWorktreePublishService()
    let scope = [
      "content/posts/hello*world.md", "content/posts/cover.png", "content/posts/missing.png",
    ]
    let confirmation = try service.prepare(
      profile: fixture.profile, commitMessage: "Publish one article", pathScope: scope)

    XCTAssertEqual(confirmation.pathScope, scope.sorted())
    XCTAssertEqual(
      Set(confirmation.snapshot.paths), ["content/posts/cover.png", "content/posts/hello*world.md"])

    // Unrelated edits after the review neither drift the scope nor get committed.
    try Data("another unrelated edit\n".utf8).write(
      to: fixture.worktree.appendingPathComponent("tracked.md"))
    let result = try service.publish(profile: fixture.profile, confirmation: confirmation)

    XCTAssertTrue(result.pushed)
    XCTAssertEqual(Set(result.committedPaths), Set(confirmation.snapshot.paths))
    let remotePaths = try git(
      ["ls-tree", "-r", "-z", "--name-only", "refs/heads/main"], at: fixture.remote
    ).split(separator: "\0").map(String.init)
    XCTAssertEqual(
      Set(remotePaths),
      ["content/posts/cover.png", "content/posts/hello*world.md", "remove-me.txt", "tracked.md"])
    XCTAssertEqual(
      try git(["show", "refs/heads/main:tracked.md"], at: fixture.remote), "base\n")
    let status = try git(
      ["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktree)
    XCTAssertEqual(
      Set(status.split(separator: "\n").map(String.init)),
      [" M tracked.md", "?? content/posts/hello-world.md", "?? theme.css"])
    XCTAssertTrue(try git(["diff", "--cached", "--name-only"], at: fixture.worktree).isEmpty)
  }

  func testScopedPublishRejectsScopeDriftAndStagedPathsOutsideTheScope() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("article\n".utf8).write(to: fixture.worktree.appendingPathComponent("article.md"))
    let service = RepositoryWorktreePublishService()

    XCTAssertThrowsError(
      try service.prepare(
        profile: fixture.profile, commitMessage: "Nothing", pathScope: ["none.md"])
    ) { XCTAssertEqual($0 as? RepositoryWorktreePublishError, .noChanges) }
    XCTAssertThrowsError(
      try service.prepare(profile: fixture.profile, commitMessage: "Escape", pathScope: ["../x.md"])
    ) { XCTAssertEqual($0 as? RepositoryWorktreePublishError, .unsupportedPaths(["../x.md"])) }

    let confirmation = try service.prepare(
      profile: fixture.profile, commitMessage: "Article", pathScope: ["article.md"])
    try Data("edited after review\n".utf8).write(
      to: fixture.worktree.appendingPathComponent("article.md"))
    XCTAssertThrowsError(try service.publish(profile: fixture.profile, confirmation: confirmation))
    {
      XCTAssertEqual($0 as? RepositoryWorktreePublishError, .snapshotDrift)
    }

    // The committed tree replaces the real index, so a staged path anywhere
    // in the repository must block the scoped publish without touching it.
    try Data("staged\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.md"))
    _ = try git(["add", "--", "tracked.md"], at: fixture.worktree)
    XCTAssertThrowsError(
      try service.prepare(
        profile: fixture.profile, commitMessage: "Article", pathScope: ["article.md"])
    ) { XCTAssertEqual($0 as? RepositoryWorktreePublishError, .dirtyIndex(["tracked.md"])) }
    XCTAssertEqual(
      try git(["diff", "--cached", "--name-only"], at: fixture.worktree), "tracked.md\n")
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing, fixture.initialSHA)
  }

  func testRejectsDirtyIndexWithoutChangingIt() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("changed\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.md"))
    _ = try git(["add", "--", "tracked.md"], at: fixture.worktree)
    let stagedBefore = try git(["diff", "--cached", "--name-only"], at: fixture.worktree)

    XCTAssertThrowsError(
      try RepositoryWorktreePublishService().prepare(
        profile: fixture.profile,
        commitMessage: "Publish"
      )
    ) { error in
      guard case .dirtyIndex(let paths) = error as? RepositoryWorktreePublishError else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(paths, ["tracked.md"])
    }
    XCTAssertEqual(
      try git(["diff", "--cached", "--name-only"], at: fixture.worktree),
      stagedBefore
    )
  }

  func testUsesGitDefaultWhenCoreFileModeIsUnset() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    _ = try git(["config", "--unset", "core.filemode"], at: fixture.worktree)
    try Data("changed\n".utf8).write(
      to: fixture.worktree.appendingPathComponent("tracked.md")
    )

    let confirmation = try RepositoryWorktreePublishService().prepare(
      profile: fixture.profile,
      commitMessage: "Publish"
    )

    XCTAssertEqual(confirmation.snapshot.paths, ["tracked.md"])
  }

  func testRejectsSensitivePathBeforeMutation() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("TOKEN=secret\n".utf8).write(to: fixture.worktree.appendingPathComponent(".env"))

    XCTAssertThrowsError(
      try RepositoryWorktreePublishService().prepare(
        profile: fixture.profile,
        commitMessage: "Publish"
      )
    ) { error in
      XCTAssertEqual(error as? RepositoryWorktreePublishError, .sensitivePaths([".env"]))
    }
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing,
      fixture.initialSHA
    )
  }

  func testRejectsPushURLThatTargetsAnotherRepository() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let otherRemote = fixture.base.appendingPathComponent("other.git", isDirectory: true)
    _ = try git(["init", "--bare", "-b", "main", otherRemote.path], at: fixture.base)
    _ = try git(["remote", "set-url", "--push", "origin", otherRemote.path], at: fixture.worktree)
    try Data("changed\n".utf8).write(
      to: fixture.worktree.appendingPathComponent("tracked.md")
    )

    XCTAssertThrowsError(
      try RepositoryWorktreePublishService().prepare(
        profile: fixture.profile,
        commitMessage: "Publish"
      )
    ) { error in
      guard case .originMismatch = error as? RepositoryWorktreePublishError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing,
      fixture.initialSHA
    )
  }

  func testRejectsContentDriftAndLeavesIndexAndHistoryUntouched() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let file = fixture.worktree.appendingPathComponent("tracked.md")
    try Data("reviewed\n".utf8).write(to: file)
    let service = RepositoryWorktreePublishService()
    let confirmation = try service.prepare(
      profile: fixture.profile,
      commitMessage: "Publish"
    )
    try Data("changed after review\n".utf8).write(to: file)

    XCTAssertThrowsError(
      try service.publish(profile: fixture.profile, confirmation: confirmation)
    ) { error in
      XCTAssertEqual(error as? RepositoryWorktreePublishError, .snapshotDrift)
    }
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing,
      fixture.initialSHA
    )
    XCTAssertTrue(try git(["diff", "--cached", "--name-only"], at: fixture.worktree).isEmpty)
  }

  func testConcurrentRealIndexAddIsExcludedAndNeverReset() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("reviewed\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.md"))
    let confirmation = try RepositoryWorktreePublishService().prepare(
      profile: fixture.profile,
      commitMessage: "Publish reviewed file"
    )
    let worktree = fixture.worktree
    let service = RepositoryWorktreePublishService(
      gitCommandRunner: GitCommandRunner(),
      testingAfterCompareAndSwap: {
        let external = worktree.appendingPathComponent("external-staged.txt")
        try? Data("must remain preserved\n".utf8).write(to: external)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", worktree.path, "add", "--", "external-staged.txt"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
      }
    )

    XCTAssertThrowsError(try service.publish(profile: fixture.profile, confirmation: confirmation))
    { error in
      guard case .commitSucceededButPushFailed = error as? RepositoryWorktreePublishError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    let treePaths = try git(["ls-tree", "-r", "--name-only", "HEAD"], at: fixture.worktree)
    XCTAssertTrue(treePaths.contains("tracked.md"))
    XCTAssertFalse(treePaths.contains("external-staged.txt"))
    XCTAssertEqual(
      try String(
        contentsOf: fixture.worktree.appendingPathComponent("external-staged.txt"),
        encoding: .utf8
      ),
      "must remain preserved\n"
    )
    let status = try git(
      ["status", "--porcelain=v1", "--untracked-files=all"],
      at: fixture.worktree
    )
    XCTAssertTrue(status.contains("?? external-staged.txt"))
    XCTAssertEqual(
      try git(["show", "HEAD:tracked.md"], at: fixture.worktree),
      "reviewed\n"
    )
  }

  func testRecoversInterruptedHeadIndexTransitionByCASRollingBackTheAppCommit() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let tree = try git(["rev-parse", "HEAD^{tree}"], at: fixture.worktree)
      .trimmedForPublishing
    let pendingCommit = try git(
      ["commit-tree", tree, "-p", fixture.initialSHA, "-m", "interrupted publish"],
      at: fixture.worktree
    ).trimmedForPublishing
    let fingerprint = try git(
      ["ls-files", "--stage", "-z"],
      at: fixture.worktree
    )
    let indexPath = try git(
      ["rev-parse", "--git-path", "index"],
      at: fixture.worktree
    ).trimmedForPublishing
    let indexURL = URL(fileURLWithPath: indexPath, relativeTo: fixture.worktree)
      .standardizedFileURL
    let coordinator = RepositoryWorktreePublishTransitionCoordinator(
      gitCommandRunner: GitCommandRunner()
    )
    let transition = try coordinator.begin(
      root: fixture.worktree,
      branch: "main",
      previousHeadSHA: fixture.initialSHA,
      commitSHA: pendingCommit,
      previousIndexFingerprint: fingerprint,
      indexURL: indexURL
    )
    let lock = try coordinator.acquireIndexLock(for: transition)
    _ = try git(
      ["update-ref", "refs/heads/main", pendingCommit, fixture.initialSHA],
      at: fixture.worktree
    )
    try lock.handle.close()

    try coordinator.recoverIfNeeded(profile: fixture.profile, root: fixture.worktree)

    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing,
      fixture.initialSHA
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: transition.journalURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: transition.markerURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: transition.indexLockURL.path))
    XCTAssertTrue(
      try git(["status", "--porcelain=v1"], at: fixture.worktree).isEmpty
    )
  }

  func testStopsPushWhenAnotherToolAdvancesHEADBeforePush() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("reviewed\n".utf8).write(
      to: fixture.worktree.appendingPathComponent("tracked.md")
    )
    let confirmation = try RepositoryWorktreePublishService().prepare(
      profile: fixture.profile,
      commitMessage: "Publish reviewed file"
    )
    let externalHead = OSAllocatedUnfairLock<String?>(initialState: nil)
    let worktree = fixture.worktree
    let service = RepositoryWorktreePublishService(
      gitCommandRunner: GitCommandRunner(),
      testingAfterCompareAndSwap: {
        let runner = GitCommandRunner()
        let reviewed = runner.run(["rev-parse", "HEAD"], rootURL: worktree)
          .standardOutput.trimmedForPublishing
        let tree = runner.run(["rev-parse", "HEAD^{tree}"], rootURL: worktree)
          .standardOutput.trimmedForPublishing
        let next = runner.run(
          ["commit-tree", tree, "-p", reviewed, "-m", "external follow-up"],
          rootURL: worktree
        ).standardOutput.trimmedForPublishing
        let update = runner.run(
          ["update-ref", "refs/heads/main", next, reviewed],
          rootURL: worktree
        )
        if update.terminationStatus == 0, !next.isEmpty {
          externalHead.withLock { $0 = next }
        }
      }
    )

    var frozenSHA: String?
    XCTAssertThrowsError(try service.publish(profile: fixture.profile, confirmation: confirmation))
    {
      error in
      guard case RepositoryWorktreePublishError.commitSucceededButPushFailed(let sha, _) = error
      else {
        return XCTFail("Expected preserved local commit without push, got \(error)")
      }
      frozenSHA = sha
    }
    let advancedHead = try XCTUnwrap(externalHead.withLock { $0 })
    XCTAssertEqual(
      try git(["rev-parse", "HEAD^"], at: fixture.worktree).trimmedForPublishing,
      try XCTUnwrap(frozenSHA))
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing, advancedHead)
    XCTAssertEqual(
      try git(["rev-parse", "refs/heads/main"], at: fixture.remote).trimmedForPublishing,
      confirmation.snapshot.remoteBranchSHA)
    XCTAssertEqual(
      try git(["show", "HEAD:tracked.md"], at: fixture.worktree), "reviewed\n")
  }

  func testFreezesModifiedDiskPackageInsteadOfOldHEADBlob() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let content = fixture.worktree.appendingPathComponent("content", isDirectory: true)
    try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
    let package = content.appendingPathComponent("package.md")
    try Data("old package\n".utf8).write(to: package)
    _ = try git(["add", "--", "content/package.md"], at: fixture.worktree)
    _ = try git(["commit", "-m", "add package"], at: fixture.worktree)
    _ = try git(["push", "origin", "main"], at: fixture.worktree)
    let headBlob = try git(
      ["rev-parse", "HEAD:content/package.md"],
      at: fixture.worktree
    ).trimmedForPublishing

    try Data("new package on disk\n".utf8).write(to: package)
    XCTAssertEqual(
      try git(["status", "--porcelain=v1", "--", "content/package.md"], at: fixture.worktree),
      " M content/package.md\n"
    )

    let service = RepositoryWorktreePublishService()
    let confirmation = try service.prepare(
      profile: fixture.profile, commitMessage: "Publish package")
    let entry = try XCTUnwrap(
      confirmation.snapshot.entries.first(where: { $0.path == "content/package.md" })
    )
    let diskBlob = try git(["hash-object", "--", "content/package.md"], at: fixture.worktree)
      .trimmedForPublishing
    XCTAssertEqual(entry.blobOID, diskBlob)
    XCTAssertNotEqual(entry.blobOID, headBlob)

    let result = try service.publish(profile: fixture.profile, confirmation: confirmation)
    XCTAssertEqual(
      try git(["show", "refs/heads/main:content/package.md"], at: fixture.remote),
      "new package on disk\n"
    )
    XCTAssertEqual(
      result.commitSHA,
      try git(["rev-parse", "refs/heads/main"], at: fixture.remote).trimmedForPublishing)
  }

  func testRejectsRemoteAdvanceBeforeAnyLocalMutation() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("local change\n".utf8).write(
      to: fixture.worktree.appendingPathComponent("tracked.md")
    )
    let service = RepositoryWorktreePublishService()
    let confirmation = try service.prepare(
      profile: fixture.profile,
      commitMessage: "Publish"
    )

    let peer = fixture.base.appendingPathComponent("peer", isDirectory: true)
    _ = try git(["clone", fixture.remote.path, peer.path], at: fixture.base)
    _ = try git(["config", "user.email", "peer@example.com"], at: peer)
    _ = try git(["config", "user.name", "Peer"], at: peer)
    try Data("remote change\n".utf8).write(to: peer.appendingPathComponent("remote.md"))
    _ = try git(["add", "--", "remote.md"], at: peer)
    _ = try git(["commit", "-m", "remote advance"], at: peer)
    _ = try git(["push", "origin", "main"], at: peer)

    XCTAssertThrowsError(
      try service.publish(profile: fixture.profile, confirmation: confirmation)
    ) { error in
      guard case .remoteOutOfDate = error as? RepositoryWorktreePublishError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing,
      fixture.initialSHA
    )
    XCTAssertTrue(try git(["diff", "--cached", "--name-only"], at: fixture.worktree).isEmpty)
  }

  func testBlocksStructuralIndexDeletionBeforeMutation() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let content = fixture.worktree.appendingPathComponent("content", isDirectory: true)
    try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
    try Data("+++\ntitle = \"Posts\"\n+++\n".utf8).write(
      to: content.appendingPathComponent("_index.md")
    )
    _ = try git(["add", "--", "content/_index.md"], at: fixture.worktree)
    _ = try git(["commit", "-m", "add structure"], at: fixture.worktree)
    _ = try git(["push", "origin", "main"], at: fixture.worktree)
    let headBefore = try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing
    try FileManager.default.removeItem(at: content.appendingPathComponent("_index.md"))

    let confirmation = try RepositoryWorktreePublishService().prepare(
      profile: fixture.profile,
      commitMessage: "Delete structure"
    )
    XCTAssertEqual(confirmation.safetyReport.warnings.map(\.code), [.structuralDelete])
    XCTAssertTrue(confirmation.safetyReport.canPublish)
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing,
      headBefore
    )
    XCTAssertTrue(try git(["diff", "--cached", "--name-only"], at: fixture.worktree).isEmpty)
  }

  func testRerunsSitePreflightBeforeMutationAndBlocksNewFailure() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("changed\n".utf8).write(
      to: fixture.worktree.appendingPathComponent("tracked.md")
    )
    try Data("base_url = \"https://example.com\"\n".utf8).write(
      to: fixture.worktree.appendingPathComponent("config.toml")
    )
    let sequence = PreflightSequence(results: [
      .init(termination: .exited, exitStatus: 0),
      .init(termination: .exited, exitStatus: 0),
      .init(termination: .exited, exitStatus: 1, standardError: "new Zola failure"),
    ])
    let preflight = RepositoryPublishPreflightService(
      commandRunner: sequence.runner,
      trustedZolaExecutable: { "/usr/local/bin/zola" }
    )
    let service = RepositoryWorktreePublishService(sitePreflightService: preflight)
    let confirmation = try service.prepare(profile: fixture.profile, commitMessage: "Publish")

    XCTAssertThrowsError(
      try service.publish(profile: fixture.profile, confirmation: confirmation)
    ) { error in
      guard case .sitePreflightFailed(let message) = error as? RepositoryWorktreePublishError else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("Zola 检查失败"))
    }
    XCTAssertEqual(sequence.commandCount, 3)
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing,
      fixture.initialSHA
    )
    XCTAssertTrue(try git(["diff", "--cached", "--name-only"], at: fixture.worktree).isEmpty)
  }

  func testExecutionPolicyChangeInvalidatesConfirmationBeforeRunningHooks() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("changed\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.md"))
    let service = RepositoryWorktreePublishService()
    let confirmation = try service.prepare(profile: fixture.profile, commitMessage: "Reviewed")
    let marker = fixture.worktree.appendingPathComponent(".git/policy-hook-marker")
    try writePolicyHook(
      "#!/bin/sh\ntouch '\(marker.path)'\n", name: "pre-commit", root: fixture.worktree)
    var profile = fixture.profile
    profile.gitExecutionPolicy = try RepositoryGitExecutionPolicyService().trustingHooks(
      at: fixture.worktree)
    XCTAssertThrowsError(try service.publish(profile: profile, confirmation: confirmation)) {
      XCTAssertEqual($0 as? RepositoryWorktreePublishError, .snapshotDrift)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing, fixture.initialSHA)
  }

  func testTrustedHooksRunFullExplicitLifecycleBeforeExactPush() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("changed\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.md"))
    let marker = fixture.worktree.appendingPathComponent(".git/policy-hooks")
    for name in ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "pre-push"] {
      let input = name == "pre-push" ? "cat >> '\(marker.path)'\n" : ""
      try writePolicyHook(
        "#!/bin/sh\nprintf '%s\\n' '\(name)' >> '\(marker.path)'\n" + input, name: name,
        root: fixture.worktree)
    }
    var profile = fixture.profile
    profile.gitExecutionPolicy = try RepositoryGitExecutionPolicyService().trustingHooks(
      at: fixture.worktree)
    let service = RepositoryWorktreePublishService()
    let confirmation = try service.prepare(profile: profile, commitMessage: "Hook-reviewed commit")
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    let result = try service.publish(profile: profile, confirmation: confirmation)
    let lines = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").map(
      String.init)
    XCTAssertEqual(
      Array(lines.prefix(5)),
      ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "pre-push"])
    XCTAssertEqual(
      lines.last, "\(result.commitSHA) \(result.commitSHA) refs/heads/main \(fixture.initialSHA)")
    XCTAssertTrue(result.pushed)
  }

  func testPreCommitFailureLeavesLocalAndRemoteHeadUnchanged() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("changed\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.md"))
    try writePolicyHook(
      "#!/bin/sh\necho rejected >&2\nexit 9\n", name: "pre-commit", root: fixture.worktree)
    var profile = fixture.profile
    profile.gitExecutionPolicy = try RepositoryGitExecutionPolicyService().trustingHooks(
      at: fixture.worktree)
    let service = RepositoryWorktreePublishService()
    let confirmation = try service.prepare(profile: profile, commitMessage: "Rejected")
    XCTAssertThrowsError(try service.publish(profile: profile, confirmation: confirmation)) {
      error in
      XCTAssertTrue(error.localizedDescription.contains("pre-commit"))
    }
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing, fixture.initialSHA)
    XCTAssertEqual(
      try git(["rev-parse", "main"], at: fixture.remote).trimmedForPublishing, fixture.initialSHA)
    XCTAssertTrue(try git(["diff", "--cached", "--name-only"], at: fixture.worktree).isEmpty)
  }

  func testHooksCannotAbsorbChangedWorkingFileOrExtraStagedFile() throws {
    for hookBody in [
      "printf 'unreviewed\\n' >> tracked.md\n",
      "printf 'extra\\n' > extra.md\ngit add extra.md\n",
    ] {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      try Data("changed\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.md"))
      try writePolicyHook("#!/bin/sh\n" + hookBody, name: "pre-commit", root: fixture.worktree)
      var profile = fixture.profile
      profile.gitExecutionPolicy = try RepositoryGitExecutionPolicyService().trustingHooks(
        at: fixture.worktree)
      let service = RepositoryWorktreePublishService()
      let confirmation = try service.prepare(profile: profile, commitMessage: "Frozen content")
      XCTAssertThrowsError(try service.publish(profile: profile, confirmation: confirmation)) {
        XCTAssertEqual($0 as? RepositoryGitExecutionPolicyError, .reviewedContentChanged)
      }
      XCTAssertEqual(
        try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing,
        fixture.initialSHA)
      XCTAssertTrue(try git(["diff", "--cached", "--name-only"], at: fixture.worktree).isEmpty)
    }
  }

  func testScopedPublishHooksCannotTouchFilesOutsideTheScope() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("article\n".utf8).write(to: fixture.worktree.appendingPathComponent("article.md"))
    try writePolicyHook(
      "#!/bin/sh\nprintf 'hook\\n' >> tracked.md\n", name: "pre-commit", root: fixture.worktree)
    var profile = fixture.profile
    profile.gitExecutionPolicy = try RepositoryGitExecutionPolicyService().trustingHooks(
      at: fixture.worktree)
    let service = RepositoryWorktreePublishService()
    let confirmation = try service.prepare(
      profile: profile, commitMessage: "Article", pathScope: ["article.md"])
    XCTAssertThrowsError(try service.publish(profile: profile, confirmation: confirmation)) {
      XCTAssertEqual($0 as? RepositoryGitExecutionPolicyError, .reviewedContentChanged)
    }
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing, fixture.initialSHA)
  }

  func testPostCommitFailureReportsCommittedFactAndDoesNotPush() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("changed\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.md"))
    try writePolicyHook(
      "#!/bin/sh\necho post-rejected >&2\nexit 5\n", name: "post-commit", root: fixture.worktree)
    var profile = fixture.profile
    profile.gitExecutionPolicy = try RepositoryGitExecutionPolicyService().trustingHooks(
      at: fixture.worktree)
    let service = RepositoryWorktreePublishService()
    let confirmation = try service.prepare(profile: profile, commitMessage: "Committed before hook")
    var committedSHA: String?
    XCTAssertThrowsError(try service.publish(profile: profile, confirmation: confirmation)) {
      error in
      guard
        case .commitSucceededButPushFailed(let sha, let message) = error
          as? RepositoryWorktreePublishError
      else {
        return XCTFail("Expected committed fact, received \(error)")
      }
      committedSHA = sha
      XCTAssertTrue(message.contains("post-commit"))
      XCTAssertTrue(message.contains("未推送"))
      XCTAssertTrue(message.contains("post-rejected"))
    }
    XCTAssertNotEqual(committedSHA, fixture.initialSHA)
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing, committedSHA)
    XCTAssertEqual(
      try git(["rev-parse", "main"], at: fixture.remote).trimmedForPublishing, fixture.initialSHA)
    XCTAssertTrue(try git(["status", "--porcelain"], at: fixture.worktree).isEmpty)
  }

  func testScopedPublishRejectsHooksRewritingAlreadyDirtyOutOfScopeFiles() throws {
    let beforeCommitHooks = ["pre-commit", "prepare-commit-msg", "commit-msg"]
    for hook in beforeCommitHooks + ["post-commit", "pre-push"] {
      for path in ["tracked.md", "later.txt"] {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let dirtyURL = fixture.worktree.appendingPathComponent(path)
        try Data("pending\n".utf8).write(to: dirtyURL)
        try Data("article\n".utf8).write(to: fixture.worktree.appendingPathComponent("article.md"))
        try writePolicyHook(
          "#!/bin/sh\nprintf 'hook\\n' >> \(path)\n", name: hook, root: fixture.worktree)
        var profile = fixture.profile
        profile.gitExecutionPolicy = try RepositoryGitExecutionPolicyService().trustingHooks(
          at: fixture.worktree)
        let service = RepositoryWorktreePublishService()
        let confirmation = try service.prepare(
          profile: profile, commitMessage: "Article", pathScope: ["article.md"])
        XCTAssertThrowsError(try service.publish(profile: profile, confirmation: confirmation)) {
          error in
          if beforeCommitHooks.contains(hook) {
            XCTAssertEqual(error as? RepositoryGitExecutionPolicyError, .reviewedContentChanged)
          } else {
            guard case .commitSucceededButPushFailed = error as? RepositoryWorktreePublishError
            else {
              return XCTFail("Expected retained local commit, got \(error)")
            }
          }
        }
        XCTAssertEqual(try String(contentsOf: dirtyURL, encoding: .utf8), "pending\nhook\n")
        XCTAssertEqual(
          try git(["rev-parse", "refs/heads/main"], at: fixture.remote).trimmedForPublishing,
          fixture.initialSHA)
        let head = try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing
        if beforeCommitHooks.contains(hook) {
          XCTAssertEqual(head, fixture.initialSHA)
        } else {
          XCTAssertNotEqual(head, fixture.initialSHA)
        }
      }
    }
  }

  func testTrustedPrePushHookChangingHeadStopsFrozenCommitPush() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("changed\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.md"))
    try writePolicyHook(
      "#!/bin/sh\ntree=$(git rev-parse HEAD^{tree})\nhead=$(git rev-parse HEAD)\nnext=$(git commit-tree \"$tree\" -p \"$head\" -m 'hook follow-up')\ngit update-ref refs/heads/main \"$next\" \"$head\"\n",
      name: "pre-push", root: fixture.worktree
    )
    var profile = fixture.profile
    profile.gitExecutionPolicy = try RepositoryGitExecutionPolicyService().trustingHooks(
      at: fixture.worktree)
    let service = RepositoryWorktreePublishService()
    let confirmation = try service.prepare(profile: profile, commitMessage: "Frozen commit")
    XCTAssertThrowsError(try service.publish(profile: profile, confirmation: confirmation)) {
      error in
      guard case .commitSucceededButPushFailed = error as? RepositoryWorktreePublishError else {
        return XCTFail("Expected local commit preserved without push, received \(error)")
      }
    }
    XCTAssertNotEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing, fixture.initialSHA)
    XCTAssertEqual(
      try git(["rev-parse", "main"], at: fixture.remote).trimmedForPublishing, fixture.initialSHA)
  }

  func testRequiredSigningFailureLeavesHeadsAndRealIndexUntouched() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Data("changed\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.md"))
    var profile = fixture.profile
    profile.gitExecutionPolicy = RepositoryGitExecutionPolicy(
      sshCommitSigningEnabled: true,
      sshSigningKey: fixture.base.appendingPathComponent("missing-key").path
    )
    let service = RepositoryWorktreePublishService()
    let confirmation = try service.prepare(profile: profile, commitMessage: "Signature required")
    XCTAssertThrowsError(try service.publish(profile: profile, confirmation: confirmation))
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing, fixture.initialSHA)
    XCTAssertEqual(
      try git(["rev-parse", "main"], at: fixture.remote).trimmedForPublishing, fixture.initialSHA)
    XCTAssertTrue(try git(["diff", "--cached", "--name-only"], at: fixture.worktree).isEmpty)
  }

  private func writePolicyHook(_ script: String, name: String, root: URL) throws {
    let url = root.appendingPathComponent(".git/hooks/\(name)")
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: url.path)
  }

  private func makeFixture() throws -> Fixture {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("repopress-worktree-publish-\(UUID().uuidString)", isDirectory: true)
    let worktree = base.appendingPathComponent("worktree", isDirectory: true)
    let ownerDirectory = base.appendingPathComponent("owner", isDirectory: true)
    let remote = ownerDirectory.appendingPathComponent("site.git", isDirectory: true)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: ownerDirectory, withIntermediateDirectories: true)
    _ = try git(["init", "--bare", "-b", "main", remote.path], at: base)
    _ = try git(["init", "-b", "main"], at: worktree)
    _ = try git(["config", "user.email", "test@example.com"], at: worktree)
    _ = try git(["config", "user.name", "RepoPress Tests"], at: worktree)
    try Data("base\n".utf8).write(to: worktree.appendingPathComponent("tracked.md"))
    try Data("remove\n".utf8).write(to: worktree.appendingPathComponent("remove-me.txt"))
    _ = try git(["add", "-A", "--", "."], at: worktree)
    _ = try git(["commit", "-m", "base"], at: worktree)
    _ = try git(["remote", "add", "origin", remote.path], at: worktree)
    _ = try git(["push", "-u", "origin", "main"], at: worktree)
    let initialSHA = try git(["rev-parse", "HEAD"], at: worktree).trimmedForPublishing
    let profile = SiteProfile(
      name: "Test",
      localRepositoryRootPath: worktree.path,
      repoOwner: "owner",
      repoName: "site",
      branch: "main"
    )
    return Fixture(
      base: base,
      worktree: worktree,
      remote: remote,
      profile: profile,
      initialSHA: initialSHA
    )
  }

  @discardableResult
  private func git(_ arguments: [String], at root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
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
        domain: "RepositoryWorktreePublishServiceTests.Git",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: error]
      )
    }
    return output
  }
}

private struct PreflightSequenceState {
  var results: [RepositoryPublishPreflightCommandResult]
  var count = 0
}

private final class PreflightSequence: Sendable {
  private let state: OSAllocatedUnfairLock<PreflightSequenceState>

  init(results: [RepositoryPublishPreflightCommandResult]) {
    state = OSAllocatedUnfairLock(initialState: PreflightSequenceState(results: results))
  }

  var commandCount: Int {
    state.withLock { $0.count }
  }

  var runner: RepositoryPublishPreflightCommandRunner {
    RepositoryPublishPreflightCommandRunner { [self] _ in
      state.withLock { state in
        state.count += 1
        guard !state.results.isEmpty else {
          return .init(termination: .launchFailed, standardError: "Unexpected command")
        }
        return state.results.removeFirst()
      }
    }
  }
}
