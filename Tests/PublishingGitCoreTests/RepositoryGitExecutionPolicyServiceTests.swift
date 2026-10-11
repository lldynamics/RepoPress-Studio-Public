import Foundation
import PublishingDomainContracts
import XCTest

@testable import PublishingGitCore

final class RepositoryGitExecutionPolicyServiceTests: XCTestCase {
  func testHistoricalPolicyDefaultsToIsolatedExecution() throws {
    let policy = try JSONDecoder().decode(RepositoryGitExecutionPolicy.self, from: Data("{}".utf8))
    XCTAssertFalse(policy.sshCommitSigningEnabled)
    XCTAssertFalse(policy.hasTrustedHooks)
    XCTAssertFalse(policy.requiresControlledCommitExecution)
  }

  func testOnlyExplicitHookExecutionRunsTrustedHooksAndRetainsFsmonitorIsolation() throws {
    let root = try makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent(".git/hook-marker")
    let monitorMarker = root.appendingPathComponent(".git/fsmonitor-marker")
    let monitor = root.appendingPathComponent(".git/monitor")
    try executable("#!/bin/sh\ntouch '\(monitorMarker.path)'\n", at: monitor)
    _ = try git(["config", "core.fsmonitor", monitor.path], root: root)
    try executable(
      "#!/bin/sh\ntouch '\(marker.path)'\n",
      at: root.appendingPathComponent(".git/hooks/pre-commit"))
    let service = RepositoryGitExecutionPolicyService()
    let policy = try service.trustingHooks(at: root)

    try service.runHook(.preCommit, policy: nil, rootURL: root)
    _ = try git(["status", "--porcelain"], root: root)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    try service.runHook(.preCommit, policy: policy, rootURL: root)
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: monitorMarker.path))
  }

  func testTrustDoesNotFollowMovedRepositoryAndRejectsMetadataDirectoryChange() throws {
    let root = try makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = RepositoryGitExecutionPolicyService()
    let policy = try service.trustingHooks(at: root)
    let moved = root.deletingLastPathComponent().appendingPathComponent(
      "moved-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: moved) }
    try FileManager.default.moveItem(at: root, to: moved)
    XCTAssertThrowsError(try service.runHook(.preCommit, policy: policy, rootURL: moved)) {
      XCTAssertEqual($0 as? RepositoryGitExecutionPolicyError, .trustNoLongerMatches)
    }
    var wrongMetadata = try service.trustingHooks(at: moved)
    wrongMetadata.trustedHooksGitDirectoryPath = moved.appendingPathComponent("other-git").path
    XCTAssertThrowsError(try service.validate(policy: wrongMetadata, rootURL: moved)) {
      XCTAssertEqual($0 as? RepositoryGitExecutionPolicyError, .trustNoLongerMatches)
    }
  }

  func testSymlinkedHooksDirectoryAndHookFileAreRejected() throws {
    let root = try makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = RepositoryGitExecutionPolicyService()
    let policy = try service.trustingHooks(at: root)
    let outside = root.appendingPathComponent(".git/outside")
    try executable("#!/bin/sh\nexit 0\n", at: outside)
    let hook = root.appendingPathComponent(".git/hooks/pre-commit")
    try FileManager.default.createSymbolicLink(at: hook, withDestinationURL: outside)
    XCTAssertThrowsError(try service.runHook(.preCommit, policy: policy, rootURL: root)) {
      XCTAssertEqual($0 as? RepositoryGitExecutionPolicyError, .unsafeHook("pre-commit"))
    }
    let hooks = root.appendingPathComponent(".git/hooks")
    try FileManager.default.removeItem(at: hooks)
    let outsideDirectory = root.appendingPathComponent(".git/outside-directory")
    try FileManager.default.createDirectory(
      at: outsideDirectory, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: hooks, withDestinationURL: outsideDirectory)
    XCTAssertThrowsError(try service.trustingHooks(at: root)) {
      XCTAssertEqual($0 as? RepositoryGitExecutionPolicyError, .unsafeHooksDirectory)
    }
  }

  func testTrustDoesNotPermitExecutableFilterConfiguration() throws {
    let root = try makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = RepositoryGitExecutionPolicyService()
    let policy = try service.trustingHooks(at: root)
    _ = try git(["config", "filter.untrusted.clean", "/usr/bin/true"], root: root)
    XCTAssertThrowsError(try service.runHook(.preCommit, policy: policy, rootURL: root)) { error in
      XCTAssertTrue(error.localizedDescription.contains("filter"))
    }
  }

  func testPreCommitLifecycleReceivesMessageArgumentsAndRejectsMessageRewrite() throws {
    let root = try makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = RepositoryGitExecutionPolicyService()
    let policy = try service.trustingHooks(at: root)
    let message = root.appendingPathComponent(".git/reviewed-message")
    try "Reviewed\n".write(to: message, atomically: true, encoding: .utf8)
    let marker = root.appendingPathComponent(".git/hook-sequence")
    for hook in [RepositoryGitHook.preCommit, .prepareCommitMessage, .commitMessage] {
      try executable(
        "#!/bin/sh\nprintf '%s|%s|%s\\n' '\(hook.rawValue)' \"$1\" \"$2\" >> '\(marker.path)'\n",
        at: root.appendingPathComponent(".git/hooks/\(hook.rawValue)")
      )
    }
    var checks = 0
    try service.runPreCommitHooks(
      policy: policy, rootURL: root, indexURL: nil, messageURL: message, source: "merge"
    ) { checks += 1 }
    XCTAssertEqual(checks, 3)
    let sequence = try String(contentsOf: marker, encoding: .utf8)
    XCTAssertTrue(sequence.contains("pre-commit||"))
    XCTAssertTrue(sequence.contains("prepare-commit-msg|\(message.path)|merge"))
    XCTAssertTrue(sequence.contains("commit-msg|\(message.path)|"))
    try executable(
      "#!/bin/sh\nprintf 'Rewritten\\n' > \"$1\"\n",
      at: root.appendingPathComponent(".git/hooks/commit-msg"))
    XCTAssertThrowsError(
      try service.runPreCommitHooks(
        policy: policy, rootURL: root, indexURL: nil, messageURL: message, source: "message",
        validateSnapshot: {}
      )
    ) {
      XCTAssertEqual($0 as? RepositoryGitExecutionPolicyError, .reviewedContentChanged)
    }
  }

  func testPrePushReceivesExactRefInputAndPreHookFailureIsReported() throws {
    let root = try makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = RepositoryGitExecutionPolicyService()
    let policy = try service.trustingHooks(at: root)
    let input = root.appendingPathComponent(".git/push-input")
    let marker = root.appendingPathComponent(".git/push-marker")
    let reference = "refs/heads/main abc refs/heads/main def\n"
    try reference.write(to: input, atomically: true, encoding: .utf8)
    try executable(
      "#!/bin/sh\nprintf '%s|%s\\n' \"$1\" \"$2\" > '\(marker.path)'\ncat >> '\(marker.path)'\nexit 7\n",
      at: root.appendingPathComponent(".git/hooks/pre-push"))
    XCTAssertThrowsError(
      try service.runHook(
        .prePush, policy: policy, rootURL: root, arguments: ["origin", "/tmp/remote.git"],
        standardInputURL: input
      )
    ) {
      guard case .hookFailed("pre-push", _) = $0 as? RepositoryGitExecutionPolicyError else {
        return XCTFail("Unexpected error: \($0)")
      }
    }
    XCTAssertEqual(
      try String(contentsOf: marker, encoding: .utf8), "origin|/tmp/remote.git\n" + reference)
  }

  func testSigningUsesExplicitSSHFormatSystemSignerAndNeverEnablesReadCommands() throws {
    let root = try makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let stub = root.appendingPathComponent(".git/git-stub")
    try executable(
      """
      #!/bin/sh
      printf '%s\\n' "$@"
      printf '%s|%s|%s|%s|%s|%s\\n' "$GIT_CONFIG_VALUE_1" "$GIT_CONFIG_VALUE_2" "$GIT_CONFIG_VALUE_6" "$GIT_CONFIG_VALUE_7" "$GIT_CONFIG_VALUE_8" "$GIT_CONFIG_VALUE_9"
      """, at: stub)
    let runner = GitCommandRunner(executableURL: stub)
    let service = RepositoryGitExecutionPolicyService(gitCommandRunner: runner)
    let policy = RepositoryGitExecutionPolicy(
      sshCommitSigningEnabled: true, sshSigningKey: "/tmp/controlled key.pub")
    let signed = try service.commit(["commit-tree", "tree"], rootURL: root, policy: policy)
    XCTAssertEqual(signed.terminationStatus, 0)
    XCTAssertTrue(signed.standardOutput.contains("commit-tree\n-S\ntree"))
    XCTAssertTrue(
      signed.standardOutput.contains(
        "/dev/null|false|ssh|/tmp/controlled key.pub|/usr/bin/ssh-keygen|true"))
    let read = runner.run(["status"], rootURL: root)
    XCTAssertTrue(read.standardOutput.contains("/dev/null|false||||"))
  }

  func testSystemSSHSignerProducesSignedCommitObject() throws {
    let root = try makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let key = root.appendingPathComponent(".git/signing-key")
    let keygen = Process()
    keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", key.path]
    try keygen.run()
    keygen.waitUntilExit()
    XCTAssertEqual(keygen.terminationStatus, 0)
    let tree = try git(["write-tree"], root: root)
    let head = try git(["rev-parse", "HEAD"], root: root)
    let result = try RepositoryGitExecutionPolicyService().commit(
      ["commit-tree", tree, "-p", head, "-m", "Signed"], rootURL: root,
      policy: RepositoryGitExecutionPolicy(sshCommitSigningEnabled: true, sshSigningKey: key.path)
    )
    XCTAssertEqual(result.terminationStatus, 0, result.output)
    XCTAssertTrue(
      try git(["cat-file", "-p", result.standardOutput], root: root).contains(
        "gpgsig -----BEGIN SSH SIGNATURE-----"))
    XCTAssertEqual(try git(["rev-parse", "HEAD"], root: root), head)
  }

  func testSigningFailureDoesNotCreateUnsignedCommit() throws {
    let root = try makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let tree = try git(["write-tree"], root: root)
    let head = try git(["rev-parse", "HEAD"], root: root)
    let service = RepositoryGitExecutionPolicyService()
    let result = try service.commit(
      ["commit-tree", tree, "-p", head, "-m", "Must sign"], rootURL: root,
      policy: RepositoryGitExecutionPolicy(
        sshCommitSigningEnabled: true,
        sshSigningKey: root.appendingPathComponent("missing-key").path)
    )
    XCTAssertNotEqual(result.terminationStatus, 0)
    XCTAssertTrue(result.standardOutput.isEmpty)
    XCTAssertEqual(try git(["rev-parse", "HEAD"], root: root), head)
  }

  func testHookSearchPathAppendsHomebrewWithoutShadowingSystemTools() {
    let path = RepositoryGitExecutionPolicyService.hookSearchPath(
      inherited: "/usr/bin:/bin", candidates: ["/opt/homebrew/bin", "/missing/bin", "/bin"],
      directoryExists: { $0 != "/missing/bin" })
    XCTAssertEqual(path, "/usr/bin:/bin:/opt/homebrew/bin")
    XCTAssertEqual(
      RepositoryGitExecutionPolicyService.hookSearchPath(
        inherited: nil, candidates: [], directoryExists: { _ in true }),
      "/usr/bin:/bin:/usr/sbin:/sbin")
  }

  func testConfiguredHooksPathIsReportedWithoutRunningHooks() async throws {
    let root = try makeRepository()
    let service = RepositoryGitExecutionPolicyService()
    let initial = await service.configuredHooksPath(rootURL: root)
    XCTAssertNil(initial)
    _ = try git(["config", "core.hooksPath", ".husky/_"], root: root)
    let configured = await service.configuredHooksPath(rootURL: root)
    XCTAssertEqual(configured, ".husky/_")
  }

  private func makeRepository() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("git-policy-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = try git(["init", "-b", "main"], root: root)
    _ = try git(["config", "user.name", "Policy Tests"], root: root)
    _ = try git(["config", "user.email", "policy@example.com"], root: root)
    _ = try git(["commit", "--allow-empty", "-m", "base"], root: root)
    return root
  }

  @discardableResult
  private func git(_ arguments: [String], root: URL) throws -> String {
    let result = GitCommandRunner().run(arguments, rootURL: root)
    guard result.terminationStatus == 0 else {
      throw NSError(
        domain: "RepositoryGitExecutionPolicyServiceTests", code: Int(result.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: result.output])
    }
    return result.standardOutput
  }

  private func executable(_ script: String, at url: URL) throws {
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: url.path)
  }
}
