import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RepositoryRebaseSyncServiceTests: XCTestCase {
  private struct Fixture {
    let base: URL
    let local: URL
    let peer: URL
    let remote: URL
    let profile: SiteProfile
  }

  func testRebasesAndRestoresStagedUnstagedAndUntrackedChanges() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }

    try write("old recovery\n", to: fixture.local, path: "old-recovery.md")
    _ = try git(["stash", "push", "--include-untracked", "-m", "existing"], at: fixture.local)
    let existingStash = try git(["rev-parse", "refs/stash"], at: fixture.local)

    try commit("local commit\n", path: "local.md", message: "local", at: fixture.local)
    try commit("remote commit\n", path: "remote.md", message: "remote", at: fixture.peer)
    _ = try git(["push", "origin", "main"], at: fixture.peer)

    try write("staged\n", to: fixture.local, path: "base.md")
    _ = try git(["add", "--", "base.md"], at: fixture.local)
    try write("unstaged after stage\n", to: fixture.local, path: "base.md")
    try write("untracked\n", to: fixture.local, path: "notes.md")

    let service = RepositoryRebaseSyncService()
    let confirmation = try confirmation(from: service.prepare(profile: fixture.profile))
    XCTAssertEqual(confirmation.snapshot.aheadCount, 1)
    XCTAssertEqual(confirmation.snapshot.behindCount, 1)

    let result = try service.apply(profile: fixture.profile, confirmation: confirmation)

    XCTAssertTrue(result.stashWasCreated)
    XCTAssertFalse(result.stashWasRetained)
    XCTAssertEqual(try content(fixture.local, path: "base.md"), "unstaged after stage\n")
    XCTAssertEqual(try content(fixture.local, path: "notes.md"), "untracked\n")
    XCTAssertEqual(
      try git(["diff", "--cached", "--name-only"], at: fixture.local),
      "base.md"
    )
    XCTAssertEqual(try git(["rev-parse", "refs/stash"], at: fixture.local), existingStash)
    XCTAssertEqual(
      try git(
        ["merge-base", "--is-ancestor", "refs/remotes/origin/main", "HEAD"],
        at: fixture.local,
        acceptsStatus: 0
      ),
      ""
    )
  }

  func testRejectsRemoteDriftBeforeChangingHeadOrWorktree() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try commit("local commit\n", path: "local.md", message: "local", at: fixture.local)
    try commit("remote one\n", path: "remote-one.md", message: "remote one", at: fixture.peer)
    _ = try git(["push", "origin", "main"], at: fixture.peer)
    try write("dirty\n", to: fixture.local, path: "dirty.md")

    let service = RepositoryRebaseSyncService()
    let confirmation = try confirmation(from: service.prepare(profile: fixture.profile))
    let originalHead = try git(["rev-parse", "HEAD"], at: fixture.local)
    let originalStatus = try git(["status", "--porcelain=v1"], at: fixture.local)
    try commit("remote two\n", path: "remote-two.md", message: "remote two", at: fixture.peer)
    _ = try git(["push", "origin", "main"], at: fixture.peer)

    XCTAssertThrowsError(try service.apply(profile: fixture.profile, confirmation: confirmation)) {
      XCTAssertEqual($0 as? RepositoryRebaseSyncError, .snapshotDrift)
    }
    XCTAssertEqual(try git(["rev-parse", "HEAD"], at: fixture.local), originalHead)
    XCTAssertEqual(try git(["status", "--porcelain=v1"], at: fixture.local), originalStatus)
    XCTAssertThrowsError(try git(["rev-parse", "--verify", "refs/stash"], at: fixture.local))
  }

  func testRebaseConflictLeavesSequencerAndRecoveryStashIntact() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try commit("local version\n", path: "base.md", message: "local conflict", at: fixture.local)
    try commit("remote version\n", path: "base.md", message: "remote conflict", at: fixture.peer)
    _ = try git(["push", "origin", "main"], at: fixture.peer)
    try write("recover me\n", to: fixture.local, path: "draft.md")

    let service = RepositoryRebaseSyncService()
    let confirmation = try confirmation(from: service.prepare(profile: fixture.profile))
    var recoveryStash: String?
    XCTAssertThrowsError(try service.apply(profile: fixture.profile, confirmation: confirmation)) {
      guard case .rebaseConflict(let stashCommitSHA, let paths) = $0 as? RepositoryRebaseSyncError
      else { return XCTFail("Unexpected error: \($0)") }
      recoveryStash = stashCommitSHA
      XCTAssertEqual(paths, ["base.md"])
    }

    XCTAssertNotNil(recoveryStash)
    XCTAssertEqual(try git(["rev-parse", "refs/stash"], at: fixture.local), recoveryStash)
    let gitDirectory = try git(["rev-parse", "--git-dir"], at: fixture.local)
    let rebaseDirectory = URL(fileURLWithPath: gitDirectory, relativeTo: fixture.local)
      .standardizedFileURL.appendingPathComponent("rebase-merge")
    XCTAssertTrue(FileManager.default.fileExists(atPath: rebaseDirectory.path))
  }

  func testRestoresFrozenStashCommitInsteadOfReflogSelector() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try commit("local commit\n", path: "local.md", message: "local", at: fixture.local)
    try commit("remote commit\n", path: "remote.md", message: "remote", at: fixture.peer)
    _ = try git(["push", "origin", "main"], at: fixture.peer)
    try write("restore this exact WIP\n", to: fixture.local, path: "draft.md")

    let wrapper = try makeStashSHAEnforcingGitWrapper(in: fixture.base)
    let service = RepositoryRebaseSyncService(
      gitCommandRunner: GitCommandRunner(executableURL: wrapper)
    )
    let confirmation = try confirmation(from: service.prepare(profile: fixture.profile))
    let result = try service.apply(profile: fixture.profile, confirmation: confirmation)

    XCTAssertFalse(result.stashWasRetained)
    XCTAssertEqual(try content(fixture.local, path: "draft.md"), "restore this exact WIP\n")
  }

  func testReportsConflictEnumerationFailureWithoutDiscardingRecoveryStash() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try commit("local version\n", path: "base.md", message: "local conflict", at: fixture.local)
    try commit("remote version\n", path: "base.md", message: "remote conflict", at: fixture.peer)
    _ = try git(["push", "origin", "main"], at: fixture.peer)
    try write("recover me\n", to: fixture.local, path: "draft.md")

    let wrapper = try makeConflictEnumerationFailingGitWrapper(in: fixture.base)
    let service = RepositoryRebaseSyncService(
      gitCommandRunner: GitCommandRunner(executableURL: wrapper)
    )
    let confirmation = try confirmation(from: service.prepare(profile: fixture.profile))

    var recoveryStash: String?
    XCTAssertThrowsError(try service.apply(profile: fixture.profile, confirmation: confirmation)) {
      guard case .partial(let stashCommitSHA, let message) = $0 as? RepositoryRebaseSyncError
      else { return XCTFail("Unexpected error: \($0)") }
      recoveryStash = stashCommitSHA
      XCTAssertTrue(message.contains("无法读取冲突路径"))
      XCTAssertTrue(message.contains("forced conflict enumeration failure"))
    }
    XCTAssertEqual(try git(["rev-parse", "refs/stash"], at: fixture.local), recoveryStash)
  }

  func testRejectsUntrackedSymlinkBeforeCreatingStash() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try commit("local commit\n", path: "local.md", message: "local", at: fixture.local)
    try commit("remote commit\n", path: "remote.md", message: "remote", at: fixture.peer)
    _ = try git(["push", "origin", "main"], at: fixture.peer)
    try FileManager.default.createSymbolicLink(
      at: fixture.local.appendingPathComponent("unsafe-link.md"),
      withDestinationURL: fixture.base.appendingPathComponent("missing-target.md")
    )

    XCTAssertThrowsError(try RepositoryRebaseSyncService().prepare(profile: fixture.profile)) {
      guard case .unsupportedLocalChanges(let paths) = $0 as? RepositoryRebaseSyncError else {
        return XCTFail("Unexpected error: \($0)")
      }
      XCTAssertEqual(paths, ["unsafe-link.md"])
    }
    XCTAssertThrowsError(try git(["rev-parse", "--verify", "refs/stash"], at: fixture.local))
  }

  private func confirmation(
    from preparation: RepositoryRebaseSyncPreparation
  ) throws -> RepositoryRebaseSyncConfirmation {
    guard case .confirmation(let confirmation) = preparation else {
      throw NSError(domain: "RepositoryRebaseSyncServiceTests", code: 1)
    }
    return confirmation
  }

  private func makeFixture() throws -> Fixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "repopress-rebase-sync-\(UUID().uuidString)", isDirectory: true
    )
    let owner = base.appendingPathComponent("owner", isDirectory: true)
    let remote = owner.appendingPathComponent("site.git", isDirectory: true)
    let local = base.appendingPathComponent("local", isDirectory: true)
    let peer = base.appendingPathComponent("peer", isDirectory: true)
    try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
    _ = try git(["init", "--bare", "-b", "main", remote.path], at: base)
    _ = try git(["init", "-b", "main", local.path], at: base)
    try configureIdentity(at: local)
    try write("base\n", to: local, path: "base.md")
    _ = try git(["add", "--", "base.md"], at: local)
    _ = try git(["commit", "-m", "base"], at: local)
    _ = try git(["remote", "add", "origin", remote.path], at: local)
    _ = try git(["push", "-u", "origin", "main"], at: local)
    _ = try git(["clone", remote.path, peer.path], at: base)
    try configureIdentity(at: peer)
    return Fixture(
      base: base,
      local: local,
      peer: peer,
      remote: remote,
      profile: SiteProfile(
        name: "Test",
        localRepositoryRootPath: local.path,
        repoOwner: "owner",
        repoName: "site",
        branch: "main"
      )
    )
  }

  private func configureIdentity(at root: URL) throws {
    _ = try git(["config", "user.email", "tests@example.com"], at: root)
    _ = try git(["config", "user.name", "Tests"], at: root)
  }

  private func commit(_ value: String, path: String, message: String, at root: URL) throws {
    try write(value, to: root, path: path)
    _ = try git(["add", "--", path], at: root)
    _ = try git(["commit", "-m", message], at: root)
  }

  private func write(_ value: String, to root: URL, path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(value.utf8).write(to: url)
  }

  private func content(_ root: URL, path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
  }

  private func makeStashSHAEnforcingGitWrapper(in root: URL) throws -> URL {
    let wrapper = root.appendingPathComponent("stash-sha-wrapper.sh")
    let script = """
      #!/bin/sh
      root="$2"
      shift 2
      if [ "$1" = "stash" ] && [ "$2" = "apply" ] && [ "$3" = "--index" ]; then
        case "$4" in
          stash@*)
            echo "reflog selectors are not accepted for restoration" >&2
            exit 87
            ;;
        esac
      fi
      exec /usr/bin/git -C "$root" "$@"
      """
    try Data(script.utf8).write(to: wrapper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    return wrapper
  }

  private func makeConflictEnumerationFailingGitWrapper(in root: URL) throws -> URL {
    let wrapper = root.appendingPathComponent("conflict-enumeration-wrapper.sh")
    let script = """
      #!/bin/sh
      root="$2"
      shift 2
      if [ "$1" = "diff" ] && [ "$2" = "--name-only" ] && [ "$3" = "--diff-filter=U" ]; then
        echo "forced conflict enumeration failure" >&2
        exit 86
      fi
      exec /usr/bin/git -C "$root" "$@"
      """
    try Data(script.utf8).write(to: wrapper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    return wrapper
  }

  @discardableResult
  private func git(
    _ arguments: [String],
    at root: URL,
    acceptsStatus: Int32 = 0
  ) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    let standardOutput = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
    )
    let standardError = String(
      decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
    )
    guard process.terminationStatus == acceptsStatus else {
      throw NSError(
        domain: "RepositoryRebaseSyncServiceTests.Git",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: standardOutput + standardError]
      )
    }
    return standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
