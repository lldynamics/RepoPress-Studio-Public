import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RepositorySafeSyncServiceTests: XCTestCase {
  private struct Fixture {
    let base: URL
    let worktree: URL
    let remote: URL
    let profile: SiteProfile
  }

  func testIdenticalUntrackedCollisionFastForwardsAndPreservesOtherDirtyFile() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try advanceRemote(fixture, path: "incoming.md", contents: "same\n")
    try write("same\n", to: fixture.worktree, path: "incoming.md")
    try write("preserve me\n", to: fixture.worktree, path: "local.md")

    let service = RepositorySafeSyncService()
    let confirmation = try confirmation(from: service.prepare(profile: fixture.profile))
    let recovery = fixture.base.appendingPathComponent("recovery", isDirectory: true)
    let result = try service.apply(
      profile: fixture.profile,
      confirmation: confirmation,
      recoveryRootURL: recovery
    )

    XCTAssertEqual(result.reconciledCollisionPaths, ["incoming.md"])
    XCTAssertEqual(try content(fixture.worktree, path: "local.md"), "preserve me\n")
    XCTAssertEqual(try content(fixture.worktree, path: "incoming.md"), "same\n")
    XCTAssertNotNil(result.recoveryArchiveURL)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: result.recoveryArchiveURL!.appendingPathComponent("manifest.json").path
      ))
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktree).trimmedForPublishing,
      try git(["rev-parse", "refs/heads/main"], at: fixture.remote).trimmedForPublishing
    )
  }

  func testRejectsDifferentUntrackedCollisionBeforeApply() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try advanceRemote(fixture, path: "incoming.md", contents: "remote\n")
    try write("local\n", to: fixture.worktree, path: "incoming.md")

    XCTAssertThrowsError(try RepositorySafeSyncService().prepare(profile: fixture.profile)) {
      error in
      XCTAssertEqual(error as? RepositorySafeSyncError, .collisionMismatch(["incoming.md"]))
    }
  }

  func testRejectsStagedChangesWithoutChangingIndex() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try advanceRemote(fixture, path: "remote.md", contents: "remote\n")
    try write("staged\n", to: fixture.worktree, path: "base.md")
    _ = try git(["add", "--", "base.md"], at: fixture.worktree)
    let before = try git(["diff", "--cached", "--", "base.md"], at: fixture.worktree)

    XCTAssertThrowsError(try RepositorySafeSyncService().prepare(profile: fixture.profile)) {
      error in
      guard case .stagedChanges(let paths) = error as? RepositorySafeSyncError else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(paths, ["base.md"])
    }
    XCTAssertEqual(try git(["diff", "--cached", "--", "base.md"], at: fixture.worktree), before)
  }

  func testRejectsLocalSnapshotDriftAfterReview() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try advanceRemote(fixture, path: "remote.md", contents: "remote\n")
    try write("reviewed\n", to: fixture.worktree, path: "local.md")
    let confirmation = try confirmation(
      from: RepositorySafeSyncService().prepare(profile: fixture.profile))
    try write("changed after review\n", to: fixture.worktree, path: "local.md")

    XCTAssertThrowsError(
      try RepositorySafeSyncService().apply(
        profile: fixture.profile,
        confirmation: confirmation,
        recoveryRootURL: fixture.base.appendingPathComponent("recovery", isDirectory: true)
      )
    ) { error in
      XCTAssertEqual(error as? RepositorySafeSyncError, .snapshotDrift)
    }
  }

  func testFastForwardsNonOverlappingRemoteChangeWithoutRecoveryArchive() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try advanceRemote(fixture, path: "remote.md", contents: "remote\n")
    try write("local\n", to: fixture.worktree, path: "local.md")
    let service = RepositorySafeSyncService()
    let confirmation = try confirmation(from: service.prepare(profile: fixture.profile))
    let result = try service.apply(
      profile: fixture.profile,
      confirmation: confirmation,
      recoveryRootURL: fixture.base.appendingPathComponent("recovery", isDirectory: true)
    )

    XCTAssertEqual(result.preservedLocalPaths, ["local.md"])
    XCTAssertNil(result.recoveryArchiveURL)
    XCTAssertEqual(try content(fixture.worktree, path: "remote.md"), "remote\n")
    XCTAssertEqual(try content(fixture.worktree, path: "local.md"), "local\n")
  }

  func testPreservesOriginalAndRecoveryDiagnosticsWhenRestoreVerificationFails() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try advanceRemote(fixture, path: "incoming.md", contents: "same\n")
    try write("same\n", to: fixture.worktree, path: "incoming.md")

    let wrapper = try makeRestoreVerificationFailingGitWrapper(in: fixture.base)
    let service = RepositorySafeSyncService(
      gitCommandRunner: GitCommandRunner(executableURL: wrapper)
    )
    let confirmation = try self.confirmation(from: service.prepare(profile: fixture.profile))

    XCTAssertThrowsError(
      try service.apply(
        profile: fixture.profile,
        confirmation: confirmation,
        recoveryRootURL: fixture.base.appendingPathComponent("recovery", isDirectory: true)
      )
    ) { error in
      guard case .partial(_, let message) = error as? RepositorySafeSyncError else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("forced merge failure"))
      XCTAssertTrue(message.contains("forced restore hash failure"))
    }
  }

  private func confirmation(
    from preparation: RepositorySafeSyncPreparation
  ) throws -> RepositorySafeSyncConfirmation {
    guard case .confirmation(let confirmation) = preparation else {
      throw NSError(domain: "RepositorySafeSyncServiceTests", code: 1)
    }
    return confirmation
  }

  private func makeFixture() throws -> Fixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "repopress-safe-sync-\(UUID().uuidString)", isDirectory: true
    )
    let worktree = base.appendingPathComponent("worktree", isDirectory: true)
    let owner = base.appendingPathComponent("owner", isDirectory: true)
    let remote = owner.appendingPathComponent("site.git", isDirectory: true)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
    _ = try git(["init", "--bare", "-b", "main", remote.path], at: base)
    _ = try git(["init", "-b", "main"], at: worktree)
    _ = try git(["config", "user.email", "local@example.com"], at: worktree)
    _ = try git(["config", "user.name", "Local"], at: worktree)
    try write("base\n", to: worktree, path: "base.md")
    _ = try git(["add", "--", "base.md"], at: worktree)
    _ = try git(["commit", "-m", "base"], at: worktree)
    _ = try git(["remote", "add", "origin", remote.path], at: worktree)
    _ = try git(["push", "-u", "origin", "main"], at: worktree)
    return Fixture(
      base: base,
      worktree: worktree,
      remote: remote,
      profile: SiteProfile(
        name: "Test",
        localRepositoryRootPath: worktree.path,
        repoOwner: "owner",
        repoName: "site",
        branch: "main"
      )
    )
  }

  private func advanceRemote(_ fixture: Fixture, path: String, contents: String) throws {
    let peer = fixture.base.appendingPathComponent("peer-\(UUID().uuidString)", isDirectory: true)
    _ = try git(["clone", fixture.remote.path, peer.path], at: fixture.base)
    _ = try git(["config", "user.email", "peer@example.com"], at: peer)
    _ = try git(["config", "user.name", "Peer"], at: peer)
    try write(contents, to: peer, path: path)
    _ = try git(["add", "--", path], at: peer)
    _ = try git(["commit", "-m", "remote advance"], at: peer)
    _ = try git(["push", "origin", "main"], at: peer)
  }

  private func write(_ value: String, to root: URL, path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.utf8).write(to: url)
  }

  private func content(_ root: URL, path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
  }

  private func makeRestoreVerificationFailingGitWrapper(in root: URL) throws -> URL {
    let wrapper = root.appendingPathComponent("restore-verification-wrapper.sh")
    let script = """
      #!/bin/sh
      root="$2"
      shift 2
      marker="$root/.repopress-force-restore-verification-failure"
      if [ "$1" = "merge" ] && [ "$2" = "--ff-only" ]; then
        : > "$marker"
        echo "forced merge failure" >&2
        exit 85
      fi
      if [ "$1" = "hash-object" ] && [ -f "$marker" ]; then
        echo "forced restore hash failure" >&2
        exit 84
      fi
      exec /usr/bin/git -C "$root" "$@"
      """
    try Data(script.utf8).write(to: wrapper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    return wrapper
  }

  @discardableResult
  private func git(_ arguments: [String], at root: URL) throws -> String {
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
      decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let standardError = String(
      decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "RepositorySafeSyncServiceTests.Git",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: standardError]
      )
    }
    return standardOutput
  }
}
